import 'dart:async';
import 'package:hive/hive.dart';
import 'package:intl/intl.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';

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
  static const String boxName = 'step_tracker';
  static const _kBaseline = 'baselineAtMidnight';
  static const _kLastDate = 'lastReadingDate';
  static const _kLastCumulative = 'lastCumulative';
  static const _kPreRebootDelta = 'preRebootDelta';

  final Box _box;

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
      : _box = box ?? Hive.box(boxName);

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

    var baseline = (_box.get(_kBaseline) as int?) ?? c;
    var lastDate = (_box.get(_kLastDate) as String?) ?? today;
    final lastCumulative = (_box.get(_kLastCumulative) as int?) ?? c;
    var preRebootDelta = (_box.get(_kPreRebootDelta) as int?) ?? 0;

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
    _box.put(_kBaseline, baseline);
    _box.put(_kLastDate, lastDate);
    _box.put(_kLastCumulative, c);
    _box.put(_kPreRebootDelta, preRebootDelta);

    return todaySteps;
  }

  /// Snapshot of internal state for the debug screen.
  Map<String, Object?> debugSnapshot() => {
        'available': _hasReading,
        'lastError': _lastError,
        'latestCumulative': _latestCumulative,
        'baselineAtMidnight': _box.get(_kBaseline),
        'lastReadingDate': _box.get(_kLastDate),
        'lastCumulative': _box.get(_kLastCumulative),
        'preRebootDelta': _box.get(_kPreRebootDelta),
        'lastReceivedAt': _lastReceivedAt?.toIso8601String(),
      };
}
