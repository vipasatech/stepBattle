import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive/hive.dart';
import '../models/source_step_hourly_log_model.dart';
import 'device_info_service.dart';
import 'native_step_service.dart';
import 'step_source_aggregator.dart';

/// Persists per-source step counts to Firestore on an hourly cadence.
///
/// Schema (top-level Firestore collection, doc id `{userId}_{hourKey}`):
///   source_step_hourly/
///     {userId}_{yyyy-MM-dd-HH}     (hourKey is UTC)
///       userId, hourStart, hourKey,
///       nativeSteps, healthConnectSteps, googleFitSteps,
///       aggregateSteps, winningSource,
///       per-source error strings,
///       deviceManufacturer, deviceModel, androidVersion, appVersion,
///       createdAt, updatedAt
///
/// Foreign keys (logical, Firestore doesn't enforce):
///   userId → users/{userId}
///   (hourStart implicitly correlates with step_logs/{userId}_{date} for
///    the matching day)
///
/// Required composite index for "user's last 24 hours" queries:
///   collection: source_step_hourly
///   fields: userId asc, hourStart desc
///
/// Write throttling — see [maybeLog]:
///   - Always writes on hour rollover (cheap; max 24/day/user).
///   - Otherwise rewrites the *current* hour at most once every 10 min so
///     within-the-hour values stay reasonably fresh without burning quota
///     (max ~6/hour intra-hour + 1 hour-boundary write = ~7/hour worst-case
///     active user, ~75/day if app is foregrounded for the full waking day).
class SourceStepHourlyLogService {
  static const String _kLastWrittenHourKey = 'srcLog_lastHourKey';
  static const String _kLastWrittenAtMs = 'srcLog_lastWrittenAtMs';

  static const Duration _intraHourThrottle = Duration(minutes: 10);

  final FirebaseFirestore _firestore;
  final DeviceInfoService _deviceInfo;
  final Box _box;

  SourceStepHourlyLogService({
    FirebaseFirestore? firestore,
    DeviceInfoService? deviceInfo,
    Box? box,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _deviceInfo = deviceInfo ?? DeviceInfoService(),
        _box = box ?? Hive.box(NativeStepService.boxName);

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('source_step_hourly');

  /// Conditionally upsert this hour's row. No-op if neither the hour has
  /// rolled over nor enough time has passed since the last write.
  ///
  /// Pass the latest [StepReading] from the aggregator. Caller is
  /// responsible for ensuring the user is signed in.
  Future<void> maybeLog({
    required String userId,
    required StepReading reading,
  }) async {
    final now = DateTime.now();
    final hourKey = SourceStepHourlyLog.hourKeyFor(now);

    final lastHourKey = _box.get(_kLastWrittenHourKey) as String?;
    final lastWrittenAt = _box.get(_kLastWrittenAtMs) as int? ?? 0;
    final sinceLast =
        DateTime.fromMillisecondsSinceEpoch(lastWrittenAt).difference(now).abs();

    final hourChanged = lastHourKey != hourKey;
    final withinThrottle = !hourChanged && sinceLast < _intraHourThrottle;
    if (withinThrottle) return;

    await _writeNow(userId: userId, reading: reading, now: now);
  }

  /// Force-write regardless of throttle (used by debug screen / on logout).
  Future<void> forceLog({
    required String userId,
    required StepReading reading,
  }) async {
    await _writeNow(userId: userId, reading: reading, now: DateTime.now());
  }

  Future<void> _writeNow({
    required String userId,
    required StepReading reading,
    required DateTime now,
  }) async {
    final hourKey = SourceStepHourlyLog.hourKeyFor(now);
    final docId = SourceStepHourlyLog.docIdFor(userId: userId, t: now);
    final fp = await _deviceInfo.getFingerprint();

    final winning = _winningSource(reading);

    final log = SourceStepHourlyLog(
      userId: userId,
      hourStart: SourceStepHourlyLog.hourStartFor(now),
      hourKey: hourKey,
      nativeSteps: reading.nativeSteps,
      healthConnectSteps: reading.healthConnectSteps,
      googleFitSteps: reading.googleFitSteps,
      aggregateSteps: reading.aggregate,
      winningSource: winning,
      nativeError: reading.nativeError,
      healthConnectError: reading.healthConnectError,
      googleFitError: reading.googleFitError,
      deviceManufacturer: fp.manufacturer,
      deviceModel: fp.model,
      androidVersion: fp.osVersion,
      appVersion: fp.appVersion,
      createdAt: now,
      updatedAt: now,
    );

    // `merge: true` so re-writes within the same hour preserve `createdAt`
    // (we conditionally only set it on first-write below).
    final docRef = _col.doc(docId);
    final snap = await docRef.get();
    final payload = log.toFirestore();
    if (snap.exists) {
      payload.remove('createdAt');
    }
    await docRef.set(payload, SetOptions(merge: true));

    await _box.put(_kLastWrittenHourKey, hourKey);
    await _box.put(_kLastWrittenAtMs, now.millisecondsSinceEpoch);
  }

  static String _winningSource(StepReading r) {
    if (r.aggregate <= 0) return 'none';
    final fit = r.googleFitSteps ?? -1;
    if (fit > r.nativeSteps && fit >= r.healthConnectSteps) {
      return 'google_fit';
    }
    if (r.nativeSteps >= r.healthConnectSteps) {
      return r.nativeSteps > 0 ? 'native' : 'none';
    }
    return r.healthConnectSteps > 0 ? 'health_connect' : 'none';
  }
}
