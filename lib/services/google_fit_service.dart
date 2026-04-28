import 'dart:convert';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
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

  /// Toggle Fit fallback on/off. When enabling, we lazily request the
  /// `fitness.activity.read` scope so the user only sees the OAuth dialog
  /// at this moment.
  ///
  /// Returns true if the toggle was set to the requested value (false
  /// means the user denied the consent dialog).
  Future<bool> setEnabled(bool enabled) async {
    if (!enabled) {
      await _box.put(_kEnabled, false);
      return true;
    }

    // Lazily request the scope on the existing signed-in account.
    final account = _signIn.currentUser ?? await _signIn.signInSilently();
    if (account == null) {
      _lastError = 'Not signed in';
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
      return true;
    } catch (e) {
      _lastError = e.toString();
      return false;
    }
  }

  /// Today's steps from Google Fit. Returns null if Fit is disabled, no
  /// auth token, or the request fails — caller should treat null as
  /// "source unavailable" (not zero).
  Future<int?> getTodaySteps() async {
    if (!isEnabled) return null;

    final token = await _accessToken();
    if (token == null) {
      _lastError = 'No access token';
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
      return total;
    } catch (e) {
      _lastError = e.toString();
      return null;
    }
  }

  Future<String?> _accessToken() async {
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
