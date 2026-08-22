import 'dart:io';

import 'package:flutter/material.dart' show Color;
import 'package:flutter/painting.dart' show FileImage, PaintingBinding;
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/app_logger.dart';

/// Profile photo pipeline — pick → crop → local save → Supabase upload
/// → profiles.avatar_url update.
///
/// The photo is a per-user personalization AND the avatar shown in
/// leaderboards, home, battles, and any other surface that reads
/// `UserModel.avatarURL`. To keep those surfaces in sync we upload the
/// cropped file to Supabase Storage under a stable key (per user) and
/// overwrite `profiles.avatar_url` with its public URL each time the
/// user updates.
///
/// Storage layout:
///   • Bucket: `avatars` (must exist server-side; see PENDING_MIGRATIONS)
///   • Object key: `<userId>/profile.jpg` — same key on every upload so
///     we replace the previous file rather than accumulate versions.
///
/// Locally, both the SharedPreferences key AND the on-disk filename are
/// namespaced by the authenticated user id — `profile_photo_path_<uid>`
/// and `profile_photo_<uid>.jpg` respectively. Without this, switching
/// accounts on the same device would show account A's cached photo to
/// account B in the profile tab (home + leaderboard don't have this bug
/// because they render the server `avatar_url` which is inherently
/// scoped to the account).
class LocalProfilePhotoService {
  static const _prefsKeyPrefix = 'profile_photo_path_';
  static const _fileNamePrefix = 'profile_photo_';
  static const _fileNameSuffix = '.jpg';
  static const _bucket = 'avatars';
  static const _objectName = 'profile.jpg';

  // Legacy (pre-per-user-namespacing) constants. Kept only for the
  // one-shot migration in [migrateLegacyCache] — do NOT reference from
  // any read/write path.
  static const _legacyPrefsKey = 'profile_photo_path';
  static const _legacyFileName = 'profile_photo.jpg';
  static const _legacyCleanedFlag = 'profile_photo_legacy_cleaned';

  /// One-shot cleanup of the device-global pref key and file that
  /// existed before we moved to per-user namespacing. Idempotent —
  /// guarded by [_legacyCleanedFlag] so it only fires once per install.
  /// Safe to call from `main()` unconditionally; runs a couple of pref
  /// reads and at most one file delete on the very first launch after
  /// upgrade, then no-ops forever after.
  static Future<void> migrateLegacyCache() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_legacyCleanedFlag) == true) return;

    final legacyPath = prefs.getString(_legacyPrefsKey);
    if (legacyPath != null) {
      try {
        final file = File(legacyPath);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Deletion errors are non-fatal — the flag flip below still
        // fires so we don't retry on every launch.
      }
      await prefs.remove(_legacyPrefsKey);
    }

    // Belt-and-suspenders: if the pref pointed elsewhere but the
    // canonical old file is still sitting in app documents, remove it.
    try {
      final docsDir = await getApplicationDocumentsDirectory();
      final canonical = File('${docsDir.path}/$_legacyFileName');
      if (await canonical.exists()) await canonical.delete();
    } catch (_) {
      // Same as above — non-fatal.
    }

    await prefs.setBool(_legacyCleanedFlag, true);
    AppLogger.auth.i('profile_photo:legacy_cache_migrated');
  }

  /// SharedPreferences key for the currently-signed-in user. Returns
  /// null when no auth session is active (cold boot before login).
  static String? _prefsKeyFor(String? uid) =>
      uid == null ? null : '$_prefsKeyPrefix$uid';

  /// Local filename for the currently-signed-in user's cached photo.
  static String? _fileNameFor(String? uid) =>
      uid == null ? null : '$_fileNamePrefix$uid$_fileNameSuffix';

  static String? _currentUid() =>
      Supabase.instance.client.auth.currentUser?.id;

  /// Returns the local cached photo path for the CURRENT user if one
  /// exists and the file is still on disk. Prunes the pref if the file
  /// was deleted. Returns null when signed out.
  static Future<String?> getPhotoPath() async {
    final uid = _currentUid();
    final key = _prefsKeyFor(uid);
    if (key == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(key);
    if (path == null) return null;
    if (!await File(path).exists()) {
      await prefs.remove(key);
      return null;
    }
    return path;
  }

  /// Full pick → crop → upload flow. Returns the new local path on
  /// success, or `null` if the user cancelled the picker or the
  /// cropper. Uploading to Supabase happens as part of this call
  /// (blocking) because we also update `profiles.avatar_url` and want
  /// the caller to be able to await both.
  ///
  /// Throws only on unexpected upload / DB failures — never on
  /// user-cancellation.
  static Future<String?> pickCropAndSave(ImageSource source) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: source,
      // Higher raw resolution here so the cropper has pixels to work
      // with; we downscale the final crop below.
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 92,
    );
    if (picked == null) return null;

    // Crop step — square aspect (the avatar renders as a circle so a
    // 1:1 crop gives the user the exact bounds they'll see).
    //
    // UI tuned to match the app: near-black toolbar + backdrop, the
    // champion-gold crop frame from the leaderboard hero, subtle white
    // grid. `hideBottomControls: true` drops the default white scale
    // ruler + rotate tab (uCrop hardcodes the ruler's background so
    // there's no way to darken it without resource overrides). Pinch
    // and pan on the image still work — rotate is rarely needed for a
    // square profile crop, and if the user needs to reorient they can
    // re-pick with the phone rotated.
    final cropped = await ImageCropper().cropImage(
      sourcePath: picked.path,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
      compressFormat: ImageCompressFormat.jpg,
      compressQuality: 88,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Adjust photo',
          toolbarColor: const Color(0xFF14141A),
          toolbarWidgetColor: const Color(0xFFFFFFFF),
          statusBarColor: const Color(0xFF14141A),
          backgroundColor: const Color(0xFF000000),
          activeControlsWidgetColor: const Color(0xFFF0B429),
          cropFrameColor: const Color(0xFFF0B429),
          cropGridColor: const Color(0x33FFFFFF),
          dimmedLayerColor: const Color(0xB3000000),
          hideBottomControls: true,
          lockAspectRatio: true,
          cropStyle: CropStyle.circle,
        ),
        IOSUiSettings(
          title: 'Adjust photo',
          aspectRatioLockEnabled: true,
          resetAspectRatioEnabled: false,
          rotateButtonsHidden: true,
          aspectRatioPickerButtonHidden: true,
          minimumAspectRatio: 1,
          cropStyle: CropStyle.circle,
        ),
      ],
    );
    if (cropped == null) return null;

    // Refuse to save when there's no authenticated user — the local
    // cache is keyed per-uid, so an anonymous save has no owner.
    final uid = _currentUid();
    final prefsKey = _prefsKeyFor(uid);
    final fileName = _fileNameFor(uid);
    if (uid == null || prefsKey == null || fileName == null) {
      AppLogger.auth.w('profile_photo:no_auth_user_at_save');
      return null;
    }

    // Copy the cropped file into app documents under the per-user
    // filename. Different accounts on the same device don't collide.
    final docsDir = await getApplicationDocumentsDirectory();
    final targetPath = '${docsDir.path}/$fileName';
    final targetFile = File(targetPath);
    if (await targetFile.exists()) await targetFile.delete();
    await File(cropped.path).copy(targetPath);

    // Evict the stale bitmap from Flutter's image cache. `FileImage` is
    // keyed by absolute path — we intentionally re-use the same
    // per-user filename each upload so we never accumulate old copies
    // on disk. Without this eviction the next paint hits the cache and
    // re-serves the previous photo's decoded bytes, so the profile
    // page appears not to update.
    PaintingBinding.instance.imageCache.evict(FileImage(File(targetPath)));

    // Persist the local path immediately so the UI can paint the new
    // photo without waiting on the network. The upload runs after.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, targetPath);

    // Upload to Supabase Storage + update profiles.avatar_url. If any
    // of this fails (offline, transient 5xx, etc.) we still keep the
    // local copy AND stash the path in a per-user "pending upload"
    // pref. `retryPendingUpload` picks it up on next app launch and on
    // app-lifecycle resume so home + leaderboard eventually get the
    // new photo without the user having to re-pick.
    try {
      await _uploadAndPersistUrl(File(targetPath));
      await _clearPendingUpload(uid);
    } catch (e, s) {
      AppLogger.auth.e('profile_photo:upload_failed',
          fields: {'err': e.toString()}, error: e, stack: s);
      await _markPendingUpload(uid, targetPath);
    }
    return targetPath;
  }

  // ---------------------------------------------------------------------------
  // Pending-upload queue
  //
  // When the initial upload fails (device offline, transient 5xx), we mark
  // the local file as "pending upload" against the user's id. On next boot
  // AND on app-lifecycle resume, `retryPendingUpload` re-attempts the
  // upload path so home + leaderboard eventually surface the new photo
  // without requiring the user to re-open the picker.
  // ---------------------------------------------------------------------------

  static const _pendingUploadPrefix = 'profile_photo_pending_upload_';

  static String _pendingKeyFor(String uid) => '$_pendingUploadPrefix$uid';

  static Future<void> _markPendingUpload(String uid, String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingKeyFor(uid), path);
    AppLogger.auth.i('profile_photo:queued_for_retry',
        fields: {'uid': uid, 'path': path});
  }

  static Future<void> _clearPendingUpload(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingKeyFor(uid));
  }

  /// Returns true if the currently-signed-in user has a photo that was
  /// saved locally but never made it to Supabase. UI can surface a
  /// small "syncing" chip while this is true.
  static Future<bool> hasPendingUpload() async {
    final uid = _currentUid();
    if (uid == null) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_pendingKeyFor(uid)) != null;
  }

  /// Attempts to re-upload any queued photo for the currently-signed-in
  /// user. No-op when there's no queued item, no auth session, or the
  /// pending file has been deleted. On success, clears the pending
  /// marker so we don't keep re-uploading. On failure, leaves the
  /// marker in place for a later retry. Safe to call unconditionally
  /// from boot / app-resume / connectivity-restored hooks.
  static Future<void> retryPendingUpload() async {
    final uid = _currentUid();
    if (uid == null) return;
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_pendingKeyFor(uid));
    if (path == null) return;
    final file = File(path);
    if (!await file.exists()) {
      // The queued file was pruned (app data cleared, external tool)
      // — no point retrying. Drop the marker.
      await _clearPendingUpload(uid);
      return;
    }
    try {
      await _uploadAndPersistUrl(file);
      await _clearPendingUpload(uid);
      AppLogger.auth
          .i('profile_photo:retry_uploaded', fields: {'uid': uid});
    } catch (e) {
      // AppLogger.w doesn't take error/stack — those are only on .e.
      // We deliberately WARN (not error) because this is expected when
      // the network is still down; a hard error hitting Sentry would
      // be noise.
      AppLogger.auth.w('profile_photo:retry_failed',
          fields: {'uid': uid, 'err': e.toString()});
      // Marker stays — we'll try again on the next retry hook.
    }
  }

  /// Uploads the given file to `avatars/{userId}/profile.jpg` (public
  /// bucket), then writes the resulting public URL to `profiles.avatar_url`.
  static Future<void> _uploadAndPersistUrl(File file) async {
    final supabase = Supabase.instance.client;
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;

    final objectPath = '$userId/$_objectName';
    final bytes = await file.readAsBytes();

    // `upsert: true` overwrites the existing file — same key each time
    // so we don't accumulate old versions.
    await supabase.storage.from(_bucket).uploadBinary(
          objectPath,
          bytes,
          fileOptions: const FileOptions(
            contentType: 'image/jpeg',
            upsert: true,
            cacheControl: '3600',
          ),
        );

    // Append a cache-buster query param on the public URL so caches
    // (network image cache, CDN edge cache) show the new pixels
    // immediately after re-upload. Users expect their new photo to
    // land on the next screen paint, not after a TTL.
    final baseUrl = supabase.storage.from(_bucket).getPublicUrl(objectPath);
    final bustedUrl = '$baseUrl?v=${DateTime.now().millisecondsSinceEpoch}';

    await supabase
        .from('profiles')
        .update({'avatar_url': bustedUrl}).eq('id', userId);

    AppLogger.auth
        .i('profile_photo:uploaded', fields: {'uid': userId, 'url': bustedUrl});
  }

  /// Removes both the on-device photo (for the CURRENT user) and the
  /// Supabase Storage copy, and clears `profiles.avatar_url`.
  static Future<void> clear() async {
    final userId = _currentUid();
    final prefsKey = _prefsKeyFor(userId);
    if (userId == null || prefsKey == null) return;

    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(prefsKey);
    if (path != null) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
    await prefs.remove(prefsKey);
    // Also drop any pending-upload marker — no point retrying an
    // upload of a file the user just asked us to delete.
    await _clearPendingUpload(userId);

    final supabase = Supabase.instance.client;
    try {
      await supabase.storage
          .from(_bucket)
          .remove(['$userId/$_objectName']);
    } catch (_) {
      // File may not exist server-side (e.g. never uploaded) — ignore.
    }
    try {
      await supabase
          .from('profiles')
          .update({'avatar_url': null}).eq('id', userId);
    } catch (e, s) {
      AppLogger.auth.e('profile_photo:clear_url_failed',
          fields: {'err': e.toString()}, error: e, stack: s);
    }
  }
}

