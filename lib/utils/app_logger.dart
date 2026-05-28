import 'dart:convert';
import 'package:flutter/foundation.dart';

/// Categorised structured logger.
///
/// Every line emitted has the shape:
///
///   `[LOG][<category>][<isoUtcTimestamp>][<level>] <event> {jsonFields?}`
///
/// The companion PowerShell script `tools/run_with_logs.ps1` matches the
/// `[LOG][<category>]` prefix and routes each line into
/// `./logs/<session>/<category>.log` so per-domain history is preserved
/// across hot reloads.
///
/// Logger is a no-op in release builds unless built with
/// `--dart-define=ENABLE_LOGS=true`.
///
/// Usage:
///
///   AppLogger.step.i('syncSteps', fields: {'userId': uid, 'steps': 647});
///   AppLogger.mission.e('progressWriteFailed', error: e, stack: s);
enum LogCategory {
  session,
  step,
  mission,
  xp,
  battle,
  clan,
  auth,
  friend,
  health,
  permission,
  leaderboard,
  geo,
  notification,
  nav,
}

enum LogLevel { trace, debug, info, warn, error }

class AppLogger {
  // Enabled in any debug/profile build, or whenever the host passes the
  // ENABLE_LOGS define explicitly (useful for release-mode field debugging).
  static const bool _enabled =
      kDebugMode || bool.fromEnvironment('ENABLE_LOGS', defaultValue: false);

  static final session = AppLogger._(LogCategory.session);
  static final step = AppLogger._(LogCategory.step);
  static final mission = AppLogger._(LogCategory.mission);
  static final xp = AppLogger._(LogCategory.xp);
  static final battle = AppLogger._(LogCategory.battle);
  static final clan = AppLogger._(LogCategory.clan);
  static final auth = AppLogger._(LogCategory.auth);
  static final friend = AppLogger._(LogCategory.friend);
  static final health = AppLogger._(LogCategory.health);
  static final permission = AppLogger._(LogCategory.permission);
  static final leaderboard = AppLogger._(LogCategory.leaderboard);
  static final geo = AppLogger._(LogCategory.geo);
  static final notification = AppLogger._(LogCategory.notification);
  static final nav = AppLogger._(LogCategory.nav);

  final LogCategory _category;
  AppLogger._(this._category);

  void t(String event, {Map<String, dynamic>? fields}) =>
      _write(LogLevel.trace, event, fields);
  void d(String event, {Map<String, dynamic>? fields}) =>
      _write(LogLevel.debug, event, fields);
  void i(String event, {Map<String, dynamic>? fields}) =>
      _write(LogLevel.info, event, fields);
  void w(String event, {Map<String, dynamic>? fields}) =>
      _write(LogLevel.warn, event, fields);

  /// Error logger that also captures the error + a trimmed stack trace so the
  /// per-service log file is self-contained for triage.
  void e(
    String event, {
    Map<String, dynamic>? fields,
    Object? error,
    StackTrace? stack,
  }) {
    final merged = <String, dynamic>{...?fields};
    if (error != null) merged['error'] = error.toString();
    if (stack != null) {
      // First 6 frames is usually enough; full stacks blow up logs.
      merged['stack'] =
          stack.toString().split('\n').take(6).join(' || ');
    }
    _write(LogLevel.error, event, merged);
  }

  void _write(LogLevel lvl, String event, Map<String, dynamic>? fields) {
    if (!_enabled) return;
    final ts = DateTime.now().toUtc().toIso8601String();
    final tag = _category.name;
    final lvlName = lvl.name;
    String payload = event;
    if (fields != null && fields.isNotEmpty) {
      try {
        payload = '$event ${jsonEncode(fields)}';
      } catch (_) {
        // Fall back to toString if a field contains a non-JSON-encodable
        // value — never let a logging call crash the app.
        payload = '$event ${fields.toString()}';
      }
    }
    debugPrint('[LOG][$tag][$ts][$lvlName] $payload');
  }
}
