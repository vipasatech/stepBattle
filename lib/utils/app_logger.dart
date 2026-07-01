import 'dart:async';
import 'dart:collection';
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
/// `debugPrint` output is a no-op in release builds unless built with
/// `--dart-define=ENABLE_LOGS=true`. The IN-MEMORY RING BUFFER, however,
/// is always populated — so an in-app logs viewer (see
/// `LogsViewerSheet`) can show recent activity to users on a release
/// build for field debugging without round-tripping through logcat.
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
  track,
  payments,
}

enum LogLevel { trace, debug, info, warn, error }

/// One in-memory log entry. Kept on the ring buffer so the in-app logs
/// viewer can render past activity without parsing stdout.
@immutable
class LogEntry {
  final DateTime ts;
  final LogCategory category;
  final LogLevel level;
  final String event;
  final Map<String, dynamic>? fields;

  const LogEntry({
    required this.ts,
    required this.category,
    required this.level,
    required this.event,
    this.fields,
  });

  /// Render in the same format as the `debugPrint` line so the viewer
  /// shows what would have been in logcat.
  String formatted() {
    final tag = category.name;
    final lvlName = level.name;
    final tsStr = ts.toUtc().toIso8601String();
    String payload = event;
    if (fields != null && fields!.isNotEmpty) {
      try {
        payload = '$event ${jsonEncode(fields)}';
      } catch (_) {
        payload = '$event ${fields.toString()}';
      }
    }
    return '[LOG][$tag][$tsStr][$lvlName] $payload';
  }
}

class AppLogger {
  // Enabled in any debug/profile build, or whenever the host passes the
  // ENABLE_LOGS define explicitly (useful for release-mode field debugging).
  static const bool _debugPrintEnabled =
      kDebugMode || bool.fromEnvironment('ENABLE_LOGS', defaultValue: false);

  /// Ring buffer capacity. ~500 entries × ~200 chars ≈ 100KB resident —
  /// cheap, and enough to cover a 30-minute run worth of tick logs.
  static const int _ringCapacity = 500;

  /// Append-only ring buffer of the most recent N log entries. Drained
  /// from the front when capacity is exceeded. Always populated even in
  /// release builds so the in-app diagnostics sheet has something to
  /// show after a problem occurs.
  static final Queue<LogEntry> _ring = Queue<LogEntry>();

  /// Broadcasts every new entry. The logs viewer subscribes so live
  /// activity streams in without polling.
  static final StreamController<LogEntry> _stream =
      StreamController<LogEntry>.broadcast();

  /// Snapshot of the current ring buffer, optionally filtered to one
  /// category. Caller gets a fresh list — modifying it doesn't affect
  /// the buffer.
  static List<LogEntry> recent({LogCategory? category}) {
    if (category == null) return List<LogEntry>.from(_ring);
    return _ring.where((e) => e.category == category).toList(growable: false);
  }

  /// Stream of newly-appended entries (broadcast). Subscribe to render a
  /// live tail in the diagnostics sheet.
  static Stream<LogEntry> get stream => _stream.stream;

  /// Drop all retained entries. Wired to a "Clear" button in the viewer
  /// so a tester can reset before reproducing.
  static void clearBuffer() => _ring.clear();

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
  static final track = AppLogger._(LogCategory.track);
  static final payments = AppLogger._(LogCategory.payments);

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
    final entry = LogEntry(
      ts: DateTime.now(),
      category: _category,
      level: lvl,
      event: event,
      fields: fields,
    );

    // Always append to the ring buffer — survives release builds so the
    // in-app viewer can show what happened.
    _ring.addLast(entry);
    while (_ring.length > _ringCapacity) {
      _ring.removeFirst();
    }
    if (_stream.hasListener) _stream.add(entry);

    if (_debugPrintEnabled) {
      debugPrint(entry.formatted());
    }
  }
}
