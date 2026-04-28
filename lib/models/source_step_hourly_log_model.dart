import 'package:cloud_firestore/cloud_firestore.dart';
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
  /// redundantly to make Firestore filtering by hour fast without
  /// a Timestamp comparison index.
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

  Map<String, dynamic> toFirestore() => {
        'userId': userId,
        'hourStart': Timestamp.fromDate(hourStart),
        'hourKey': hourKey,
        'nativeSteps': nativeSteps,
        'healthConnectSteps': healthConnectSteps,
        'googleFitSteps': googleFitSteps,
        'aggregateSteps': aggregateSteps,
        'winningSource': winningSource,
        'nativeError': nativeError,
        'healthConnectError': healthConnectError,
        'googleFitError': googleFitError,
        'deviceManufacturer': deviceManufacturer,
        'deviceModel': deviceModel,
        'androidVersion': androidVersion,
        'appVersion': appVersion,
        'createdAt': Timestamp.fromDate(createdAt),
        'updatedAt': Timestamp.fromDate(updatedAt),
      };

  factory SourceStepHourlyLog.fromFirestore(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    return SourceStepHourlyLog(
      userId: d['userId'] as String? ?? '',
      hourStart: (d['hourStart'] as Timestamp?)?.toDate() ?? DateTime.now(),
      hourKey: d['hourKey'] as String? ?? '',
      nativeSteps: d['nativeSteps'] as int? ?? 0,
      healthConnectSteps: d['healthConnectSteps'] as int? ?? 0,
      googleFitSteps: d['googleFitSteps'] as int?,
      aggregateSteps: d['aggregateSteps'] as int? ?? 0,
      winningSource: d['winningSource'] as String? ?? 'none',
      nativeError: d['nativeError'] as String?,
      healthConnectError: d['healthConnectError'] as String?,
      googleFitError: d['googleFitError'] as String?,
      deviceManufacturer: d['deviceManufacturer'] as String? ?? '',
      deviceModel: d['deviceModel'] as String? ?? '',
      androidVersion: d['androidVersion'] as String? ?? '',
      appVersion: d['appVersion'] as String? ?? '',
      createdAt: (d['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (d['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }
}
