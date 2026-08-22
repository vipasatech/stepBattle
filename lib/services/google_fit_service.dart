import 'dart:convert';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import '../utils/app_logger.dart';
import 'native_step_service.dart';

/// Last-resort step source: queries Google Fit via the REST API using the
/// existing Google Sign-In access token.
///
/// Why REST and not the Fit Android SDK: Google deprecated the Fit Android
/// SDK in 2024. The REST endpoint (`fitness.googleapis.com`) remains the
/// supported path and works on every Android phone where the user has Fit
/// installed and at least some history.
///
/// Why opt-in: requesting the `fitness.activity.read` scope shows users an
/// extra consent dialog. We don't want to widen our default OAuth ask, so
/// users only land on this scope if they explicitly enable Fit fallback in
/// settings (typically Realme/Motorola users hitting empty-HC issues).
///
/// Persistence:
///   - `fit_enabled` (bool)         — user's opt-in toggle
///   - `fit_scope_granted` (bool)   — whether we've successfully requested
///                                    the scope at least once
///   - `fit_last_token_hash` (str)  — debug only; hash of last access token
class GoogleFitService {
  static const String _scope =
      'https://www.googleapis.com/auth/fitness.activity.read';
  static const String _aggregateUrl =
      'https://www.googleapis.com/fitness/v1/users/me/dataset:aggregate';
  static const String _stepCountDataType =
      'com.google.step_count.delta';

  static const String _kEnabled = 'fit_enabled';
  static const String _kScopeGranted = 'fit_scope_granted';

  /// Set to `true` in Hive when we auto-disable because the Fit REST
  /// API returned 403. The Step Sources screen reads this flag to
  /// show a "Google retired this API" banner + prevent the user from
  /// pointlessly re-enabling. Cleared only when the user acknowledges
  /// the banner (via a "Got it" tap on the UI).
  static const String _kAutoDisabledDeprecated = 'fit_deprecated_disabled';

  final GoogleSignIn _signIn;
  final Box _box;
  String? _lastError;

  GoogleFitService({GoogleSignIn? signIn, Box? box})
      : _signIn = signIn ??
            GoogleSignIn(scopes: const [
              'email',
              _scope,
            ]),
        _box = box ?? Hive.box(NativeStepService.boxName);

  /// User-facing opt-in.
  bool get isEnabled => _box.get(_kEnabled) as bool? ?? false;
  bool get hasScope => _box.get(_kScopeGranted) as bool? ?? false;
  String? get lastError => _lastError;

  /// True when the Fit REST API returned 403 and we auto-disabled the
  /// toggle. Step Sources UI reads this to show a "Google retired
  /// this API" deprecation banner so the user understands why the
  /// switch went off on its own.
  bool get wasAutoDisabledDueToDeprecation =>
      _box.get(_kAutoDisabledDeprecated) as bool? ?? false;

  /// Clear the deprecation flag after the user acknowledges the banner.
  Future<void> acknowledgeDeprecationBanner() async {
    try {
      await _box.put(_kAutoDisabledDeprecated, false);
    } catch (_) {}
  }

  /// Internal — called when Fit REST returns 403. Disables the toggle
  /// AND sets the deprecation flag so the UI can show a specific
  /// message. Best-effort; a Hive write failure just means the flag
  /// won't stick, and the next 403 will re-trigger this path.
  Future<void> _autoDisableOnDeprecation(String from) async {
    AppLogger.health.w('googleFit:autoDisabledOn403', fields: {
      'from': from,
      'reason': 'Google Fit REST API retired 2026-06-30',
    });
    try {
      await _box.put(_kEnabled, false);
      await _box.put(_kAutoDisabledDeprecated, true);
    } catch (_) {}
  }

  /// Toggle Fit fallback on/off. When enabling, we lazily request the
  /// `fitness.activity.read` scope so the user only sees the OAuth dialog
  /// at this moment.
  ///
  /// Returns true if the toggle was set to the requested value (false
  /// means the user denied the consent dialog).
  Future<bool> setEnabled(bool enabled) async {
    AppLogger.health.i('googleFit:setEnabled', fields: {'enabled': enabled});
    if (!enabled) {
      await _box.put(_kEnabled, false);
      return true;
    }

    // We construct our OWN GoogleSignIn instance in the constructor,
    // separate from the one the auth service uses at login. That means
    // `currentUser` on THIS instance is null and `signInSilently()` only
    // works when the OS already has a matching account granted the
    // needed scopes — which for a fresh install with only `email`
    // granted, it doesn't. Prior versions gave up here with "Not signed
    // in", stranding Motorola / Realme / Nothing users who tapped
    // Enable. Fall back to interactive `signIn()` so the account picker
    // opens and the user can grant the fitness scope in one flow.
    final account = _signIn.currentUser ??
        await _signIn.signInSilently() ??
        await _interactiveSignIn();
    if (account == null) {
      _lastError = 'Sign-in cancelled';
      return false;
    }

    try {
      // `requestScopes` is on GoogleSignIn (the client), not on the account.
      final granted = await _signIn.requestScopes([_scope]);
      if (!granted) {
        _lastError = 'User denied Fit scope';
        await _box.put(_kEnabled, false);
        return false;
      }
      await _box.put(_kEnabled, true);
      await _box.put(_kScopeGranted, true);
      _lastError = null;
      return true;
    } catch (e) {
      _lastError = e.toString();
      return false;
    }
  }

  /// Interactive Google sign-in on THIS service's GoogleSignIn instance.
  /// Returns null when the user cancels the account picker (which is
  /// distinct from a hard failure). Isolated so callers don't have to
  /// re-derive the try/catch shape.
  Future<GoogleSignInAccount?> _interactiveSignIn() async {
    try {
      return await _signIn.signIn();
    } catch (e) {
      _lastError = 'signIn: $e';
      AppLogger.health.w('googleFit:interactiveSignInFailed',
          fields: {'err': e.toString()});
      return null;
    }
  }

  /// Today's steps from Google Fit. Returns null if Fit is disabled, no
  /// auth token, or the request fails — caller should treat null as
  /// "source unavailable" (not zero).
  Future<int?> getTodaySteps() async {
    if (!isEnabled) {
      AppLogger.health.t('googleFit:disabled');
      return null;
    }

    final token = await _accessToken();
    if (token == null) {
      _lastError = 'No access token';
      AppLogger.health.w('googleFit:noToken');
      return null;
    }

    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    final body = jsonEncode({
      'aggregateBy': [
        {'dataTypeName': _stepCountDataType}
      ],
      'bucketByTime': {'durationMillis': 86400000}, // 24 h bucket
      'startTimeMillis': startOfDay.millisecondsSinceEpoch,
      'endTimeMillis': now.millisecondsSinceEpoch,
    });

    try {
      final res = await http
          .post(
            Uri.parse(_aggregateUrl),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 5));

      if (res.statusCode != 200) {
        _lastError = 'Fit API HTTP ${res.statusCode}';
        // 403 = the Fitness REST API is refusing us. Google formally
        // retired this API on 2026-06-30; most projects now return
        // 403 unconditionally. Auto-disable so we stop hammering a
        // dead endpoint on every aggregator tick. The Step Sources
        // screen carries a deprecation banner explaining why the
        // toggle went off and pointing users at Health Connect.
        if (res.statusCode == 403) {
          await _autoDisableOnDeprecation('getTodaySteps');
        }
        return null;
      }

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final buckets = (json['bucket'] as List?) ?? const [];
      if (buckets.isEmpty) return 0;

      var total = 0;
      for (final bucket in buckets) {
        final datasets = (bucket['dataset'] as List?) ?? const [];
        for (final ds in datasets) {
          final points = (ds['point'] as List?) ?? const [];
          for (final p in points) {
            final values = (p['value'] as List?) ?? const [];
            for (final v in values) {
              final n = (v['intVal'] as num?)?.toInt() ?? 0;
              total += n;
            }
          }
        }
      }
      _lastError = null;
      AppLogger.health.d('googleFit:getTodaySteps', fields: {'steps': total});
      return total;
    } catch (e, s) {
      _lastError = e.toString();
      AppLogger.health.e('googleFit:getTodaySteps:failed', error: e, stack: s);
      return null;
    }
  }

  /// Aggregate step count for a specific past date (00:00 → 23:59 local
   /// midnight). Used by the missed-days backfill to reconstruct
  /// step_logs rows for days the app was terminated across.
  ///
  /// Returns null when Fit is disabled, no auth token, or the request
  /// fails — caller should treat null as "source unavailable" and
  /// fall through to the time-proportional estimator.
  Future<int?> getStepsForDate(DateTime date) async {
    if (!isEnabled) {
      AppLogger.health.t('googleFit:disabled');
      return null;
    }
    final token = await _accessToken();
    if (token == null) {
      _lastError = 'No access token';
      return null;
    }
    // Bucket the requested calendar day locally so DST changes /
    // near-midnight edge cases don't leak into the neighbouring day.
    final startOfDay = DateTime(date.year, date.month, date.day);
    final endOfDay = startOfDay.add(const Duration(days: 1));
    final body = jsonEncode({
      'aggregateBy': [
        {'dataTypeName': _stepCountDataType}
      ],
      'bucketByTime': {'durationMillis': 86400000},
      'startTimeMillis': startOfDay.millisecondsSinceEpoch,
      'endTimeMillis': endOfDay.millisecondsSinceEpoch,
    });
    try {
      final res = await http
          .post(
            Uri.parse(_aggregateUrl),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) {
        _lastError = 'Fit API HTTP ${res.statusCode}';
        // Same 403 auto-disable path as getTodaySteps — see there for
        // rationale. Missed-day backfill goes silent for this device
        // and future calls short-circuit at the isEnabled guard.
        if (res.statusCode == 403) {
          await _autoDisableOnDeprecation('getStepsForDate');
        }
        return null;
      }
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final buckets = (json['bucket'] as List?) ?? const [];
      if (buckets.isEmpty) return 0;
      var total = 0;
      for (final bucket in buckets) {
        final datasets = (bucket['dataset'] as List?) ?? const [];
        for (final ds in datasets) {
          final points = (ds['point'] as List?) ?? const [];
          for (final p in points) {
            final values = (p['value'] as List?) ?? const [];
            for (final v in values) {
              final n = (v['intVal'] as num?)?.toInt() ?? 0;
              total += n;
            }
          }
        }
      }
      _lastError = null;
      AppLogger.health.d('googleFit:getStepsForDate', fields: {
        'date': startOfDay.toIso8601String().split('T').first,
        'steps': total,
      });
      return total;
    } catch (e, s) {
      _lastError = e.toString();
      AppLogger.health.e('googleFit:getStepsForDate:failed',
          error: e, stack: s);
      return null;
    }
  }

  Future<String?> _accessToken() async {
    // Read side: never open an interactive account picker mid-poll.
    // If both current + silent are empty, treat as "no token" — the
    // enable flow above is what surfaces the sign-in UI.
    final account = _signIn.currentUser ?? await _signIn.signInSilently();
    if (account == null) return null;
    try {
      final auth = await account.authentication;
      return auth.accessToken;
    } catch (e) {
      _lastError = e.toString();
      return null;
    }
  }
}
