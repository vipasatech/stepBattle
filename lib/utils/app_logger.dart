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
/// PII redaction: every string value that flows through `_write` is
/// scanned for emails, phone numbers, and JWT tokens; matches are
/// replaced with placeholder tokens (`<email>`, `<phone>`, `<jwt>`)
/// before hitting the ring buffer, stream, `debugPrint`, or any future
/// upstream sink (Sentry). Prevents user PII leaking into third-party
/// error trackers or in-app diagnostics screens. See [_redactPII].
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

/// Callback fired every time an error-level log is emitted. Wired in
/// [ObservabilityService] to forward to Sentry. Kept as a plain callback
/// (not a stream) so a missing subscription can't drop the report.
typedef ErrorHook = void Function(
    LogEntry entry, Object? error, StackTrace? stack);

class AppLogger {
  // Enabled in any debug/profile build, or whenever the host passes the
  // ENABLE_LOGS define explicitly (useful for release-mode field debugging).
  static const bool _debugPrintEnabled =
      kDebugMode || bool.fromEnvironment('ENABLE_LOGS', defaultValue: false);

  static ErrorHook? _errorHook;

  /// Install a callback fired for every [LogLevel.error] entry. Used by
  /// [ObservabilityService] to forward errors to Sentry. Only one hook
  /// is supported — the last call wins. Pass `null` to detach.
  static void setOnErrorHook(ErrorHook? hook) => _errorHook = hook;

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

  /// Resolve a logger from a runtime [LogCategory]. Used by call-site
  /// helpers (see [SupabaseApiClient]) that need to route log lines to
  /// a category the caller picks at runtime.
  static AppLogger forCategory(LogCategory category) {
    switch (category) {
      case LogCategory.session: return session;
      case LogCategory.step: return step;
      case LogCategory.mission: return mission;
      case LogCategory.xp: return xp;
      case LogCategory.battle: return battle;
      case LogCategory.clan: return clan;
      case LogCategory.auth: return auth;
      case LogCategory.friend: return friend;
      case LogCategory.health: return health;
      case LogCategory.permission: return permission;
      case LogCategory.leaderboard: return leaderboard;
      case LogCategory.geo: return geo;
      case LogCategory.notification: return notification;
      case LogCategory.nav: return nav;
      case LogCategory.track: return track;
      case LogCategory.payments: return payments;
    }
  }

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
  /// per-service log file is self-contained for triage. Additionally fires
  /// the installed [ErrorHook] (typically the Sentry bridge) with the raw
  /// error + stack so remote crash tracking sees the actual exception,
  /// not the redacted `.toString()`.
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
    final entry = _write(LogLevel.error, event, merged);
    final hook = _errorHook;
    if (hook != null && entry != null) {
      try {
        hook(entry, error, stack);
      } catch (_) {
        // A crashing error hook must never crash the app. Swallow.
      }
    }
  }

  LogEntry? _write(LogLevel lvl, String event, Map<String, dynamic>? fields) {
    final entry = LogEntry(
      ts: DateTime.now(),
      category: _category,
      level: lvl,
      event: _redactPII(event),
      fields: _redactFieldsPII(fields),
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
    return entry;
  }
}

// ─── PII redaction ────────────────────────────────────────────────────────
// Regexes are static + final so they compile once. Loose-enough patterns to
// catch the common leak vectors — false positives (e.g. a UUID with dots
// matching part of the email pattern) prefer redaction over disclosure.

// RFC 5322 subset: word-char + . + _ + - + %, `@`, hostname, TLD.
final RegExp _emailRegex =
    RegExp(r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}');

// E.164 flavoured phone matcher: optional `+`, 8-15 digits, allowing
// dashes/spaces/parens between groups. Boundary set excludes:
//   - alphanumerics + `_`  (identifiers)
//   - `-`, `/`             (UUID segments like `2318-4166`, paths)
// so we redact real phones in JSON strings (`{"phone":"+15551234567"}`)
// but leave UUIDs, hex hashes, build IDs, and file paths alone. The
// digit body itself still allows internal `-`, spaces, and parens so
// `+1 415-555-0123` and `(415) 555 0123` still match.
final RegExp _phoneRegex = RegExp(
  r'(?:(?<=^)|(?<=[^A-Za-z0-9_\-/]))\+?(?:\d[\s\-()]?){7,14}\d(?=$|[^A-Za-z0-9_\-/])',
);

// JWT: 3 base64url segments joined by `.`. Second and third segments are
// long enough that <20 chars/segment weeds out false positives from
// filenames like `foo.bar.baz`.
final RegExp _jwtRegex = RegExp(
  r'eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}',
);

/// Replace common PII patterns in `s` with fixed placeholder tokens.
/// Idempotent — running twice yields the same output.
///
/// Ordering matters: JWTs before phones (JWT segments can look like long
/// digit runs), emails last (some emails contain a `+phone-like` local
/// part we don't want mistaken for phones).
String _redactPII(String s) {
  if (s.isEmpty) return s;
  return s
      .replaceAll(_jwtRegex, '<jwt>')
      .replaceAll(_phoneRegex, '<phone>')
      .replaceAll(_emailRegex, '<email>');
}

/// Walk a fields map and redact string values in place. Non-string values
/// (ints, doubles, bools, nulls) pass through; nested maps + lists are
/// visited recursively so error objects with a `data:{email:'x@y'}` field
/// still get scrubbed.
Map<String, dynamic>? _redactFieldsPII(Map<String, dynamic>? fields) {
  if (fields == null) return null;
  final out = <String, dynamic>{};
  fields.forEach((k, v) {
    out[k] = _redactValuePII(v);
  });
  return out;
}

Object? _redactValuePII(Object? v) {
  if (v == null) return null;
  if (v is String) return _redactPII(v);
  if (v is Map) {
    // Preserve string-keyed maps (the only shape the logger receives).
    return v.map<String, dynamic>(
      (dynamic k, dynamic val) => MapEntry(k.toString(), _redactValuePII(val)),
    );
  }
  if (v is Iterable) return v.map(_redactValuePII).toList(growable: false);
  return v;
}
