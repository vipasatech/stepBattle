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
/// local storage, but doesn't refresh it. The refresh only happens
/// LAZILY on the first authed request that gets a 401. If the app was
/// terminated for longer than the JWT TTL (default 1 hour), every
/// realtime channel + FGS-isolate Supabase client retries with the
/// stale token, all fail, and there's no clean recovery path in the
/// current codebase. This function fires a refresh right after init so
/// downstream systems get a valid token from the start.
///
/// Behavior:
///   • No session at all → no-op (user is signed out, router handles).
///   • Session present + not expired → still call refreshSession() as
///     a cheap health check (Supabase treats non-expired sessions as
///     a fast no-op internally).
///   • Session present + expired → refreshSession() uses the persisted
///     refresh token to mint a new access token (refresh tokens live
///     ~30 days by default).
///   • Refresh token itself expired / revoked → refreshSession()
///     throws AuthException → we sign out locally so the router routes
///     to /welcome instead of leaving the user in a broken state.
Future<void> _refreshSessionIfStale() async {
  try {
    final client = Supabase.instance.client;
    final session = client.auth.currentSession;
    if (session == null) {
      AppLogger.session.i('sessionRefresh:skipped', fields: {'reason': 'no_session'});
      return;
    }
    final wasExpired = session.isExpired;
    await client.auth.refreshSession();
    AppLogger.session.i('sessionRefresh:done', fields: {'wasExpired': wasExpired});
  } on AuthException catch (e) {
    // Refresh token itself is invalid — persisted session is dead.
    // Sign the user out cleanly; the router redirect will route them
    // to /welcome. Better than letting the app run in a broken state
    // where every authed call fails and the user has no recovery UI.
    AppLogger.session.w('sessionRefresh:refreshTokenDead',
        fields: {'error': e.message});
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (_) {}
  } catch (e, s) {
    // Network error or other transient — log but don't sign out;
    // the app can try again on the next authed call. This is the
    // "your phone is offline at boot" case.
    AppLogger.session
        .w('sessionRefresh:transientError', fields: {'error': e.toString()});
    // s intentionally unused — transient errors don't need stack trace noise.
    // ignore: unused_local_variable
    final _ = s;
  }
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
