import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import '../utils/app_logger.dart';

/// Single owner of client-side observability: crash reporting via Sentry
/// and product-analytics events via PostHog.
///
/// Design constraints:
///   • Both providers no-op cleanly when their `.env` secret is the string
///     `'changeme'` (the shipped placeholder). This lets a fresh clone
///     boot without paying / signing up for either service.
///   • Every error captured by [captureException] is ALSO logged through
///     [AppLogger] so the in-app diagnostics sheet, per-category log
///     files, and the ring buffer keep working exactly as before.
///   • [AppLogger.e] is bridged to [captureException] via the outbound
///     hook installed in [_installLoggerBridge] — no extra call sites to
///     update in the rest of the codebase.
///   • PII redaction is handled INSIDE [AppLogger]; by the time an error
///     message reaches Sentry through the bridge, emails / phones / JWTs
///     have already been replaced with placeholders.
class ObservabilityService {
  ObservabilityService._();

  static bool _sentryEnabled = false;
  static bool _posthogEnabled = false;

  /// Retained isolate-error port. The Isolate holds only the SendPort;
  /// the RawReceivePort itself needs a strong reference on the Dart heap
  /// or GC will reclaim it and every subsequent isolate error is
  /// silently dropped. Static field lifetime = process lifetime.
  static RawReceivePort? _isolateErrorPort;

  static bool get sentryEnabled => _sentryEnabled;
  static bool get posthogEnabled => _posthogEnabled;

  /// Initialise both providers based on `.env` values. Call from
  /// `main()` AFTER `dotenv.load(...)` and BEFORE `runApp(...)`.
  ///
  /// The `runner` callback is what would have been passed to `runApp`.
  /// When Sentry is enabled we hand `runner` to
  /// [SentryFlutter.init]'s `appRunner` param so Sentry can wrap the
  /// zone that hosts the widget tree. When disabled, we just invoke it.
  static Future<void> init({required FutureOr<void> Function() runner}) async {
    final sentryDsn = (dotenv.env['SENTRY_DSN'] ?? '').trim();
    final sentryEnv = (dotenv.env['SENTRY_ENV'] ?? 'dev').trim();
    final tracesSampleRateStr =
        (dotenv.env['SENTRY_TRACES_SAMPLE_RATE'] ?? '1.0').trim();
    final tracesSampleRate = double.tryParse(tracesSampleRateStr) ?? 1.0;

    final posthogKey = (dotenv.env['POSTHOG_API_KEY'] ?? '').trim();
    final posthogHost =
        (dotenv.env['POSTHOG_HOST'] ?? 'https://us.i.posthog.com').trim();

    _sentryEnabled = _isRealSecret(sentryDsn);
    _posthogEnabled = _isRealSecret(posthogKey);

    // Always install the AppLogger.e → Sentry bridge; it internally checks
    // [_sentryEnabled] before doing any Sentry work, so wiring is uniform.
    _installLoggerBridge();

    // Install our own onError handlers first, so behaviour is consistent
    // whether Sentry is enabled or not. Sentry's wrapper will further
    // decorate them when init() runs.
    _installErrorHandlers();

    // Bootstrap PostHog. Its Flutter SDK reads the key from the native
    // AndroidManifest / Info.plist rather than at Dart runtime, so with a
    // placeholder key nothing gets uploaded — the SDK is a local no-op.
    if (_posthogEnabled) {
      try {
        final config = PostHogConfig(posthogKey)
          ..host = posthogHost
          ..debug = kDebugMode
          ..captureApplicationLifecycleEvents = true;
        await Posthog().setup(config);
        AppLogger.session
            .i('posthog:init', fields: {'host': posthogHost, 'enabled': true});
      } catch (e, s) {
        _posthogEnabled = false;
        AppLogger.session
            .e('posthog:initFailed', error: e, stack: s);
      }
    } else {
      AppLogger.session.i('posthog:init',
          fields: {'enabled': false, 'reason': 'placeholder key'});
    }

    if (!_sentryEnabled) {
      AppLogger.session.i('sentry:init',
          fields: {'enabled': false, 'reason': 'placeholder DSN'});
      // Still run the app; skip Sentry init entirely.
      await runner();
      return;
    }

    AppLogger.session.i('sentry:init', fields: {
      'enabled': true,
      'env': sentryEnv,
      'tracesSampleRate': tracesSampleRate,
    });

    await SentryFlutter.init(
      (options) {
        options.dsn = sentryDsn;
        options.environment = sentryEnv;
        options.tracesSampleRate = tracesSampleRate;
        // Session Replay is opt-in later; leave off for Phase 0 to stay
        // within the free-tier session cap.
        options.attachScreenshot = false;
        options.attachViewHierarchy = false;
        options.enableAutoPerformanceTracing = true;
        // Retain some breadcrumbs from prints / logger before an error
        // so Sentry has context. AppLogger already redacts PII first.
        options.enablePrintBreadcrumbs = true;
        // Beforesend hook lets us drop noisy events. Kept minimal here;
        // a proper allow-list lives in Phase 7.
        options.beforeSend = (event, hint) async {
          if (event.throwable is FlutterErrorDetails) {
            // FlutterErrorDetails wraps the underlying exception; keep
            // the wrapper for its extra widget context but demote noisy
            // "IgnorePointer parent detached" style false positives if
            // we see them accumulate. Placeholder for future filtering.
          }
          return event;
        };
      },
      appRunner: () async => await runner(),
    );
  }

  /// Bridge AppLogger.e → Sentry so every error log path is auto-captured
  /// without every service having to remember to also call this class.
  static void _installLoggerBridge() {
    AppLogger.setOnErrorHook((entry, error, stack) {
      if (!_sentryEnabled) return;
      // Fire-and-forget; Sentry batches internally and we don't want to
      // block the logger call site.
      unawaited(
        Sentry.captureException(
          error ?? entry.event,
          stackTrace: stack,
          withScope: (scope) {
            scope.setTag('category', entry.category.name);
            scope.setTag('level', entry.level.name);
            if (entry.fields != null && entry.fields!.isNotEmpty) {
              scope.setContexts('fields', entry.fields!);
            }
          },
        ),
      );
    });
  }

  static void _installErrorHandlers() {
    // FlutterError.onError already exists in main.dart; we DON'T replace
    // it here, we compose. main.dart routes to AppLogger.e which then
    // fans out to Sentry via the bridge. This method is a hook for
    // future decoration (e.g. isolate error handling).
    //
    // MUST assign to a field before passing sendPort: Isolate holds
    // only the SendPort, so without a strong reference on the Dart
    // heap the RawReceivePort is GC-eligible and the callback stops
    // firing. Idempotent — repeat init calls close the old port first.
    _isolateErrorPort?.close();
    _isolateErrorPort = RawReceivePort((pair) {
      final list = pair as List<dynamic>;
      final error = list.first;
      final stack = StackTrace.fromString(list.last?.toString() ?? '');
      AppLogger.session.e('isolateError', error: error, stack: stack);
    });
    Isolate.current.addErrorListener(_isolateErrorPort!.sendPort);
  }

  /// Capture an exception with optional extra context. Prefer using
  /// `AppLogger.e(...)` — this method exists for cases where you need
  /// custom scope tags without a logger call.
  static Future<void> captureException(
    Object error, {
    StackTrace? stack,
    Map<String, Object?>? context,
  }) async {
    AppLogger.session.e('captureException',
        fields: context?.cast<String, Object?>(), error: error, stack: stack);
  }

  /// Drop a Sentry breadcrumb — timeline entry that ships with the next
  /// captured exception but never generates one itself. Cheap; use
  /// liberally for state transitions (realtime connect/disconnect, auth
  /// events, screen focus changes) so when something DOES crash the
  /// preceding activity is visible in the Sentry issue.
  ///
  /// Silent no-op when Sentry is disabled.
  static void breadcrumb(
    String message, {
    String? category,
    SentryLevel level = SentryLevel.info,
    Map<String, Object?>? data,
  }) {
    if (!_sentryEnabled) return;
    try {
      Sentry.addBreadcrumb(Breadcrumb(
        message: message,
        category: category,
        level: level,
        data: data,
        timestamp: DateTime.now().toUtc(),
      ));
    } catch (_) {
      // Breadcrumbs are best-effort — never let observability plumbing
      // take down the caller.
    }
  }

  /// Fire a product-analytics event. Silent no-op when PostHog is
  /// disabled. Common event names: `signup`, `battle_create`,
  /// `battle_win`, `step_synced`, `avatar_pick`, `streak_break`.
  ///
  /// Properties should be small (≤~20 keys) and MUST NOT contain PII —
  /// PostHog is a third-party sink; `userId` is fine but `email` /
  /// `phone` should be omitted.
  static void trackEvent(String name, {Map<String, Object>? properties}) {
    if (!_posthogEnabled) return;
    try {
      Posthog().capture(eventName: name, properties: properties);
    } catch (e, s) {
      AppLogger.session.w('posthog:trackFailed',
          fields: {'event': name, 'error': e.toString()});
      // Also loop back through AppLogger.e so Sentry (if on) sees it.
      AppLogger.session.e('posthog:trackFailed', error: e, stack: s);
    }
  }

  /// Identify the current user so subsequent events are attributed. Call
  /// once after sign-in with the Supabase user id. Distinct-id is opaque
  /// on the PostHog side; no PII in properties.
  static Future<void> identify(String userId,
      {Map<String, Object>? properties}) async {
    if (!_posthogEnabled) return;
    try {
      await Posthog().identify(userId: userId, userProperties: properties);
    } catch (e, s) {
      AppLogger.session.e('posthog:identifyFailed', error: e, stack: s);
    }

    if (_sentryEnabled) {
      Sentry.configureScope((scope) {
        scope.setUser(SentryUser(id: userId));
      });
    }
  }

  /// Clear identity on sign-out.
  static Future<void> resetIdentity() async {
    if (_posthogEnabled) {
      try {
        await Posthog().reset();
      } catch (_) {}
    }
    if (_sentryEnabled) {
      Sentry.configureScope((scope) => scope.setUser(null));
    }
  }

  /// `changeme` is the placeholder shipped in `.env.example`; any real
  /// secret is at least ~20 characters and doesn't equal the sentinel.
  static bool _isRealSecret(String s) =>
      s.isNotEmpty && s != 'changeme' && s.length >= 8;
}

/// Route observer that fires `screen_view` events to PostHog whenever
/// GoRouter navigates. Add to `routerConfig.observers` in `app.dart`.
///
/// The name we send is the last non-empty segment of the location path
/// (`/battles/abc-123` → `battles`). Query params + IDs stay out — they
/// blow up cardinality on the PostHog side without adding signal.
class ObservabilityRouteObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _report(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null) _report(newRoute);
  }

  void _report(Route<dynamic> route) {
    if (route is! PageRoute) return;
    final name = _screenName(route);
    if (name == null) return;
    ObservabilityService.trackEvent('screen_view', properties: {'screen': name});
  }

  String? _screenName(Route<dynamic> route) {
    final n = route.settings.name;
    if (n == null || n.isEmpty) return null;
    // Strip query + trailing slash; take the last non-empty segment.
    final path = n.split('?').first;
    final segments =
        path.split('/').where((s) => s.isNotEmpty && !_looksLikeId(s)).toList();
    if (segments.isEmpty) return 'root';
    return segments.last;
  }

  static final _idRegex =
      RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
          r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$|^\d{3,}$');
  bool _looksLikeId(String s) => _idRegex.hasMatch(s);
}
