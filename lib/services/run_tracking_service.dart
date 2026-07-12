import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

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

  // Hive keys that mirror the live session's key metrics so the
  // background-service isolate can render a rich lock-screen
  // notification (Strava-style: time / pace / distance / steps)
  // without needing to reach back into this service's memory.
  static const _kActiveTrackSteps = 'active_track_steps';
  static const _kActiveTrackDistanceM = 'active_track_distance_m';
  static const _kActiveTrackPaceSecKm = 'active_track_pace_sec_km';
  static const _kActiveTrackCalories = 'active_track_calories';

  // Exposed so `background_sync._renderTrack` can key off the same
  // strings without depending back on this whole file.
  static const activeTrackStartedAtKey = _kActiveStartedAt;
  static const activeTrackStepsKey = _kActiveTrackSteps;
  static const activeTrackDistanceMKey = _kActiveTrackDistanceM;
  static const activeTrackPaceSecKmKey = _kActiveTrackPaceSecKm;
  static const activeTrackCaloriesKey = _kActiveTrackCalories;

  /// Prefix for pending-upload session payloads. Each ended session is
  /// stamped into Hive under `pendingTrackPrefix + <uuid>` BEFORE we
  /// attempt the Supabase insert; the entry is deleted only after the
  /// insert succeeds. [syncPending] walks every key with this prefix on
  /// every hub-open + app-launch and retries the upload. This is what
  /// prevents data loss when the network is flaky (screen off for 20+
  /// min → auth token stale → first end() insert fails — without local
  /// persistence the run is gone).
  static const String pendingTrackPrefix = 'pending_track_session__';

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

  /// Finalize the session and persist it.
  ///
  /// Save flow (local-first):
  ///   1. Build the row payload.
  ///   2. **Stamp the payload into Hive** under
  ///      [pendingTrackPrefix] + uuid. This is the durability point —
  ///      if the app crashes after this, the run is recoverable.
  ///   3. Attempt the Supabase insert. On success: delete the Hive
  ///      entry. On failure: leave it; [syncPending] will retry on
  ///      every subsequent hub-open / app-launch / background tick.
  ///
  /// The returned [EndResult] tells the caller whether the run was
  /// persisted server-side ([EndResult.synced]) or only locally
  /// ([EndResult.pending]) so the UI can show an honest message instead
  /// of the old silent-fail "Saved" lie.
  ///
  /// Optional [description] + [mediaUrls] come from the Save Activity
  /// page (note text and any uploaded photo URLs). Both are persisted
  /// into the row payload so the local Hive copy carries them too —
  /// `syncPending()` doesn't strip them on retry.
  Future<EndResult?> end({
    String? description,
    List<String> mediaUrls = const [],
  }) async {
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

    final persistedName = (_name == null || _name!.isEmpty)
        ? RunSession.autoDefaultNameFor(startedAt)
        : _name!;

    final payload = <String, dynamic>{
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
      if (description != null && description.trim().isNotEmpty)
        'description': description.trim(),
      if (mediaUrls.isNotEmpty) 'media_urls': mediaUrls,
    };

    // Local-first: stamp into Hive BEFORE the network attempt so a
    // crash / kill after this point is recoverable. Key is a millis-
    // suffixed string (unique per device); the entry survives until
    // [syncPending] confirms a server insert.
    final pendingKey =
        '$pendingTrackPrefix${endedAt.microsecondsSinceEpoch}_${startedAt.microsecondsSinceEpoch}';
    try {
      await Hive.box(NativeStepService.boxName).put(pendingKey, payload);
    } catch (e, s) {
      AppLogger.track.e('runTracking:hivePersistFailed',
          error: e, stack: s);
      // Continue anyway — Hive failure is exotic; the live network
      // insert below is still attempted. If that fails too, the caller
      // sees `pending` status but we've genuinely lost data. Log loud.
    }

    String? newId;
    bool synced = false;
    try {
      final row = await _client
          .from('track_sessions')
          .insert(payload)
          .select('id')
          .single();
      newId = row['id'] as String?;
      synced = newId != null;
      if (synced) {
        // Server confirmed → drop the local copy.
        try {
          await Hive.box(NativeStepService.boxName).delete(pendingKey);
        } catch (_) {}
      }
    } catch (e, s) {
      AppLogger.track.e('runTracking:insertFailed',
          fields: {'pendingKey': pendingKey}, error: e, stack: s);
      // pendingKey row stays in Hive — `syncPending` will retry.
    }

    try {
      final box = Hive.box(NativeStepService.boxName);
      // Clearing every key that made the notification "live" — the
      // background isolate's render helper treats any-missing as
      // "session inactive" and cancels the notification.
      await box.delete(_kActiveStartedAt);
      await box.delete(_kActiveTrackSteps);
      await box.delete(_kActiveTrackDistanceM);
      await box.delete(_kActiveTrackPaceSecKm);
      await box.delete(_kActiveTrackCalories);
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
      'synced': synced,
    });
    return EndResult(
      session: saved,
      synced: synced,
      pendingKey: synced ? null : pendingKey,
    );
  }

  /// Sweep Hive for any [pendingTrackPrefix] entries and try to upload
  /// them. Safe to call repeatedly; only deletes on a confirmed insert.
  /// Returns the count of newly-synced sessions so the caller can decide
  /// whether to refresh its UI.
  ///
  /// CALL SITES: TrackHub initState, app launch (post-auth), and the
  /// BackgroundSync periodic tick. Idempotent under concurrent callers
  /// because each row carries a unique payload and the server's
  /// PRIMARY KEY (id) is generated on insert — a re-upload after a
  /// partial failure that DID land on the server would create a
  /// duplicate row. We accept that risk for now (rare; payload includes
  /// started_at so duplicates are easy to spot in the UI). A future
  /// hardening would add a client_dedupe_key column with a unique
  /// constraint.
  /// Upload [photoBytes] to the public `track-media` Storage bucket
  /// under the signed-in user's folder. Returns the resulting public
  /// URLs in the same order as the input — empty when nothing
  /// uploaded. Throws on transport failure so the caller can keep the
  /// user on the Save Activity page instead of half-saving the run.
  Future<List<String>> uploadTrackMedia({
    required String userId,
    required List<List<int>> photoBytes,
  }) async {
    if (photoBytes.isEmpty) return const [];
    final urls = <String>[];
    final stamp = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < photoBytes.length; i++) {
      // Path shape: `<uid>/<millis>_<i>.jpg`. RLS in migration 0022
      // forces the first folder to equal `auth.uid()`.
      final path = '$userId/${stamp}_$i.jpg';
      try {
        await _client.storage.from('track-media').uploadBinary(
              path,
              Uint8List.fromList(photoBytes[i]),
              fileOptions: const FileOptions(
                contentType: 'image/jpeg',
                upsert: false,
              ),
            );
        urls.add(_client.storage.from('track-media').getPublicUrl(path));
      } catch (e, s) {
        AppLogger.track.e('runTracking:mediaUploadFailed',
            fields: {'index': i, 'path': path}, error: e, stack: s);
        rethrow;
      }
    }
    return urls;
  }

  Future<int> syncPending() async {
    final box = Hive.box(NativeStepService.boxName);
    final keys = box.keys
        .whereType<String>()
        .where((k) => k.startsWith(pendingTrackPrefix))
        .toList(growable: false);
    if (keys.isEmpty) return 0;

    int synced = 0;
    for (final key in keys) {
      final raw = box.get(key);
      if (raw is! Map) {
        // Corrupted entry → drop it so we don't loop on it.
        await box.delete(key);
        continue;
      }
      final payload = Map<String, dynamic>.from(raw);
      try {
        await _client.from('track_sessions').insert(payload);
        await box.delete(key);
        synced++;
        AppLogger.track
            .i('runTracking:pendingSynced', fields: {'key': key});
      } catch (e) {
        AppLogger.track.w('runTracking:pendingRetryFailed',
            fields: {'key': key, 'err': e.toString()});
        // Leave it in Hive for the next sweep.
      }
    }
    return synced;
  }

  /// Number of un-synced sessions waiting in Hive. The hub can surface
  /// this as a small badge ("3 sessions waiting to sync") so the user
  /// knows their runs aren't lost.
  int pendingCount() {
    final box = Hive.box(NativeStepService.boxName);
    return box.keys
        .whereType<String>()
        .where((k) => k.startsWith(pendingTrackPrefix))
        .length;
  }


  /// Read pending-but-not-yet-synced sessions from Hive. These are the
  /// rows that `end()` stamped locally but whose Supabase insert failed
  /// or hasn't run yet. Surfaced in the history list with a "Pending
  /// sync" pill so the user sees their run isn't lost.
  List<RunSession> getPendingSessions({required String userId}) {
    final box = Hive.box(NativeStepService.boxName);
    final out = <RunSession>[];
    for (final key in box.keys.whereType<String>()) {
      if (!key.startsWith(pendingTrackPrefix)) continue;
      final raw = box.get(key);
      if (raw is! Map) continue;
      try {
        final payload = Map<String, dynamic>.from(raw);
        // Filter to the signed-in user so a logout/login on the same
        // device doesn't surface someone else's pending row.
        if (payload['user_id'] != userId) continue;
        out.add(RunSession.fromPendingPayload(payload, key));
      } catch (e, s) {
        AppLogger.track.w(
          'runTracking:pendingParseFailed',
          fields: {'key': key, 'error': e.toString()},
        );
        AppLogger.track.e('runTracking:pendingParseStack',
            error: e, stack: s);
      }
    }
    return out;
  }

  Future<List<RunSession>> getHistory({required String userId, int limit = 20}) async {
    // Pending (local-only) sessions first — most recent end times bubble
    // to the top of the merged list so a just-finished run that hasn't
    // synced yet shows up immediately instead of vanishing.
    final pending = getPendingSessions(userId: userId);

    List<RunSession> synced = const [];
    try {
      final rows = await _client
          .from('track_sessions')
          .select()
          .eq('user_id', userId)
          .not('ended_at', 'is', null)
          .order('started_at', ascending: false)
          .limit(limit);
      synced = (rows as List)
          .map((r) => RunSession.fromSupabaseRow(r as Map<String, dynamic>))
          .toList();
    } catch (e, s) {
      AppLogger.track.e('runTracking:historyFailed', error: e, stack: s);
      // Fall through so we still return whatever's in the local pending
      // queue — the user still sees their unsynced runs even when the
      // server fetch fails.
    }

    final merged = [...pending, ...synced];
    merged.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return merged;
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

    // Mirror the four notification metrics into Hive so the
    // foreground-service isolate (see background_sync._renderTrack)
    // can render a Strava-style lock-screen notification without
    // cross-isolate messaging. Best-effort — a Hive write hiccup
    // shouldn't affect the live UI.
    try {
      final box = Hive.box(NativeStepService.boxName);
      box.put(_kActiveTrackSteps, _currentSteps);
      box.put(_kActiveTrackDistanceM, totalDistance);
      // Store null-as-null so the notification can distinguish
      // "warming up, no pace yet" from "pace = 0".
      box.put(_kActiveTrackPaceSecKm, pace);
      box.put(
        _kActiveTrackCalories,
        _latest!.calories,
      );
    } catch (_) {/* ignore transient Hive errors */}
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

  /// Patch an existing SAVED session — used by the Edit page to update
  /// the user-set name, the description, and/or the media_urls array.
  ///
  /// Any field left null is skipped, so the caller can update a subset
  /// without clobbering the rest. Pass an empty string for
  /// [description] to clear it back to NULL. Pass an empty list for
  /// [mediaUrls] to strip every attached photo.
  Future<bool> updateSession({
    required String sessionId,
    String? name,
    String? description,
    List<String>? mediaUrls,
  }) async {
    try {
      final updates = <String, dynamic>{};
      if (name != null) {
        final clean = _cleanName(name);
        if (clean != null) updates['name'] = clean;
      }
      if (description != null) {
        final trimmed = description.trim();
        updates['description'] = trimmed.isEmpty ? null : trimmed;
      }
      if (mediaUrls != null) {
        updates['media_urls'] = mediaUrls;
      }
      if (updates.isEmpty) return true;

      await _client
          .from('track_sessions')
          .update(updates)
          .eq('id', sessionId);
      AppLogger.track.i(
        'runTracking:updated',
        fields: {'id': sessionId, 'fields': updates.keys.toList()},
      );
      return true;
    } catch (e, s) {
      AppLogger.track
          .e('runTracking:updateFailed', error: e, stack: s);
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

/// Outcome of [RunTrackingService.end]. The UI inspects [synced] to
/// pick between "Saved" and "Will sync when online" messaging — the
/// previous version returned a [RunSession] directly which silently
/// masked failed inserts.
class EndResult {
  /// The session as it was finalised in-memory. `id` will be 'local'
  /// when the server insert failed; the canonical row id is only
  /// available after a successful insert.
  final RunSession session;

  /// True iff the server confirmed the insert. False means the row is
  /// still pending in Hive and will be retried by [syncPending].
  final bool synced;

  /// Hive key under which the pending payload lives, when [synced] is
  /// false. Null on success. Useful for explicit retry UI.
  final String? pendingKey;

  const EndResult({
    required this.session,
    required this.synced,
    required this.pendingKey,
  });
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
