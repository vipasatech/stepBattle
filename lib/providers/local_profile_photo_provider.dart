import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../services/local_profile_photo_service.dart';
import 'auth_provider.dart';

/// Watches the on-device profile photo path for the CURRENTLY signed-in
/// user. `null` = no photo set (or signed out), so the UI should fall
/// back to the initials / server avatar_url.
///
/// The provider is rebuilt whenever the authenticated user id changes
/// so switching accounts on the same device shows the correct cached
/// photo for the new user rather than leaking the previous account's
/// image into the profile tab.
final localProfilePhotoProvider =
    StateNotifierProvider<LocalProfilePhotoNotifier, String?>((ref) {
  // Rebuild when the auth uid changes — sign-in, sign-out, account
  // switch. The service reads the per-user pref key on `_load`.
  final uid = ref.watch(authStateProvider).valueOrNull?.id;
  return LocalProfilePhotoNotifier(uid: uid, ref: ref);
});

class LocalProfilePhotoNotifier extends StateNotifier<String?> {
  final String? uid;
  final Ref _ref;
  LocalProfilePhotoNotifier({required this.uid, required Ref ref})
      : _ref = ref,
        super(null) {
    _load();
  }

  Future<void> _load() async {
    if (uid == null) return;
    state = await LocalProfilePhotoService.getPhotoPath();
  }

  Future<void> pickFromGallery() async {
    final path = await LocalProfilePhotoService.pickCropAndSave(ImageSource.gallery);
    if (path != null) state = path;
    // Refresh the pending-upload badge — the pick may have set the
    // marker (offline) or cleared it (upload succeeded).
    _ref.invalidate(pendingProfilePhotoUploadProvider);
  }

  Future<void> pickFromCamera() async {
    final path = await LocalProfilePhotoService.pickCropAndSave(ImageSource.camera);
    if (path != null) state = path;
    _ref.invalidate(pendingProfilePhotoUploadProvider);
  }

  Future<void> clear() async {
    await LocalProfilePhotoService.clear();
    state = null;
    _ref.invalidate(pendingProfilePhotoUploadProvider);
  }
}

/// True while the current user has a locally-saved profile photo that
/// hasn't been mirrored to Supabase Storage / `profiles.avatar_url`
/// yet — usually because the network was offline at pick time. UI
/// surfaces a small "Syncing…" chip on the avatar while this is true.
///
/// Reacts to:
///   • Auth uid changes (per-user pending marker).
///   • [profilePhotoRetryTickProvider] emissions — every time we
///     attempt a retry (connectivity-restore, app-resume, boot) we
///     bump the tick so this provider re-reads the pref and clears
///     the chip when the retry succeeded.
final pendingProfilePhotoUploadProvider = FutureProvider<bool>((ref) async {
  ref.watch(authStateProvider);
  ref.watch(profilePhotoRetryTickProvider);
  return LocalProfilePhotoService.hasPendingUpload();
});

/// Monotonic counter bumped every time we run a background retry of
/// the pending photo upload. [pendingProfilePhotoUploadProvider]
/// watches this so the "Syncing…" chip disappears as soon as a retry
/// succeeds (without polling the pref).
final profilePhotoRetryTickProvider = StateProvider<int>((_) => 0);

/// Owns the app-wide connectivity listener that opportunistically
/// re-drives `LocalProfilePhotoService.retryPendingUpload()` the
/// moment the device gets a live network again. Read once by
/// [StepBattleApp] so the subscription lives for the whole app
/// lifetime; disposal is automatic when the provider container
/// tears down (which for the top-level scope is app shutdown).
final photoRetryConnectivityProvider = Provider<StreamSubscription<void>>((ref) {
  var wasOffline = true;
  final sub = Connectivity()
      .onConnectivityChanged
      .listen((results) async {
    final online = results.any((r) => r != ConnectivityResult.none);
    // Rising-edge only — no point re-firing every second while the
    // user hops between WiFi and mobile data.
    if (online && wasOffline) {
      await LocalProfilePhotoService.retryPendingUpload();
      // Bump the tick even if the retry no-op'd — the UI chip subscribes
      // to this and needs the signal to re-read the pref.
      ref.read(profilePhotoRetryTickProvider.notifier).state++;
    }
    wasOffline = !online;
  });
  ref.onDispose(sub.cancel);
  return sub;
});
