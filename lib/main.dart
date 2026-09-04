import 'dart:async';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app.dart';
import 'firebase_options.dart';
import 'services/alarm_wake_scheduler.dart';
import 'services/background_sync.dart';
import 'services/local_profile_photo_service.dart';
import 'services/native_step_service.dart';
import 'services/observability_service.dart';
import 'services/persistent_notifications.dart';
import 'utils/app_logger.dart';
import 'utils/cross_isolate_kv.dart';

/// Top-level FCM background/terminated message handler. Must be a top-level
/// (or static) function annotated with `@pragma('vm:entry-point')` because it
/// runs in its own isolate. The OS renders `notification` messages itself, so
/// there's nothing to do here for the wake-the-phone use case.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Silent "sync_wake" pushes (sent ~2 min before a battle ends) wake the app
  // so it uploads fresh steps before the server freezes the score. Other
  // (visible) notifications are rendered by the OS; nothing to do for them.
  if (message.data['type'] == 'sync_wake') {
    await headlessStepSync();
  }
}

/// Proactively refresh the persisted Supabase session at cold-start.
///
/// Rationale: [Supabase.initialize] restores the last session from
/// local storage, but doesn't refresh it. The refresh happens LAZILY on
/// the first authed request that gets a 401, OR proactively when we
/// detect the persisted access token is already past its expiry.
///
/// **Revised behavior (2026-08-30 — auth-persistence fix):**
///
/// The prior version called `refreshSession()` on every cold start even
/// when the access token was still valid, treating it as a cheap health
/// check. It's not cheap — with Supabase's refresh-token rotation
/// (gotrue default) every call consumes and replaces the refresh token.
/// Combined with 4 concurrent isolates each running their own
/// Supabase client (main + FGS + WorkManager + AlarmWake), the
/// aggressive refresh burned tokens fast enough to trigger reuse
/// detection server-side, which invalidated the entire session family
/// and forced sign-out after 1–2 days of light use. See ticket in
/// PENDING_MIGRATIONS notes; root-cause chain analyzed 2026-08-30.
///
/// New behavior:
///   • No session at all → no-op (router handles).
///   • Session present + NOT expired → **no-op**. Supabase's built-in
///     auto-refresh (single-flight on the main isolate) will handle
///     it in-flight when the JWT actually expires.
///   • Session present + expired → refreshSession() (only path that
///     actually needs to fire on cold start).
///   • On genuine "refresh token dead" errors → sign out (session is
///     unrecoverable server-side). We keep the last-signed-in email
///     hint in prefs so /welcome can offer a one-tap re-auth path.
///   • On transient errors (network, 5xx) → log + skip; the SDK
///     will retry lazily on the next authed call.
Future<void> _refreshSessionIfStale() async {
  try {
    final client = Supabase.instance.client;
    final session = client.auth.currentSession;
    if (session == null) {
      AppLogger.session.i('sessionRefresh:skipped',
          fields: {'reason': 'no_session'});
      return;
    }
    // FIX 1 — Skip the "health-check" refresh entirely when the access
    // token is still valid. Every unnecessary refresh consumes a
    // refresh token (rotation is on), and with 4 isolates in play any
    // race triggers Supabase's reuse-detection and nukes the session.
    if (!session.isExpired) {
      AppLogger.session.i('sessionRefresh:skipped', fields: {
        'reason': 'not_expired',
        'expiresIn': session.expiresIn,
      });
      return;
    }
    // Access token IS expired — proactive refresh so the first authed
    // call after boot doesn't have to eat a 401 → retry cycle.
    final sw = Stopwatch()..start();
    AppLogger.session.i('sessionRefresh:start', fields: {
      'reason': 'access_token_expired',
      'expiresIn': session.expiresIn,
    });
    final refreshed = await client.auth.refreshSession();
    sw.stop();
    AppLogger.session.i('sessionRefresh:done', fields: {
      'ms': sw.elapsedMilliseconds,
      'newExpiresIn': refreshed.session?.expiresIn,
      'hasNewSession': refreshed.session != null,
    });
  } on AuthException catch (e) {
    // FIX 3a — Distinguish truly-dead sessions from transient/service
    // errors. Only sign out when Supabase says the refresh token is
    // dead (reuse detected, expired past its 30d TTL, or explicitly
    // revoked). Everything else stays signed-in and gets retried on
    // the next authed call.
    if (_isRefreshTokenTrulyDead(e)) {
      AppLogger.session.w('sessionRefresh:refreshTokenDead', fields: {
        'error': e.message,
        'statusCode': e.statusCode,
      });
      try {
        // Sign out via full SupabaseAuthService.signOut() semantics would
        // require reaching into Riverpod from main() which is awkward.
        // Directly call Supabase auth.signOut() — the router picks up the
        // signed-out state via onAuthStateChange and routes to /welcome.
        // The last-signed-in-email prefs entry is preserved (not cleared)
        // so /welcome can offer a soft "Continue as <email>" one-tap
        // re-auth path instead of a cold "sign in from scratch" UX.
        await Supabase.instance.client.auth.signOut();
      } catch (_) {}
    } else {
      // Transient AuthException (5xx from goauth, rate limit, network
      // hiccup dressed as AuthException). Don't sign out — the next
      // authed call will retry, and if the token is genuinely fine
      // the request succeeds without any user-visible disruption.
      AppLogger.session.w('sessionRefresh:transientAuthError', fields: {
        'error': e.message,
        'statusCode': e.statusCode,
      });
    }
  } catch (e, s) {
    // Network error or other non-AuthException failure — log but don't
    // sign out; the app can try again on the next authed call. This is
    // the "your phone is offline at boot" case.
    AppLogger.session.w('sessionRefresh:transientError',
        fields: {'error': e.toString()});
    // s intentionally unused — transient errors don't need stack trace noise.
    // ignore: unused_local_variable
    final _ = s;
  }
}

/// Returns true when the AuthException indicates the persisted refresh
/// token is unusable server-side and re-auth is the only recovery. False
/// for transient errors (5xx, rate limit, network) where a retry might
/// succeed.
///
/// Matched against Supabase gotrue's error codes (see
/// https://supabase.com/docs/reference/dart/auth-error-codes). We match
/// on `code` when present and fall back to substring on `message` for
/// older SDK versions that don't populate `code`.
bool _isRefreshTokenTrulyDead(AuthException e) {
  final code = e.code?.toLowerCase();
  if (code != null) {
    const deadCodes = {
      'refresh_token_not_found',
      'refresh_token_already_used',
      'invalid_grant',
      'session_not_found',
      'user_not_found',
    };
    if (deadCodes.contains(code)) return true;
  }
  final msg = e.message.toLowerCase();
  if (msg.contains('refresh token not found') ||
      msg.contains('refresh token already used') ||
      msg.contains('invalid grant') ||
      msg.contains('invalid refresh token') ||
      msg.contains('session from session_id claim in jwt does not exist')) {
    return true;
  }
  // A 400 from the token endpoint with an unrecognized message is
  // ambiguous; err on the safe side (transient) since Fix 1 + Fix 2
  // make the truly-dead case rare and re-auth on false-positive
  // transient is worse UX than a delayed signOut on true-dead.
  return false;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Hive must be initialized before any service that persists state.
  // The native step tracker needs its baseline persisted across launches.
  await Hive.initFlutter();
  await Hive.openBox(NativeStepService.boxName);

  // Warm the CrossIsolateKV SharedPreferences cache so sync getters in
  // Riverpod providers (e.g., isTrackActive) can read without an await.
  // Background isolates initialize their own copy in their entry points.
  await CrossIsolateKV.init();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Register the FCM background handler so push sent by the server (battle
  // results, invites) is delivered while the app is backgrounded/terminated.
  // `notification`-type messages are shown by the OS automatically; this
  // handler just keeps data payloads from being dropped.
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  // Load .env (bundled as an asset) BEFORE initializing Supabase or
  // Sentry/PostHog. Treat missing Supabase values as fatal in debug so
  // we notice locally; in release we fall through to a placeholder so
  // the app at least starts — Supabase calls will fail loudly via RLS
  // denial. Sentry/PostHog gracefully no-op on placeholder values.
  await dotenv.load(fileName: '.env');
  final supaUrl = dotenv.env['SUPABASE_URL'];
  final supaKey = dotenv.env['SUPABASE_ANON_KEY'];
  if (supaUrl == null || supaUrl.isEmpty || supaKey == null || supaKey.isEmpty) {
    AppLogger.session.e('supabaseInit:missingEnv', fields: {
      'hasUrl': supaUrl != null && supaUrl.isNotEmpty,
      'hasKey': supaKey != null && supaKey.isNotEmpty,
    });
    assert(false,
        '.env is missing SUPABASE_URL or SUPABASE_ANON_KEY. Copy .env.example.');
  } else {
    await Supabase.initialize(url: supaUrl, anonKey: supaKey);
    AppLogger.session.i('supabaseInit:done', fields: {'url': supaUrl});
    // Cold-start session refresh. Supabase persists the session to
    // local storage and auto-refreshes it in-flight, but if the app
    // was terminated for longer than the JWT TTL (default 1 hour), the
    // persisted session is stale — the refresh happens only after the
    // FIRST authed call fails with InvalidJWTToken. That failure
    // cascades to every realtime channel (they retry with the same
    // stale token and keep failing), and to the FGS isolate which
    // silently can't sync. Symptoms observed 2026-08-13:
    //   • realtime:retry with "InvalidJWTToken: Token has expired
    //     186274 seconds ago" (~52 hours)
    //   • Live tracking Resume button appears to do nothing (FGS
    //     starts but its Supabase writes 401)
    // Fix: proactively refresh right after init. If the refresh token
    // itself is expired (>30 days), sign out cleanly so the router
    // routes to /welcome instead of leaving the user in limbo.
    await _refreshSessionIfStale();
  }

  // Background sync plumbing (foreground-service config + WorkManager init).
  // Android-only inside; safe no-op elsewhere. The periodic task itself is
  // registered after login (see MainShell), and the foreground service is
  // started/stopped based on active battles.
  await BackgroundSync.initEarly();

  // Cold-start native pedometer warmup. Fire-and-forget subscription
  // to the OS step-counter sensor. Purpose: on OEM Androids where
  // the first TYPE_STEP_COUNTER event can take 2-3 seconds to
  // deliver (moto g35, older Realme / Xiaomi), starting the
  // subscription during app boot lets the sensor warm up in the
  // background so by the time the Home tab mounts the first event
  // has already landed and step counts appear instantly instead
  // of "0 steps" for the first few seconds.
  //
  // Correctness note: Riverpod's `nativeStepServiceProvider` will
  // create ANOTHER NativeStepService instance later — subscribing to
  // the same `Pedometer.stepCountStream` (which is a broadcast
  // stream, plugin-managed). Two subscribers is fine; both receive
  // events. This warmup instance's stream is intentionally never
  // cancelled — it lives for the app lifetime, negligible memory
  // (one event callback registered) but shaves the cold-start "0
  // steps" window off Home renders.
  unawaited(NativeStepService().start());

  // Android exact-time alarm scheduler. Fires headlessStepSync at 4
  // fixed times/day (06:00, 12:00, 18:00, 23:45) as a resilient backup
  // to WorkManager — AlarmManager runs even under Doze / OEM battery
  // saver, so aggressive Xiaomi/Realme/OnePlus builds still get
  // periodic cloud sync. No-op on iOS. See alarm_wake_scheduler.dart.
  await AlarmWakeScheduler.initialize();

  // Battle + Track persistent notifications (posted by the foreground service
  // tick from `background_sync.dart`). Tap handlers funnel the target route
  // into `pendingDeepLinkNotifier`; MainShell consumes it via context.go.
  await PersistentNotifications.instance.init(
    onTap: (payload) {
      final route = routeForNotifPayload(payload);
      if (route != null) pendingDeepLinkNotifier.value = route;
    },
  );

  // Emit a session header so per-session log folders start with build/device
  // context. Wrapped so a logging hiccup never blocks app startup.
  unawaited(_emitSessionHeader());

  // One-shot cleanup of the legacy device-global profile-photo cache
  // (pre per-user namespacing). Idempotent + guarded by a pref flag —
  // no-ops after the first launch that runs it. Fire-and-forget so a
  // slow filesystem call never blocks boot.
  unawaited(LocalProfilePhotoService.migrateLegacyCache());

  // Try to flush any profile-photo upload that was queued because the
  // network was offline the last time the user picked a photo. The
  // service is idempotent and no-ops when no queued item exists;
  // failure just leaves the marker in place for the app-resume retry
  // in `StepBattleApp.didChangeAppLifecycleState`.
  unawaited(LocalProfilePhotoService.retryPendingUpload());

  // Catch every unhandled framework error and surface it into _session.log
  // — these otherwise vanish into the platform stderr. Both handlers also
  // fan out to Sentry via the AppLogger error hook installed by
  // [ObservabilityService.init] below.
  FlutterError.onError = (details) {
    AppLogger.session.e(
      'flutterError',
      fields: {'library': details.library, 'context': details.context?.toString()},
      error: details.exception,
      stack: details.stack,
    );
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    // Downgrade known-transient network noise so it doesn't clog the
    // Diagnostics screen + eat mental space during real triage. The
    // `google_fonts` package tries to download font `.ttf` files from
    // `fonts.gstatic.com` at first-run; when DNS is down (flaky wifi,
    // VPN, some ISPs), the SocketException bubbles up as an uncaught
    // async error. The package itself catches internally + falls back
    // to system font, so nothing is actually broken — but the noise
    // used to look like an error worth investigating. Log at debug
    // so the trail is preserved without ranking it as ERROR-severity.
    //
    // Match on the exception's string form because the package throws
    // both `ClientException` and `Exception` wrappers depending on the
    // failure mode; a substring check covers every variant we've seen.
    final msg = error.toString();
    final isFontFetchNoise =
        msg.contains('fonts.gstatic.com') ||
        msg.contains('Failed to load font');
    if (isFontFetchNoise) {
      AppLogger.session.d('platformError:fontFetchFallback',
          fields: {'msg': msg.length > 160 ? '${msg.substring(0, 160)}…' : msg});
      return false;
    }
    // Also downgrade Supabase Realtime timeout noise. `supabase_flutter`
    // auto-retries a dropped WebSocket subscription with exponential
    // backoff; the initial timeout bubbles up here as an uncaught
    // async error, but the channel usually resubscribes within a
    // few seconds. Route to DEBUG so real errors aren't buried under
    // recoverable-network-flap noise. The missed-event case (an
    // INSERT that fires during our reconnect window) is handled
    // separately by the lifecycle-resume invalidation on the missions
    // + friends providers (2026-08-31 change).
    final isRealtimeTimeoutNoise =
        msg.contains('RealtimeSubscribeException') &&
        msg.contains('timedOut');
    if (isRealtimeTimeoutNoise) {
      AppLogger.session.d('platformError:realtimeReconnect',
          fields: {'msg': msg.length > 160 ? '${msg.substring(0, 160)}…' : msg});
      return false;
    }
    // Similar treatment for the HTTP RPC connection-closed noise that
    // rides along with WebSocket timeouts during the same network flap.
    // A future RPC call will succeed once the connection is restored;
    // no code-side recovery needed.
    final isConnectionClosedNoise =
        msg.contains('Connection closed before full header was received');
    if (isConnectionClosedNoise) {
      AppLogger.session.d('platformError:connectionClosed',
          fields: {'msg': msg.length > 160 ? '${msg.substring(0, 160)}…' : msg});
      return false;
    }
    AppLogger.session.e('platformError', error: error, stack: stack);
    return false;
  };

  // Replace the default red-screen error box with a small, friendly
  // fallback in release builds. Framework exceptions still fire
  // `FlutterError.onError` above (which logs + reports to Sentry) —
  // this only changes the visible pixel-for-pixel widget that renders
  // when a build fails, so users see a graceful "unavailable" placeholder
  // instead of the yellow-on-red debug screen (e.g. the GlobalKey /
  // HeroController assertion that hit v1.0.2+9 users on the public
  // profile screen). Debug builds keep the loud red screen because
  // that's what developers need.
  if (kReleaseMode) {
    ErrorWidget.builder = (details) => Container(
          color: const Color(0xFF14141A),
          alignment: Alignment.center,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline,
                  color: Colors.white70, size: 40),
              const SizedBox(height: 12),
              Text(
                'Couldn\'t render this section.',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                'Please go back and try again.',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 13,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        );
  }

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF0E0E10),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  // Sentry wraps the runApp zone so uncaught async errors inside widget
  // callbacks are captured. When the DSN is a placeholder the wrapper is
  // skipped and `runner` is invoked directly. PostHog init is idempotent
  // and independent of Sentry state.
  await ObservabilityService.init(runner: () {
    runApp(
      const ProviderScope(
        child: StepBattleApp(),
      ),
    );
  });
}

Future<void> _emitSessionHeader() async {
  try {
    final pkg = await PackageInfo.fromPlatform();
    final fields = <String, dynamic>{
      'appName': pkg.appName,
      'version': pkg.version,
      'build': pkg.buildNumber,
      'package': pkg.packageName,
    };
    final deviceInfo = DeviceInfoPlugin();
    if (defaultTargetPlatform == TargetPlatform.android) {
      final a = await deviceInfo.androidInfo;
      fields.addAll({
        'platform': 'android',
        'model': a.model,
        'manufacturer': a.manufacturer,
        'sdkInt': a.version.sdkInt,
        'release': a.version.release,
      });
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      final i = await deviceInfo.iosInfo;
      fields.addAll({
        'platform': 'ios',
        'model': i.utsname.machine,
        'systemVersion': i.systemVersion,
      });
    }
    AppLogger.session.i('sessionStart', fields: fields);
  } catch (e, s) {
    AppLogger.session.e('sessionHeaderFailed', error: e, stack: s);
  }
}
