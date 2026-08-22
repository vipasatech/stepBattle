import 'package:hive/hive.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/source_step_hourly_log_model.dart';
import '../utils/app_logger.dart';
import '../utils/hive_lifecycle.dart';
import 'device_info_service.dart';
import 'native_step_service.dart';
import 'step_source_aggregator.dart';

/// Persists per-source step counts to Supabase on an hourly cadence.
///
/// Each row is keyed by (user_id, hour_start) — see the unique constraint
/// in supabase/migrations/0001_init.sql and the additional forensic
/// columns added in 0002. The `hour_key` column is the
/// `yyyy-MM-dd-HH` (UTC) string form of `hour_start`, kept for fast
/// human-readable filtering during debugging.
///
/// Write throttling — see [maybeLog]:
///   • Always writes on hour rollover (cheap; max 24/day/user).
///   • Otherwise rewrites the current hour at most once every 10 min so
///     within-the-hour values stay fresh without burning egress.
class SourceStepHourlyLogService {
  static const String _kLastWrittenHourKey = 'srcLog_lastHourKey';
  static const String _kLastWrittenAtMs = 'srcLog_lastWrittenAtMs';

  static const Duration _intraHourThrottle = Duration(minutes: 10);

  final SupabaseClient _supabase;
  final DeviceInfoService _deviceInfo;
  final Box _box;

  SourceStepHourlyLogService({
    SupabaseClient? supabase,
    DeviceInfoService? deviceInfo,
    Box? box,
  })  : _supabase = supabase ?? Supabase.instance.client,
        _deviceInfo = deviceInfo ?? DeviceInfoService(),
        _box = box ?? Hive.box(NativeStepService.boxName);

  /// Conditionally upsert this hour's row. No-op if neither the hour has
  /// rolled over nor enough time has passed since the last write.
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
    try {
      final hourKey = SourceStepHourlyLog.hourKeyFor(now);
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

      // Upsert on the unique (user_id, hour_start) constraint so a single
      // hour-bucket gets rewritten in place. We strip `created_at` from
      // updates so the original first-write timestamp is preserved.
      final row = log.toSupabaseRow();
      row['created_at'] = now.toUtc().toIso8601String();
      await _supabase
          .from('source_step_hourly')
          .upsert(row, onConflict: 'user_id,hour_start');

      // Persist last-written markers via the live shared box. The
      // captured [_box] handle can go stale after a WorkManager
      // background isolate takes over; falling through to
      // safeSharedBox() re-fetches the current handle each call.
      final box = safeSharedBox() ?? _box;
      try {
        await box.put(_kLastWrittenHourKey, hourKey);
        await box.put(_kLastWrittenAtMs, now.millisecondsSinceEpoch);
      } catch (e) {
        // Skip the marker write on a benign close race — the Supabase
        // upsert above already succeeded, so we won't double-write on
        // the next tick even without the throttle marker.
        if (!isBenignBoxClosed(e)) rethrow;
      }
    } catch (e, s) {
      if (isBenignBoxClosed(e)) return;
      AppLogger.step.e('sourceHourly:writeFailed',
          fields: {'userId': userId}, error: e, stack: s);
      rethrow;
    }
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
