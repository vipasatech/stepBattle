import 'dart:async';
import 'package:hive/hive.dart';
import 'package:intl/intl.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';

import '../utils/hive_lifecycle.dart';

/// Reads the device's hardware pedometer (`Sensor.TYPE_STEP_COUNTER` on
/// Android, `CMPedometer` on iOS) and exposes today's step count.
///
/// The OS-level cumulative counter is preserved across app kills and survives
/// while our process is dead — opening the app catches up automatically. The
/// counter resets only on device reboot, which we detect and compensate for.
///
/// State persisted across launches (Hive `step_tracker` box):
///   - `baselineAtMidnight`  — sensor cumulative captured at last midnight
///                             rollover (or post-reboot reset).
///   - `lastReadingDate`     — yyyy-MM-dd of the last computation; new day
///                             resets the baseline.
///   - `lastCumulative`      — most recent sensor reading; smaller-than-last
///                             reading implies a reboot.
///   - `preRebootDelta`      — accumulated steps from prior boots THIS DAY,
///                             added back into today's total so a reboot
///                             does not erase pre-reboot progress.
///
/// Today's steps = `preRebootDelta + (currentCumulative - baselineAtMidnight)`.
class NativeStepService {
  /// Main-isolate Hive box name. Opened ONCE in main.dart's bootstrap
  /// and used by every repository / service running on the UI thread.
  ///
  /// Background isolates (WorkManager, foreground service) MUST NOT
  /// open this box — they use [backgroundBoxName] instead so two
  /// isolates never fight for the same file handle. See the "Level B"
  /// note in lib/utils/cross_isolate_kv.dart for the full rationale.
  static const String boxName = 'step_tracker';

  /// Background-isolate-only Hive box. Never opened by the main isolate.
  /// Holds a background-scoped copy of NativeStepService state so the
  /// WorkManager / FGS entry points can compute step deltas without
  /// touching the main-isolate box.
  ///
  /// The two boxes will inevitably drift (main's baseline updates when
  /// main is foreground; bg's baseline updates on bg ticks). That's OK
  /// because Supabase upserts on `(user_id, hour_start)` — last write
  /// wins on the same row regardless of which isolate wrote it.
  static const String backgroundBoxName = 'step_tracker_bg';
  static const _kBaseline = 'baselineAtMidnight';
  static const _kLastDate = 'lastReadingDate';
  static const _kLastCumulative = 'lastCumulative';
  static const _kPreRebootDelta = 'preRebootDelta';

  /// Unix-ms timestamp of the most recent snapshot we persisted. Used
  /// by the missed-days backfill to figure out how much elapsed
  /// between the last known reading and now, and therefore how to
  /// distribute a multi-day delta across the missed calendar days.
  static const _kLastKnownAtMs = 'lastKnownAtMs';

  /// Computed "today's steps" AT the last snapshot. Persisting this
  /// lets the backfill routine tell "yesterday ended with N steps"
  /// vs "yesterday had zero snapshots at all" — the former lets us
  /// pin yesterday to an authoritative value; the latter falls back
  /// to time-proportional estimation.
  static const _kLastKnownDailyTotal = 'lastKnownDailyTotal';

  /// Fallback box captured at construction — used for tests that inject
  /// a specific box, and as the "if the shared box is somehow gone but
  /// we still have a reference" safety net. Live callers should prefer
  /// [_liveBox] which re-fetches on every access.
  final Box _boxFallback;

  StreamSubscription<StepCount>? _sub;
  int _latestCumulative = 0;
  bool _hasReading = false;
  DateTime? _lastReceivedAt;
  String? _lastError;

  /// Whether the most recent stream event was a successful reading.
  bool get isAvailable => _hasReading;
  String? get lastError => _lastError;
  DateTime? get lastReceivedAt => _lastReceivedAt;

  NativeStepService({Box? box})
      : _boxFallback = box ?? Hive.box(boxName);

  /// Live box handle — re-fetched on every access so a background-isolate
  /// close doesn't leave us holding a stale reference. Falls back to the
  /// injected/constructed box only when the shared registry is empty
  /// (test path).
  Box get _box => safeSharedBox() ?? _boxFallback;

  /// Fire-and-forget put that swallows the benign
  /// `FileSystemException: File closed` race with the background isolate.
  /// Real defects (disk full, permission denied) still propagate to the
  /// unhandled-error stream where Diagnostics catches them.
  void _safePut(String key, Object value) {
    try {
      unawaited(_box.put(key, value).catchError((Object e) {
        if (isBenignBoxClosed(e)) return;
        // Non-benign — re-raise to the unhandled-error stream where
        // Diagnostics catches it like any other real failure.
        throw e;
      }));
    } catch (e) {
      // Sync throw path (box was closed at the moment put was called).
      if (isBenignBoxClosed(e)) return;
      rethrow;
    }
  }

  /// Safe read that returns null if the box is closed / the read throws
  /// a benign error. Callers that want a default supply one via `??`.
  Object? _safeGet(String key) {
    try {
      return _box.get(key);
    } catch (e) {
      if (isBenignBoxClosed(e)) return null;
      rethrow;
    }
  }

  /// Begin subscribing to the pedometer stream. Idempotent.
  ///
  /// Requires `ACTIVITY_RECOGNITION` (Android 10+) / `MotionUsage` (iOS)
  /// permission. If not granted we no-op silently — `getTodaySteps()` will
  /// return 0 and `isAvailable` will stay false.
  Future<void> start() async {
    if (_sub != null) return;

    final granted = await Permission.activityRecognition.status;
    if (!granted.isGranted) {
      _lastError = 'ACTIVITY_RECOGNITION not granted';
      return;
    }

    try {
      _sub = Pedometer.stepCountStream.listen(
        (event) {
          _latestCumulative = event.steps;
          _hasReading = true;
          _lastReceivedAt = DateTime.now();
          _lastError = null;
        },
        onError: (Object e) {
          _hasReading = false;
          _lastError = e.toString();
        },
        cancelOnError: false,
      );
    } catch (e) {
      _lastError = e.toString();
    }
  }

  /// Stop the subscription. Counts continue at OS level; resume by
  /// calling [start] again.
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  /// Compute today's steps from the latest sensor reading + persisted state.
  /// Handles midnight rollover and reboot recovery.
  ///
  /// Returns 0 if no sensor reading has arrived yet (cold start before the
  /// first stream event lands — usually <1 second).
  int getTodaySteps() {
    if (!_hasReading) return 0;

    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final c = _latestCumulative;

    var baseline = (_safeGet(_kBaseline) as int?) ?? c;
    var lastDate = (_safeGet(_kLastDate) as String?) ?? today;
    final lastCumulative = (_safeGet(_kLastCumulative) as int?) ?? c;
    var preRebootDelta = (_safeGet(_kPreRebootDelta) as int?) ?? 0;

    // 1. Midnight rollover — new day resets baseline + delta.
    if (lastDate != today) {
      baseline = c;
      preRebootDelta = 0;
      lastDate = today;
    }

    // 2. Reboot detection — sensor counter resets to 0 on boot, so a
    // reading lower than what we last saw means the device rebooted.
    // Capture the delta walked between baseline and the last reading
    // (i.e., the steps already counted today before the reboot) and
    // start a new baseline at 0 for the new boot session.
    if (c < lastCumulative) {
      preRebootDelta += (lastCumulative - baseline);
      baseline = 0;
    }

    final today_ = preRebootDelta + (c - baseline);
    final todaySteps = today_ < 0 ? 0 : today_;

    // Persist state so reboot/midnight detection survives app restarts.
    _safePut(_kBaseline, baseline);
    _safePut(_kLastDate, lastDate);
    _safePut(_kLastCumulative, c);
    _safePut(_kPreRebootDelta, preRebootDelta);
    // Snapshot metadata for the backfill routine — timestamps of
    // when we last knew the counter + the computed day total. If the
    // app is killed after this write and re-opened days later, the
    // backfill uses these values to bound the missed-day window.
    _safePut(_kLastKnownAtMs, DateTime.now().millisecondsSinceEpoch);
    _safePut(_kLastKnownDailyTotal, todaySteps);

    return todaySteps;
  }

  /// Persist the CURRENT sensor reading + timestamp without recomputing
  /// today's steps. Called from the app-lifecycle handler the moment
  /// the app transitions out of `resumed` (paused / inactive / hidden)
  /// so the last known state is as fresh as possible before Android
  /// eventually kills the process.
  ///
  /// No-op when we haven't received a sensor reading yet — writing a
  /// zero cumulative here would corrupt the baseline math.
  ///
  /// Cheap: 3 Hive writes, no network, no ticker. Safe to call on
  /// every lifecycle transition.
  Future<void> snapshotForShutdown() async {
    if (!_hasReading) return;
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    // Recompute today's steps so the snapshotted daily-total reflects
    // whatever's happened since the last read. Reuses getTodaySteps
    // which also handles reboot / rollover detection along the way.
    final total = getTodaySteps();
    _safePut(_kLastCumulative, _latestCumulative);
    _safePut(_kLastDate, today);
    _safePut(_kLastKnownAtMs, DateTime.now().millisecondsSinceEpoch);
    _safePut(_kLastKnownDailyTotal, total);
  }

  /// Recompute the persisted baseline so that today's value will match
  /// [trustedTodaySteps] on the next read. Used by the aggregator when
  /// it detects native has drifted far above HC (corrupt baseline /
  /// silent reboot detection failure).
  ///
  /// The math: today = preRebootDelta + (latestCumulative − baseline).
  /// We want today == trustedTodaySteps, so
  /// baseline = latestCumulative − (trustedTodaySteps − preRebootDelta).
  ///
  /// We clear `preRebootDelta` to 0 to start fresh — the trusted source
  /// already incorporates any reboot-era walking it could observe.
  void repairBaselineFromTrustedSource({required int trustedTodaySteps}) {
    if (!_hasReading) return; // No latest cumulative yet — nothing to anchor.
    final c = _latestCumulative;
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final newBaseline = c - trustedTodaySteps;
    _safePut(_kBaseline, newBaseline < 0 ? 0 : newBaseline);
    _safePut(_kLastDate, today);
    _safePut(_kLastCumulative, c);
    _safePut(_kPreRebootDelta, 0);
  }

  /// Snapshot of internal state for the debug screen.
  Map<String, Object?> debugSnapshot() => {
        'available': _hasReading,
        'lastError': _lastError,
        'latestCumulative': _latestCumulative,
        'baselineAtMidnight': _safeGet(_kBaseline),
        'lastReadingDate': _safeGet(_kLastDate),
        'lastCumulative': _safeGet(_kLastCumulative),
        'preRebootDelta': _safeGet(_kPreRebootDelta),
        'lastReceivedAt': _lastReceivedAt?.toIso8601String(),
        'lastKnownAtMs': _safeGet(_kLastKnownAtMs),
        'lastKnownDailyTotal': _safeGet(_kLastKnownDailyTotal),
      };

  /// Public accessors for the backfill routine to reason about the
  /// pre-termination snapshot without going through Hive keys directly.
  /// Returns null when we've never captured a reading.
  DateTime? get lastKnownAt {
    final ms = _safeGet(_kLastKnownAtMs);
    if (ms is! int) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// Local calendar date (yyyy-MM-dd) of the last known snapshot.
  String? get lastKnownDate => _safeGet(_kLastDate) as String?;

  /// The computed today-total AT the last snapshot. Represents where
  /// the last-known-date's step tally left off before the app went
  /// silent.
  int? get lastKnownDailyTotal =>
      (_safeGet(_kLastKnownDailyTotal) as num?)?.toInt();

  /// Sensor cumulative counter AT the last snapshot. Combined with
  /// the current cumulative, the delta between them = ALL steps
  /// walked during the silent window.
  int? get lastKnownCumulative =>
      (_safeGet(_kLastCumulative) as num?)?.toInt();

  /// Current cumulative from the most recent sensor event, or null
  /// if we haven't received one yet.
  int? get currentCumulative => _hasReading ? _latestCumulative : null;
}
