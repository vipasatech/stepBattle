import 'dart:async';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/run_session_model.dart';
import '../utils/app_logger.dart';
import 'background_sync.dart';
import 'native_step_service.dart';

/// Trust state of the in-flight session. Drives the live-screen pill and
/// determines which accumulator any new step-delta lands in.
///   • indoor         — no GPS fix ever in this session (treadmill, basement)
///   • gpsSteady      — recent GPS fix, last speed > _stationarySpeedMs
///   • gpsStationary  — recent GPS fix, last speed ≈ 0 (user not moving)
///   • estimated      — had a fix at some point, GPS has now been silent
///                      past the loss threshold (tunnel / dense cover)
enum _TrackState { indoor, gpsSteady, gpsStationary, estimated }

/// Owns one live "Track" session: subscribes to the GPS stream, accumulates
/// distance + steps + kcal, falls back to pedometer-estimated distance when
/// GPS is unavailable/inaccurate, persists the result on End.
///
/// State is exposed as a broadcast `Stream<RunSession>` that the UI
/// subscribes to. Only one session at a time. The active state is also
/// mirrored to Hive so the foreground service can switch its notification to
/// the TRACK layout.
class RunTrackingService {
  final SupabaseClient _client;
  final NativeStepService _native;

  static const double _strideMeters = 0.762; // default stride; calibrate later
  // Accept fixes up to 50m accuracy. Strava-class apps sit around this number;
  // 25m is too strict for assisted-GPS / Wi-Fi triangulated fixes that are
  // common indoors or near tall buildings — they get rejected and the path
  // stays empty even when GPS is actually working.
  static const double _accuracyThresholdMeters = 50;
  static const Duration _gpsLostThreshold = Duration(seconds: 15);
  static const double _kcalPerStep = 0.04;

  // Hive keys (live in the existing `step_tracker` box so we don't have to
  // open a new one). Read by background_sync.dart's notification renderer.
  static const _kActiveStartedAt = 'active_track_started_at';

  /// Hard cap on session names (matches the text-field maxLength).
  static const int nameMaxLength = 50;

  /// GPS speed below this is treated as stationary (m/s). Walking pace is
  /// ~1.2 m/s; standing still produces noisy speeds < ~0.5.
  static const double _stationarySpeedMs = 0.5;

  StreamSubscription<Position>? _gpsSub;
  Timer? _periodic;

  String? _userId;
  String? _name;
  DateTime? _startedAt;
  int _baselineSteps = 0;
  int _currentSteps = 0;

  // Distance accounting split by trust level. distanceMeters (total) is the
  // sum of these two; detail screen exposes them separately for honest
  // disclosure when estimated > 0.
  double _verifiedMeters = 0;       // from GPS-haversine while moving
  double _estimatedMeters = 0;      // from pedometer × stride (indoor / GPS gap)
  int _unverifiedSteps = 0;         // steps counted while GPS confirmed stationary

  Position? _lastAcceptedFix;
  DateTime? _lastFixAt;
  // Snapshot of `_currentSteps` at the moment the state last changed. Used
  // to compute the step-delta to attribute to the current state.
  int _stepsAtStateChange = 0;
  _TrackState _state = _TrackState.indoor;

  final List<RunPoint> _path = [];

  // Nullable: emitting `null` is how end() tells subscribers "no active
  // session anymore". Stale non-null values would otherwise be cached on the
  // Riverpod StreamProvider and the Hub would keep showing "Open active
  // session" after the user already ended one.
  final StreamController<RunSession?> _stateController =
      StreamController<RunSession?>.broadcast();

  RunSession? _latest;

  RunTrackingService({
    required NativeStepService native,
    SupabaseClient? client,
  })  : _native = native,
        _client = client ?? Supabase.instance.client;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  Stream<RunSession?> get stateStream => _stateController.stream;
  RunSession? get latest => _latest;
  bool get isRunning => _startedAt != null;

  /// Begin a new session. Assumes the caller has already obtained
  /// `ACCESS_FINE_LOCATION` (the FAB tap flow handles that in the UI).
  /// [name] is optional; if null/blank we auto-default on save in [end].
  /// Returns true on success, false if a session was already running.
  Future<bool> start({required String userId, String? name}) async {
    if (_startedAt != null) return false;

    _userId = userId;
    _name = _cleanName(name);
    _startedAt = DateTime.now();
    _baselineSteps = _native.getTodaySteps();
    _currentSteps = 0;
    _verifiedMeters = 0;
    _estimatedMeters = 0;
    _unverifiedSteps = 0;
    _lastAcceptedFix = null;
    _lastFixAt = null;
    _stepsAtStateChange = 0;
    _state = _TrackState.indoor;
    _path.clear();

    try {
      await Hive.box(NativeStepService.boxName)
          .put(_kActiveStartedAt, _startedAt!.millisecondsSinceEpoch);
    } catch (_) {}

    // Subscribe to GPS. If permission isn't granted yet the stream throws;
    // we still let the session run as pedometer-only.
    try {
      _gpsSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 5,
        ),
      ).listen(_onPosition, onError: (e) {
        AppLogger.track.w('runTracking:gpsError', fields: {'error': e.toString()});
      });
    } catch (e, s) {
      AppLogger.track.e('runTracking:gpsSubscribeFailed', error: e, stack: s);
    }

    _periodic = Timer.periodic(const Duration(seconds: 2), _onTick);
    BackgroundSync.nudge();
    _emit();
    AppLogger.track.i('runTracking:started', fields: {'uid': userId});
    return true;
  }

  /// Finalize the session, write it to Supabase, return the saved row.
  Future<RunSession?> end() async {
    if (_startedAt == null) return null;
    _gpsSub?.cancel();
    _gpsSub = null;
    _periodic?.cancel();
    _periodic = null;

    // One last reconciliation tick.
    _onTick();

    final userId = _userId!;
    final startedAt = _startedAt!;
    final endedAt = DateTime.now();
    final duration = endedAt.difference(startedAt).inSeconds;
    final totalDistance = _verifiedMeters + _estimatedMeters;
    final pace = totalDistance > 100
        ? duration / (totalDistance / 1000.0)
        : null;
    final source = _computeSource();

    // PostGIS column accepts GeoJSON via PostgREST. Skip if < 2 points.
    final pathGeoJson = _path.length >= 2
        ? {
            'type': 'LineString',
            'coordinates':
                _path.map((p) => [p.lng, p.lat]).toList(growable: false),
          }
        : null;
    final pointMeta = _path
        .map((p) => {
              'ts': p.ts.millisecondsSinceEpoch,
              'accuracy': p.accuracyMeters,
              'source': p.source,
            })
        .toList(growable: false);

    // If the user never set a name (or cleared it), persist the canonical
    // auto-default so the row is always renderable without UI-side fallback
    // gymnastics. Matches RunSession.autoDefaultNameFor.
    final persistedName = (_name == null || _name!.isEmpty)
        ? RunSession.autoDefaultNameFor(startedAt)
        : _name!;

    String? newId;
    try {
      final row = await _client.from('track_sessions').insert({
        'user_id': userId,
        'name': persistedName,
        'started_at': startedAt.toUtc().toIso8601String(),
        'ended_at': endedAt.toUtc().toIso8601String(),
        'duration_seconds': duration,
        'steps': _currentSteps,
        'distance_meters': totalDistance,
        'distance_meters_verified': _verifiedMeters,
        'distance_meters_estimated': _estimatedMeters,
        'unverified_steps': _unverifiedSteps,
        'calories': (_currentSteps * _kcalPerStep).round(),
        'avg_pace_sec_per_km': pace,
        'path': pathGeoJson,
        'point_meta': pointMeta.isEmpty ? null : pointMeta,
        'source': source,
      }).select('id').single();
      newId = row['id'] as String?;
    } catch (e, s) {
      AppLogger.track.e('runTracking:insertFailed', error: e, stack: s);
    }

    try {
      await Hive.box(NativeStepService.boxName).delete(_kActiveStartedAt);
    } catch (_) {}

    final saved = RunSession(
      id: newId ?? 'local',
      userId: userId,
      name: persistedName,
      startedAt: startedAt,
      endedAt: endedAt,
      durationSeconds: duration,
      steps: _currentSteps,
      distanceMeters: totalDistance,
      calories: (_currentSteps * _kcalPerStep).round(),
      avgPaceSecPerKm: pace,
      source: source,
      distanceMetersVerified: _verifiedMeters,
      distanceMetersEstimated: _estimatedMeters,
      unverifiedSteps: _unverifiedSteps,
      path: List.unmodifiable(_path),
    );

    _userId = null;
    _name = null;
    _startedAt = null;
    _latest = null;
    // Signal subscribers (TrackHub, TrackLiveScreen, FAB) that the session
    // is over so they stop rendering the "active" UI immediately.
    if (!_stateController.isClosed) _stateController.add(null);
    BackgroundSync.nudge();
    AppLogger.track.i('runTracking:ended', fields: {
      'durationSec': duration,
      'distanceM': totalDistance.round(),
      'verifiedM': _verifiedMeters.round(),
      'estimatedM': _estimatedMeters.round(),
      'steps': _currentSteps,
      'unverifiedSteps': _unverifiedSteps,
      'source': source,
    });
    return saved;
  }

  Future<List<RunSession>> getHistory({required String userId, int limit = 20}) async {
    try {
      final rows = await _client
          .from('track_sessions')
          .select()
          .eq('user_id', userId)
          .not('ended_at', 'is', null)
          .order('started_at', ascending: false)
          .limit(limit);
      return (rows as List)
          .map((r) => RunSession.fromSupabaseRow(r as Map<String, dynamic>))
          .toList();
    } catch (e, s) {
      AppLogger.track.e('runTracking:historyFailed', error: e, stack: s);
      return const [];
    }
  }

  void dispose() {
    _gpsSub?.cancel();
    _periodic?.cancel();
    _stateController.close();
  }

  // ---------------------------------------------------------------------------
  // Internal — GPS + fallback state machine
  // ---------------------------------------------------------------------------

  void _onPosition(Position p) {
    // Every position event is logged so we can see in track.log what the
    // device is actually producing — invaluable for diagnosing "GPS isn't
    // working" reports.
    if (p.accuracy <= 0 || p.accuracy > _accuracyThresholdMeters) {
      AppLogger.track.d('gpsReject', fields: {
        'accuracy': p.accuracy,
        'reason': p.accuracy <= 0 ? 'no_fix' : 'over_threshold',
        'threshold': _accuracyThresholdMeters,
      });
      return;
    }
    _lastFixAt = DateTime.now();

    // Settle any pending step-delta to whatever accumulator the previous
    // state was filling — BEFORE we transition. Otherwise steps walked
    // during INDOOR / ESTIMATED would silently get reattributed to GPS.
    _flushStepDelta();

    final speed = (p.speed.isFinite && p.speed >= 0) ? p.speed : 0.0;
    final newState = speed > _stationarySpeedMs
        ? _TrackState.gpsSteady
        : _TrackState.gpsStationary;

    // Compute the GPS segment for distance accounting. Only credit it as
    // "verified" when we're already in (or transitioning to) STEADY; a
    // stationary fix's segment is effectively noise.
    double segment = 0;
    if (_lastAcceptedFix != null) {
      segment = Geolocator.distanceBetween(
        _lastAcceptedFix!.latitude,
        _lastAcceptedFix!.longitude,
        p.latitude,
        p.longitude,
      );
      if (newState == _TrackState.gpsSteady) {
        _verifiedMeters += segment;
      }
    }
    _lastAcceptedFix = p;
    _path.add(RunPoint(
      lat: p.latitude,
      lng: p.longitude,
      ts: DateTime.now(),
      accuracyMeters: p.accuracy,
      source: 'gps',
    ));

    _setState(newState);

    AppLogger.track.d('gpsAccept', fields: {
      'accuracy': p.accuracy,
      'speedMs': speed,
      'segmentM': segment.round(),
      'pathLen': _path.length,
      'state': newState.name,
      'verifiedM': _verifiedMeters.round(),
    });
    _emit();
  }

  void _onTick([Timer? _]) {
    if (_startedAt == null) return;
    final today = _native.getTodaySteps();
    final delta = today - _baselineSteps;
    _currentSteps = delta < 0 ? 0 : delta;

    // If GPS is silent past the loss threshold AND we previously saw at least
    // one fix, demote to ESTIMATED (tunnel / dense cover during real motion).
    // If we never had a fix, stay INDOOR. If we were STATIONARY and there's no
    // fresh fix, stay STATIONARY — distanceFilter=5 means a non-moving user
    // simply doesn't get more fixes; that's not GPS-lost, just not-moving.
    final fixAge = _lastFixAt == null
        ? null
        : DateTime.now().difference(_lastFixAt!);
    if (_state == _TrackState.gpsSteady &&
        fixAge != null &&
        fixAge > _gpsLostThreshold) {
      _flushStepDelta();
      _setState(_TrackState.estimated);
    }

    _flushStepDelta();
    _emit();
  }

  /// Attribute any step-delta accrued since [_stepsAtStateChange] to the
  /// appropriate accumulator for the current state, then re-anchor.
  ///   • INDOOR    / ESTIMATED → distance estimated from steps × stride.
  ///   • STATIONARY            → steps counted as "unverified" (no distance).
  ///   • STEADY                → discarded; GPS already provides distance.
  void _flushStepDelta() {
    final stepDelta = _currentSteps - _stepsAtStateChange;
    if (stepDelta <= 0) return;
    switch (_state) {
      case _TrackState.indoor:
      case _TrackState.estimated:
        _estimatedMeters += stepDelta * _strideMeters;
        break;
      case _TrackState.gpsStationary:
        _unverifiedSteps += stepDelta;
        break;
      case _TrackState.gpsSteady:
        // No-op — GPS provides distance during steady movement.
        break;
    }
    _stepsAtStateChange = _currentSteps;
  }

  /// Transition into [next], re-anchoring the step counter so the next
  /// `_flushStepDelta` starts from zero in the new accumulator.
  void _setState(_TrackState next) {
    if (_state == next) return;
    _state = next;
    _stepsAtStateChange = _currentSteps;
  }

  void _emit() {
    if (_startedAt == null) return;
    final now = DateTime.now();
    final dur = now.difference(_startedAt!).inSeconds;
    final totalDistance = _verifiedMeters + _estimatedMeters;
    final pace = totalDistance > 100
        ? dur / (totalDistance / 1000.0)
        : null;
    final source = _computeSource();
    _latest = RunSession(
      id: 'live',
      userId: _userId ?? '',
      name: _name,
      startedAt: _startedAt!,
      durationSeconds: dur,
      steps: _currentSteps,
      distanceMeters: totalDistance,
      calories: (_currentSteps * _kcalPerStep).round(),
      avgPaceSecPerKm: pace,
      source: source,
      distanceMetersVerified: _verifiedMeters,
      distanceMetersEstimated: _estimatedMeters,
      unverifiedSteps: _unverifiedSteps,
      trackState: _state.name,
      path: List.unmodifiable(_path),
    );
    if (!_stateController.isClosed) _stateController.add(_latest!);
  }

  String _computeSource() {
    if (_verifiedMeters > 0 && _estimatedMeters > 0) return 'mixed';
    if (_verifiedMeters > 0) return 'gps';
    return 'pedometer';
  }

  // ---------------------------------------------------------------------------
  // Naming (mid-run + post-save)
  // ---------------------------------------------------------------------------

  /// Trim + cap to [nameMaxLength]. Returns null when the result is empty so
  /// the auto-default logic in [end] kicks in.
  String? _cleanName(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    return trimmed.length > nameMaxLength
        ? trimmed.substring(0, nameMaxLength)
        : trimmed;
  }

  /// Update the name of the in-flight session and re-emit so the live screen
  /// (and the foreground notification, via a subsequent nudge) refreshes. No
  /// network call — the row isn't written until [end].
  void setName(String? raw) {
    if (_startedAt == null) return;
    _name = _cleanName(raw);
    _emit();
  }

  /// Rename a SAVED session. Blank → auto-default based on the row's
  /// started_at. Returns true on success.
  Future<bool> renameSession({
    required String sessionId,
    required String? newName,
    DateTime? startedAtForFallback,
  }) async {
    try {
      var clean = _cleanName(newName);
      // Blank → reset to canonical auto-default.
      if (clean == null) {
        final ts = startedAtForFallback;
        if (ts == null) {
          // We don't know started_at; fetch it once.
          final row = await _client
              .from('track_sessions')
              .select('started_at')
              .eq('id', sessionId)
              .maybeSingle();
          final s = (row?['started_at'] as String?);
          final parsed = s == null ? DateTime.now() : DateTime.parse(s);
          clean = RunSession.autoDefaultNameFor(parsed);
        } else {
          clean = RunSession.autoDefaultNameFor(ts);
        }
      }
      await _client
          .from('track_sessions')
          .update({'name': clean}).eq('id', sessionId);
      AppLogger.track
          .i('runTracking:renamed', fields: {'id': sessionId, 'name': clean});
      return true;
    } catch (e, s) {
      AppLogger.track
          .e('runTracking:renameFailed', error: e, stack: s);
      return false;
    }
  }

  /// Permanently delete a saved session. Returns true on success.
  Future<bool> deleteSession(String sessionId) async {
    try {
      await _client.from('track_sessions').delete().eq('id', sessionId);
      AppLogger.track.i('runTracking:deleted', fields: {'id': sessionId});
      return true;
    } catch (e, s) {
      AppLogger.track.e('runTracking:deleteFailed', error: e, stack: s);
      return false;
    }
  }

  /// Fetch one saved session by id (for the detail screen).
  Future<RunSession?> getById(String sessionId) async {
    try {
      final row = await _client
          .from('track_sessions')
          .select()
          .eq('id', sessionId)
          .maybeSingle();
      if (row == null) return null;
      return RunSession.fromSupabaseRow(row);
    } catch (e, s) {
      AppLogger.track
          .e('runTracking:getByIdFailed', error: e, stack: s);
      return null;
    }
  }
}

/// Whether a Track session is currently active, derived from the Hive flag
/// that the service writes. Reading from Hive lets the FAB show its active
/// state even before the service is in memory (e.g., immediately after a
/// cold launch with a prior session still running on the foreground isolate).
bool isTrackActiveFromHive() {
  try {
    final ms = Hive.box(NativeStepService.boxName)
        .get(RunTrackingService._kActiveStartedAt);
    return ms is int;
  } catch (_) {
    return false;
  }
}

/// Read the start time of an active session straight from Hive (used by the
/// notification renderer in [background_sync.dart] without needing the
/// service instance).
DateTime? activeTrackStartedAtFromHive() {
  try {
    final ms = Hive.box(NativeStepService.boxName)
        .get(RunTrackingService._kActiveStartedAt);
    if (ms is int) {
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
  } catch (_) {}
  return null;
}

// math import kept for distance helper if we ever need haversine without
// Geolocator's helper (e.g., from the headless isolate without the plugin).
// ignore: unused_element
double _haversineMeters(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final p1 = lat1 * math.pi / 180;
  final p2 = lat2 * math.pi / 180;
  final dp = (lat2 - lat1) * math.pi / 180;
  final dl = (lon2 - lon1) * math.pi / 180;
  final a = math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
