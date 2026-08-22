import 'package:intl/intl.dart';

/// One row per (user, hour-of-day) capturing what each step source reported.
///
/// Why per hour: gives us hourly granularity for charts ("steps by hour
/// today") AND a forensic trail of which sources are working on which
/// devices. If a Realme user reports "0 steps", we look at their
/// `source_step_hourly` entries to see whether the native sensor was
/// reading anything or whether HC was empty etc.
///
/// Why cumulative-since-midnight (not hourly delta):
///   - Cumulative is monotonic and idempotent — easy to upsert without
///     reading first.
///   - Delta-per-hour can be derived at read time as `H_total - (H-1)_total`.
///   - Avoids edge cases (midnight rollover, missing intermediate hours).
///
/// Doc ID convention: `{userId}_{hourKeyUtc}` — guarantees one row per
/// (user, hour). UTC so cross-timezone analytics line up cleanly.
class SourceStepHourlyLog {
  /// FK → users/{userId}
  final String userId;

  /// UTC start of this hour-bucket.
  final DateTime hourStart;

  /// Same as `hourStart` formatted `yyyy-MM-dd-HH` (UTC). Stored
  /// redundantly so hourly grouping / de-dup lookups are cheap
  /// without a range scan over the timestamp column.
  final String hourKey;

  // ── Per-source today-cumulative-steps as of this hour's last sync ──
  final int nativeSteps;
  final int healthConnectSteps;
  final int? googleFitSteps;

  // ── Aggregate (max of available sources) ──
  final int aggregateSteps;
  final String winningSource; // native | health_connect | google_fit | none

  // ── Per-source error trace (null if healthy) ──
  final String? nativeError;
  final String? healthConnectError;
  final String? googleFitError;

  // ── Device fingerprint (helps debug per-OEM step ingestion issues) ──
  final String deviceManufacturer; // e.g., 'samsung', 'realme', 'motorola'
  final String deviceModel;
  final String androidVersion;
  final String appVersion;

  final DateTime createdAt;
  final DateTime updatedAt;

  const SourceStepHourlyLog({
    required this.userId,
    required this.hourStart,
    required this.hourKey,
    required this.nativeSteps,
    required this.healthConnectSteps,
    this.googleFitSteps,
    required this.aggregateSteps,
    required this.winningSource,
    this.nativeError,
    this.healthConnectError,
    this.googleFitError,
    required this.deviceManufacturer,
    required this.deviceModel,
    required this.androidVersion,
    required this.appVersion,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Format a DateTime as `yyyy-MM-dd-HH` in UTC.
  static String hourKeyFor(DateTime t) {
    final utc = t.toUtc();
    return DateFormat('yyyy-MM-dd-HH').format(utc);
  }

  /// Truncate a DateTime to the start of its hour (UTC).
  static DateTime hourStartFor(DateTime t) {
    final utc = t.toUtc();
    return DateTime.utc(utc.year, utc.month, utc.day, utc.hour);
  }

  /// Deterministic doc id: `{userId}_{hourKey}`.
  static String docIdFor({required String userId, required DateTime t}) =>
      '${userId}_${hourKeyFor(t)}';

  /// Payload for `public.source_step_hourly` upsert.
  Map<String, dynamic> toSupabaseRow() => {
        'user_id': userId,
        'hour_start': hourStart.toUtc().toIso8601String(),
        'hour_key': hourKey,
        'native_steps': nativeSteps,
        'health_connect_steps': healthConnectSteps,
        'google_fit_steps': googleFitSteps,
        'aggregate': aggregateSteps,
        'winning_source': winningSource,
        'native_error': nativeError,
        'health_connect_error': healthConnectError,
        'google_fit_error': googleFitError,
        'device_manufacturer': deviceManufacturer,
        'device_model': deviceModel,
        'android_version': androidVersion,
        'app_version': appVersion,
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  /// Build from a Supabase `public.source_step_hourly` row.
  factory SourceStepHourlyLog.fromSupabaseRow(Map<String, dynamic> d) {
    DateTime parseTs(Object? raw) {
      if (raw == null) return DateTime.now();
      return DateTime.tryParse(raw.toString()) ?? DateTime.now();
    }

    return SourceStepHourlyLog(
      userId: d['user_id'] as String? ?? '',
      hourStart: parseTs(d['hour_start']),
      hourKey: d['hour_key'] as String? ?? '',
      nativeSteps: (d['native_steps'] as num?)?.toInt() ?? 0,
      healthConnectSteps: (d['health_connect_steps'] as num?)?.toInt() ?? 0,
      googleFitSteps: (d['google_fit_steps'] as num?)?.toInt(),
      aggregateSteps: (d['aggregate'] as num?)?.toInt() ?? 0,
      winningSource: d['winning_source'] as String? ?? 'none',
      nativeError: d['native_error'] as String?,
      healthConnectError: d['health_connect_error'] as String?,
      googleFitError: d['google_fit_error'] as String?,
      deviceManufacturer: d['device_manufacturer'] as String? ?? '',
      deviceModel: d['device_model'] as String? ?? '',
      androidVersion: d['android_version'] as String? ?? '',
      appVersion: d['app_version'] as String? ?? '',
      createdAt: parseTs(d['created_at']),
      updatedAt: parseTs(d['updated_at']),
    );
  }}
