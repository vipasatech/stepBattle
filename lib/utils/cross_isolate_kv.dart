import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

/// Cross-isolate key-value store — the escape hatch for state that
/// needs to be readable and writable from BOTH the main isolate AND
/// the background isolates (WorkManager + `flutter_foreground_task`).
///
/// **Why not Hive:** Hive box files can only be safely opened by ONE
/// isolate at a time — when the WorkManager background isolate opens
/// the shared box, the main isolate's handle goes stale and every
/// subsequent write throws `FileSystemException: File closed`. That
/// error family is what flooded Diagnostics with 400+ entries before
/// the Level A guards + this Level B refactor.
///
/// **Why SharedPreferences works:** on Android it is backed by
/// SharedPreferences (SQLite under the hood in modern versions),
/// which IS multi-process / multi-isolate safe. On iOS it uses
/// NSUserDefaults, also process-safe. Both platforms are the
/// "correct" primitive for the "small K-V shared across
/// components-of-my-app" job.
///
/// **The keys we host here:**
///   • `fgAliveAtMs` — foreground service liveness timestamp. Written
///     by the always-on foreground service; read by WorkManager to
///     decide whether to skip a redundant sync.
///   • `activeTrack*` — mirror of the current run-tracking session's
///     numbers (steps / distance / pace / calories / started-at).
///     Written by RunTrackingService in the main isolate; read by
///     `background_sync._renderTrack` in the foreground-service
///     isolate to render the Strava-style lock-screen notification.
///
/// **Init contract:** call [init] once per isolate at startup. The
/// main isolate does this in [main]; background isolates do it in
/// their entry points (see `background_sync.dart`). Callers that
/// want sync reads (e.g. `isTrackActive` from a Riverpod provider)
/// MUST have called [init] first, otherwise sync getters return null.
class CrossIsolateKV {
  CrossIsolateKV._();

  // ── Key catalog — prefix `ci_` distinguishes cross-isolate keys
  // from ordinary SharedPreferences entries other packages own.
  static const String fgAliveAtMs = 'ci_fg_alive_at_ms';

  static const String activeTrackStartedAt = 'ci_active_track_started_at';
  static const String activeTrackSteps = 'ci_active_track_steps';
  static const String activeTrackDistanceM = 'ci_active_track_distance_m';
  static const String activeTrackPaceSecKm = 'ci_active_track_pace_sec_km';
  static const String activeTrackCalories = 'ci_active_track_calories';

  // Pending OTP restore — signup / login / password-reset all send a
  // 6-digit code to the user's email, then navigate to /verify-otp.
  // If the OS kills the app while the user is switching to their email
  // client to grab the code, we want the app to re-open on the OTP
  // screen (not the welcome/signup landing). These three keys let the
  // router redirect back into the flow on cold start; they're cleared
  // on successful verify OR when the user picks "Use a different email".
  static const String pendingOtpEmail = 'ci_pending_otp_email';
  static const String pendingOtpMode = 'ci_pending_otp_mode';
  static const String pendingOtpSentAtMs = 'ci_pending_otp_sent_at_ms';

  // Last-signed-in email — persisted after any successful sign-in so
  // /welcome can offer a soft "Continue as <email>" one-tap re-auth
  // path when a session dies for reasons other than an explicit user
  // sign-out (e.g., refresh token rotated past its 30-day TTL or
  // Supabase-side invalidation from a multi-isolate race). The key is
  // cleared on explicit user-initiated signOut so the next open reads
  // as a truly-fresh install-and-sign-in flow. Auth-persistence fix
  // 2026-08-30 — see main.dart `_refreshSessionIfStale` header.
  static const String lastSignedInEmail = 'ci_last_signed_in_email';

  // Last-sign-in METHOD — one of 'google' or 'email'. Paired with
  // [lastSignedInEmail] so /welcome's "Continue as <email>" button
  // fires the RIGHT re-auth flow directly instead of dropping the
  // user on the generic /login screen. Google users → open Google
  // account picker; email-OTP users → fire sendEmailOtp + navigate
  // straight to /verify-otp. Null when the user hasn't signed in
  // since this key was introduced (fall back to /login prefill).
  // 2026-09-04 fix — see welcome_screen.dart _continueAsLastUser.
  static const String lastSignInMethod = 'ci_last_signin_method';

  /// Cached instance for sync reads. Populated by [init]; nulled by
  /// nothing (SharedPreferences singleton lives as long as the isolate).
  static SharedPreferences? _prefs;

  /// Initialize the SharedPreferences singleton for THIS isolate. Safe
  /// to call more than once — subsequent calls are cheap no-ops. Every
  /// isolate must call this before using [getIntSync] / [getDoubleSync].
  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  // ── Writes — async because the underlying prefs write is async.
  //    Every setter re-fetches the instance so callers that skipped
  //    init() still work (they just incur one extra platform-channel
  //    roundtrip on the first write).

  static Future<void> setString(String key, String value) async {
    final p = _prefs ?? (await SharedPreferences.getInstance());
    _prefs = p;
    await p.setString(key, value);
  }

  static Future<void> setInt(String key, int value) async {
    final p = _prefs ?? (await SharedPreferences.getInstance());
    _prefs = p;
    await p.setInt(key, value);
  }

  static Future<void> setDouble(String key, double value) async {
    final p = _prefs ?? (await SharedPreferences.getInstance());
    _prefs = p;
    await p.setDouble(key, value);
  }

  /// Store a nullable double — SharedPreferences has no "set null"
  /// concept, so `null` is encoded as REMOVAL of the key. Reads
  /// that come back missing are interpreted as null by the caller.
  static Future<void> setNullableDouble(String key, double? value) async {
    if (value == null) {
      await remove(key);
      return;
    }
    await setDouble(key, value);
  }

  static Future<void> remove(String key) async {
    final p = _prefs ?? (await SharedPreferences.getInstance());
    _prefs = p;
    await p.remove(key);
  }

  // ── Sync reads — for hot paths where async would ripple through
  //    the UI tree. Returns null if the value doesn't exist OR if
  //    [init] hasn't run yet in this isolate (isolate startup race).

  static int? getIntSync(String key) => _prefs?.getInt(key);
  static double? getDoubleSync(String key) => _prefs?.getDouble(key);
  static String? getStringSync(String key) => _prefs?.getString(key);

  // ── Async reads — for cold paths / background isolates where we
  //    can't rely on init having been awaited before the read.

  static Future<int?> getInt(String key) async {
    final p = _prefs ?? (await SharedPreferences.getInstance());
    _prefs = p;
    return p.getInt(key);
  }

  static Future<double?> getDouble(String key) async {
    final p = _prefs ?? (await SharedPreferences.getInstance());
    _prefs = p;
    return p.getDouble(key);
  }

  // ── Pending-OTP convenience helpers ──────────────────────────────
  // Wraps the three [pendingOtp*] keys as one logical unit — saves,
  // reads (with TTL check), and clears them together. TTL is short
  // enough (15 min) that a stale entry never causes an unwanted
  // redirect if the user comes back to the app days later.

  /// How long a pending-OTP restore is considered valid. Supabase OTPs
  /// themselves live ~60 min but we tighten to 15 to avoid awkward
  /// "resurrect the OTP screen 30 minutes after I already gave up" UX.
  static const Duration pendingOtpTtl = Duration(minutes: 15);

  /// Persist the email + mode of an in-flight OTP verification. Called
  /// right after signup/login/reset flows fire `sendEmailOtp`. Logs
  /// the outcome so we can trace restore failures — swallowing errors
  /// silently made the earlier "app forgot the OTP page" bug invisible.
  static Future<void> savePendingOtp({
    required String email,
    required String mode,
  }) async {
    try {
      await setString(pendingOtpEmail, email);
      await setString(pendingOtpMode, mode);
      await setInt(pendingOtpSentAtMs, DateTime.now().millisecondsSinceEpoch);
      AppLogger.auth.i('otpRestore:saved', fields: {'mode': mode});
    } catch (e, s) {
      AppLogger.auth.e('otpRestore:saveFailed',
          fields: {'mode': mode}, error: e, stack: s);
    }
  }

  /// Read the pending OTP restore payload, or null if none / expired.
  /// Sync — safe for use in the router's redirect gate on cold start.
  static ({String email, String mode})? getPendingOtpSync() {
    final email = getStringSync(pendingOtpEmail);
    final mode = getStringSync(pendingOtpMode);
    final sentAt = getIntSync(pendingOtpSentAtMs);
    if (email == null || email.isEmpty) return null;
    if (mode == null || mode.isEmpty) return null;
    if (sentAt == null) return null;
    final ageMs = DateTime.now().millisecondsSinceEpoch - sentAt;
    if (ageMs > pendingOtpTtl.inMilliseconds) return null;
    return (email: email, mode: mode);
  }

  /// Clear the pending OTP restore payload. Called on successful verify,
  /// "Use a different email", and the X close button on the verify
  /// screen. Fire-and-forget; logs but doesn't rethrow.
  static Future<void> clearPendingOtp() async {
    try {
      await remove(pendingOtpEmail);
      await remove(pendingOtpMode);
      await remove(pendingOtpSentAtMs);
      AppLogger.auth.i('otpRestore:cleared');
    } catch (e, s) {
      AppLogger.auth.w('otpRestore:clearFailed',
          fields: {'err': e.toString()});
      // s intentionally unused — clear failures shouldn't crash the app.
      // ignore: unused_local_variable
      final _ = s;
    }
  }

  // ── Last-signed-in-email convenience helpers ─────────────────────
  // See the [lastSignedInEmail] key comment for the full policy: save
  // on any successful sign-in, clear on explicit user signOut, PRESERVE
  // on session-death signOut (so /welcome can offer a soft one-tap
  // re-auth). Fire-and-forget; never blocks or throws.

  /// Persist the email + sign-in method from a successful sign-in.
  /// Overwrites any prior value so a user who switches accounts on the
  /// same device sees their most-recent email as the re-auth hint AND
  /// the correct method fires when they tap "Continue as".
  ///
  /// [method] must be `'google'` or `'email'`. Null-safe on either —
  /// unset method just means `/welcome` falls back to opening `/login`
  /// with the email pre-filled (pre-2026-09-04 behaviour).
  static Future<void> saveLastSignedInEmail(String? email,
      {String? method}) async {
    if (email == null || email.isEmpty) return;
    try {
      await setString(lastSignedInEmail, email);
      if (method != null && method.isNotEmpty) {
        await setString(lastSignInMethod, method);
      }
      AppLogger.auth
          .i('lastEmail:saved', fields: {'method': method ?? 'unknown'});
    } catch (e) {
      AppLogger.auth.w('lastEmail:saveFailed',
          fields: {'err': e.toString()});
    }
  }

  /// Read the last-signed-in email hint, or null if none is stored.
  /// Sync — safe for use from a widget build() or the router.
  static String? getLastSignedInEmailSync() =>
      getStringSync(lastSignedInEmail);

  /// Read the last-sign-in method (`'google'` or `'email'`), or null
  /// if none is stored. Sync — safe for use from a widget build().
  static String? getLastSignInMethodSync() =>
      getStringSync(lastSignInMethod);

  /// Clear the last-signed-in email hint + method. Called only on
  /// explicit user-initiated signOut — NOT on session-death signOut,
  /// which deliberately preserves the hint so the user can
  /// re-authenticate with one tap. Fire-and-forget.
  static Future<void> clearLastSignedInEmail() async {
    try {
      await remove(lastSignedInEmail);
      await remove(lastSignInMethod);
      AppLogger.auth.i('lastEmail:cleared');
    } catch (e) {
      AppLogger.auth.w('lastEmail:clearFailed',
          fields: {'err': e.toString()});
    }
  }
}
