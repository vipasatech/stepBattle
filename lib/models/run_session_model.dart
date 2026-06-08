import 'package:intl/intl.dart';

/// A finished or in-flight run/walk Track session.
///
/// Mirrors the `public.track_sessions` row from migration 0010 (+ 0011 for
/// path:jsonb, + 0012 for name). While a session is still running, [endedAt]
/// is null and the numeric counters reflect the latest in-app live state —
/// the row isn't persisted until End.
class RunSession {
  final String id;
  final String userId;

  /// Optional user-set name. Null/blank renders as [displayName] = "Run ·
  /// Jun 3, 11:12 AM" derived from [startedAt]. On save we auto-fill that
  /// default into the DB so the column is rarely null in practice.
  final String? name;

  final DateTime startedAt;
  final DateTime? endedAt;
  final int durationSeconds;
  final int steps;
  final double distanceMeters;
  final int calories;

  /// seconds per kilometre. null when distance is too small to be meaningful.
  final double? avgPaceSecPerKm;

  /// `gps` | `pedometer` | `mixed`. Source of truth for the distance number.
  final String source;

  /// Distance metres confirmed by GPS-haversine (gold-standard).
  final double distanceMetersVerified;

  /// Distance metres estimated from pedometer × stride during GPS gaps OR for
  /// indoor sessions with no GPS. Included in [distanceMeters]; surfaced as a
  /// note on the detail screen when > 0.
  final double distanceMetersEstimated;

  /// Steps the pedometer counted while GPS confirmed the user was stationary
  /// — NOT included in distance. Surfaced as a "X steps without confirmed
  /// movement" note when > 0.
  final int unverifiedSteps;

  /// In-flight session state, valued only for live emissions:
  ///   `indoor` | `gps_steady` | `gps_stationary` | `estimated`.
  /// Saved rows leave this empty — the detail screen derives its own notes
  /// from [distanceMetersEstimated] / [unverifiedSteps].
  final String trackState;

  /// Sampled GPS fixes accumulated during the session. Empty when running
  /// indoors / GPS denied. Stored as a GeoJSON LineString in `path` jsonb.
  final List<RunPoint> path;

  const RunSession({
    required this.id,
    required this.userId,
    this.name,
    required this.startedAt,
    this.endedAt,
    this.durationSeconds = 0,
    this.steps = 0,
    this.distanceMeters = 0,
    this.calories = 0,
    this.avgPaceSecPerKm,
    this.source = 'pedometer',
    this.distanceMetersVerified = 0,
    this.distanceMetersEstimated = 0,
    this.unverifiedSteps = 0,
    this.trackState = '',
    this.path = const [],
  });

  /// What the UI should render as the title. Falls back to a date-based label
  /// if [name] is null or blank (covers legacy rows + safety).
  String get displayName {
    final n = name?.trim() ?? '';
    if (n.isNotEmpty) return n;
    return autoDefaultNameFor(startedAt);
  }

  /// Canonical auto-default name shape, used both by the service when saving
  /// a blank name and by [displayName] as a fallback. Kept here so the two
  /// strings can never drift apart.
  static String autoDefaultNameFor(DateTime startedAt) {
    final local = startedAt.toLocal();
    final fmt = DateFormat('MMM d, h:mm a');
    return 'Run · ${fmt.format(local)}';
  }

  factory RunSession.fromSupabaseRow(Map<String, dynamic> d) {
    // `path` is a jsonb GeoJSON LineString or null. Parse coordinates back
    // into RunPoints so the detail screen can render the polyline. We don't
    // round-trip `ts`/`accuracy`/`source` per-point in v1 (that lives in
    // `point_meta` and isn't needed by the read-only detail map).
    final pathRaw = d['path'];
    final pathPoints = <RunPoint>[];
    if (pathRaw is Map &&
        pathRaw['type'] == 'LineString' &&
        pathRaw['coordinates'] is List) {
      for (final c in pathRaw['coordinates'] as List) {
        if (c is List && c.length >= 2) {
          final lng = (c[0] as num).toDouble();
          final lat = (c[1] as num).toDouble();
          pathPoints.add(RunPoint(
            lat: lat,
            lng: lng,
            ts: DateTime.fromMillisecondsSinceEpoch(0),
            accuracyMeters: 0,
          ));
        }
      }
    }
    return RunSession(
      id: d['id'] as String,
      userId: d['user_id'] as String,
      name: d['name'] as String?,
      startedAt: DateTime.parse(d['started_at'] as String),
      endedAt: d['ended_at'] == null
          ? null
          : DateTime.parse(d['ended_at'] as String),
      durationSeconds: (d['duration_seconds'] as num?)?.toInt() ?? 0,
      steps: (d['steps'] as num?)?.toInt() ?? 0,
      distanceMeters: (d['distance_meters'] as num?)?.toDouble() ?? 0,
      calories: (d['calories'] as num?)?.toInt() ?? 0,
      avgPaceSecPerKm: (d['avg_pace_sec_per_km'] as num?)?.toDouble(),
      source: d['source'] as String? ?? 'pedometer',
      distanceMetersVerified:
          (d['distance_meters_verified'] as num?)?.toDouble() ?? 0,
      distanceMetersEstimated:
          (d['distance_meters_estimated'] as num?)?.toDouble() ?? 0,
      unverifiedSteps: (d['unverified_steps'] as num?)?.toInt() ?? 0,
      path: pathPoints,
    );
  }

  RunSession copyWith({
    String? name,
    DateTime? endedAt,
    int? durationSeconds,
    int? steps,
    double? distanceMeters,
    int? calories,
    double? avgPaceSecPerKm,
    String? source,
    List<RunPoint>? path,
  }) {
    return RunSession(
      id: id,
      userId: userId,
      name: name ?? this.name,
      startedAt: startedAt,
      endedAt: endedAt ?? this.endedAt,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      steps: steps ?? this.steps,
      distanceMeters: distanceMeters ?? this.distanceMeters,
      calories: calories ?? this.calories,
      avgPaceSecPerKm: avgPaceSecPerKm ?? this.avgPaceSecPerKm,
      source: source ?? this.source,
      path: path ?? this.path,
    );
  }
}

/// One sampled GPS fix during a session.
class RunPoint {
  final double lat;
  final double lng;
  final DateTime ts;
  final double accuracyMeters;

  /// `gps` when sourced from the location stream; `pedometer` when this point
  /// was synthesised during a GPS-loss fallback (we don't actually store
  /// pedometer "points" — this distinguishes segments rendered as dashed).
  final String source;

  const RunPoint({
    required this.lat,
    required this.lng,
    required this.ts,
    required this.accuracyMeters,
    this.source = 'gps',
  });
}
