import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_3d_controller/flutter_3d_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/colors.dart';
import '../../models/battle_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/battle_provider.dart';
import '../../providers/character_3d_provider.dart';
import '../../services/battleground_tile.dart';
import '../../utils/app_logger.dart';
import '../../widgets/animated_character_viewer.dart';
import 'widgets/countdown_ring.dart';
import 'widgets/leaderboard_pill.dart';

/// Battle-ground arena — live 3D city scene.
///
/// The screen mounts a single [Flutter3DViewer] loading
/// `assets/images/battleground/cityView/city_arena_{tod}.glb`. The variant
/// is picked from the device wall clock at build time (see
/// [BattlegroundTimeOfDay.forNow]) — no server round-trip.
///
/// M5 (dual camera modes): toggle between top-down and third-person
/// eye-level views. Each mode configures its own camera orbit + target on
/// the [Flutter3DController]. Zoom / pan clamps are model-viewer-native
/// (initial position only for now — hard clamping via JS bridge lands as
/// M5c once we validate the basic mode swap works on device).
///
/// Locking philosophy: the user should never see outside the two building
/// rows. Only "up" (sky) is a free direction — the camera stays boxed
/// between the buildings in both modes.
class BattleGroundScreen extends ConsumerStatefulWidget {
  final String battleId;

  const BattleGroundScreen({super.key, required this.battleId});

  @override
  ConsumerState<BattleGroundScreen> createState() =>
      _BattleGroundScreenState();
}

/// Which camera framing the arena is currently using.
enum ArenaCameraMode {
  /// Bird's-eye top-down of the whole block. Users can zoom in on details
  /// but the initial zoom-out shows the full arena between building rows.
  topView,

  /// Eye-level walking view down the road, framed by buildings on both
  /// sides. Users can zoom in on cars / benches / trees; zoom-out reset
  /// returns to this framing.
  thirdPerson,
}

/// State of the arena-open cinematic sweep.
enum _CinematicPhase {
  /// Cinematic hasn't kicked off yet — waiting for onLoad.
  idle,

  /// Camera visiting the TOP user (rank #1). Their Taunt animation plays.
  atTop,

  /// Camera visiting the BOTTOM user (rank last).
  atBottom,

  /// Camera arriving at the main user (You).
  atMain,

  /// Cinematic finished (or skipped). Normal gestures active.
  done,
}

/// Slot Y positions (Blender coords) — must match the arena GLB bake.
/// Index 0 = backmost/south end; index 5 = frontmost/north end. Ranks
/// assigned in DESCENDING step count: #1 → slot 5, last → slot 0.
const List<double> _slotBlenderY = [-80.0, -50.0, -20.0, 20.0, 50.0, 80.0];

class _BattleGroundScreenState extends ConsumerState<BattleGroundScreen> {
  late final BattlegroundTimeOfDay _timeOfDay;
  late final Flutter3DController _controller;

  /// Currently-active camera framing. Toggling this re-runs
  /// [_applyCameraForMode] which drives the model-viewer camera.
  ArenaCameraMode _cameraMode = ArenaCameraMode.thirdPerson;

  /// Pings the completion RPC once per screen lifetime when end_time
  /// crosses while this screen is open.
  bool _completionRequested = false;

  // ---------------------------------------------------------------------------
  // Top-view camera state
  // ---------------------------------------------------------------------------
  //
  // Top view uses custom Flutter gesture handling (model-viewer's own touch
  // is disabled while Top is active). Zoom-out is hard-locked at the initial
  // radius; zoom-in is unlimited. Pan is 1-finger, clamped to the arena
  // block; zoom is 2-finger pinch only. See _onTopScaleUpdate for the math.

  /// Initial radius when Top mode is entered — becomes the max radius the
  /// user can zoom out to. Also serves as the yardstick for pixel→meter
  /// pan conversion.
  static const double _topInitialRadius = 45.0;
  static const double _topMinRadius = 2.0;

  /// Arena bounds in model-viewer coords for Top-view pan clamping. mv X =
  /// Blender X (arena width). mv Z = -Blender Y (arena length, negated
  /// because export_yup=True flips forward-axis sign). Tightened INSIDE
  /// the last building rows — camera can never look past them into the
  /// backdrop cluster.
  static const double _topPanBoundX = 5.0;
  static const double _topPanBoundZ = 75.0;

  /// Idle timeout after which either camera returns to its initial
  /// framing. Reset on every gesture; fires once after this delay of no
  /// touch input.
  static const Duration _idleResetDelay = Duration(seconds: 5);

  /// Current camera target + radius while in Top mode. Reset every time
  /// Top mode is (re-)entered.
  double _topTargetX = 0;
  double _topTargetZ = 0;
  double _topRadius = _topInitialRadius;

  /// Snapshots taken at gesture start for delta computation.
  double _topScaleStartRadius = _topInitialRadius;
  double _topScaleStartTargetX = 0;
  double _topScaleStartTargetZ = 0;

  /// Idle-timeout timer. Started when a gesture ends; cancelled when a
  /// new gesture begins.
  Timer? _topIdleResetTimer;

  // ---------------------------------------------------------------------------
  // Third-person view camera state
  // ---------------------------------------------------------------------------
  //
  // 3P view mirrors the Top-view gesture model: 1-finger pan, 2-finger
  // pinch zoom, zoom-out locked at initial radius, 5-second idle reset.
  // The camera is horizontal (phi=90°) with the target 12 m ahead of the
  // camera position. Swipe-up → walk forward; swipe-left/right → strafe
  // across the road.

  static const double _tpInitialRadius = 12.0;
  static const double _tpMinRadius = 2.0;

  /// 3P pan clamps. Target X mirrors Top — before the grass beds.
  /// Target Z is chosen so the CAMERA (target.z + radius) stays inside
  /// Blender Y = ±75. Camera-mv-Z ranges [-75, +75] → target-mv-Z =
  /// camera-mv-Z − 12 → target-mv-Z ∈ [−87, +63].
  static const double _tpPanBoundX = 5.0;
  static const double _tpPanBoundZMin = -87.0;
  static const double _tpPanBoundZMax = 63.0;

  double _tpTargetX = 0;
  double _tpTargetZ = 0;
  double _tpRadius = _tpInitialRadius;

  double _tpScaleStartRadius = _tpInitialRadius;
  double _tpScaleStartTargetX = 0;
  double _tpScaleStartTargetZ = 0;

  Timer? _tpIdleResetTimer;

  // ---------------------------------------------------------------------------
  // Cinematic intro state
  // ---------------------------------------------------------------------------

  _CinematicPhase _cinematicPhase = _CinematicPhase.idle;

  /// Slot index (0..5) that maps to each rank position; computed once per
  /// battle open. slotForRank[0] = the top user's slot, .last = bottom user.
  List<int> _slotForRank = const [];

  /// Slot index of the current user. Cinematic ends here.
  int _mySlotIndex = 3;

  /// Whether the current user is #1 on the battle board. Drives which GLB
  /// the character overlay picks — `Taunt.glb` if true, `character.glb`
  /// otherwise. Set in [_startCinematic] once ranks are computed and
  /// stays sticky until the next mount (rank changes mid-arena would
  /// require a rebuild we don't do yet).
  bool _isTopRanked = false;

  /// Live timers driving the cinematic. Cancelled on skip / dispose / mode
  /// toggle.
  final List<Timer> _cinematicTimers = [];

  @override
  void initState() {
    super.initState();
    _timeOfDay = BattlegroundTimeOfDay.forNow();
    _controller = Flutter3DController();
    // Lock to portrait — the 3D arena is designed for that aspect.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
    });
  }

  @override
  void dispose() {
    _topIdleResetTimer?.cancel();
    _tpIdleResetTimer?.cancel();
    _cancelCinematic();
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Cinematic
  // ---------------------------------------------------------------------------

  /// Kick off the cinematic sweep. Called once from onLoad. If for any
  /// reason there aren't at least 2 participants, we skip straight to
  /// the resting 3P framing.
  void _startCinematic(BattleModel battle, String myUid) {
    if (_cinematicPhase != _CinematicPhase.idle) return;

    // 1) Rank participants by step count DESC. Only accepted participants
    //    count (invitees who haven't joined shouldn't get a slot).
    final ranked = battle.participants
        .where((p) => p.inviteStatus == ParticipantInviteStatus.accepted)
        .toList()
      ..sort((a, b) => b.currentSteps.compareTo(a.currentSteps));

    if (ranked.length < 2) {
      // 1v1 not-yet-joined case → skip cinematic.
      _cinematicPhase = _CinematicPhase.done;
      _applyCameraForMode(_cameraMode);
      return;
    }

    // 2) Assign slots: top of ranking → slot 5, next → slot 4, etc.
    //    Only assign up to 6 slots; extra participants share the last.
    _slotForRank = List<int>.generate(
      ranked.length,
      (i) => (5 - i).clamp(0, 5),
    );

    // 3) Locate MY rank/slot.
    final myRankIdx = ranked.indexWhere((p) => p.userId == myUid);
    _mySlotIndex =
        myRankIdx >= 0 ? _slotForRank[myRankIdx] : 3; // fallback to middle
    _isTopRanked = myRankIdx == 0;

    final topSlot = _slotForRank.first;
    final bottomSlot = _slotForRank.last;
    final mySlot = _mySlotIndex;

    AppLogger.battle.i('arena3d:cinematicStart', fields: {
      'topSlot': topSlot,
      'bottomSlot': bottomSlot,
      'mySlot': mySlot,
      'ranked': ranked.length,
      'isTopRanked': _isTopRanked,
    });

    // 4) Frame TOP user first.
    _cinematicPhase = _CinematicPhase.atTop;
    _frameSlot(topSlot);

    // 5) Schedule the two subsequent moves. Model-viewer interpolates the
    //    camera automatically between setCameraOrbit / setCameraTarget
    //    calls, so we just fire the next values at the right beats.
    _cinematicTimers.add(Timer(const Duration(seconds: 3), () {
      if (!mounted || _cinematicPhase == _CinematicPhase.done) return;
      _cinematicPhase = _CinematicPhase.atBottom;
      _frameSlot(bottomSlot);
    }));
    _cinematicTimers.add(Timer(const Duration(seconds: 5), () {
      if (!mounted || _cinematicPhase == _CinematicPhase.done) return;
      _cinematicPhase = _CinematicPhase.atMain;
      _frameSlot(mySlot);
    }));
    _cinematicTimers.add(Timer(const Duration(seconds: 7), () {
      if (!mounted || _cinematicPhase == _CinematicPhase.done) return;
      _finishCinematic();
    }));
    // Force a rebuild so the Skip button is visible.
    setState(() {});
  }

  /// Point the camera at a slot's over-shoulder framing. Slot Y is Blender
  /// coord — convert to model-viewer (mv Z = -Blender Y).
  void _frameSlot(int slotIndex) {
    final blenderY = _slotBlenderY[slotIndex.clamp(0, 5)];
    final mvZChar = -blenderY;
    // Target 5 m in front of the character (looking down the road).
    _controller.setCameraTarget(0, 1.6, mvZChar - 5);
    // Camera 8 m behind target (3 m behind character) at eye level.
    _controller.setCameraOrbit(0, 90, 8);
  }

  /// End the cinematic — cancel timers, snap to the standard 3P framing,
  /// re-enable gestures.
  void _finishCinematic() {
    if (_cinematicPhase == _CinematicPhase.done) return;
    for (final t in _cinematicTimers) {
      t.cancel();
    }
    _cinematicTimers.clear();
    _cinematicPhase = _CinematicPhase.done;
    // Rest at YOUR slot rather than arena centre.
    _frameSlot(_mySlotIndex);
    AppLogger.battle.i('arena3d:cinematicDone', fields: {});
    setState(() {});
  }

  void _skipCinematic() {
    AppLogger.battle.i('arena3d:cinematicSkip', fields: {});
    _finishCinematic();
  }

  /// Cancel + wipe cinematic state (mode toggle, dispose).
  void _cancelCinematic() {
    for (final t in _cinematicTimers) {
      t.cancel();
    }
    _cinematicTimers.clear();
    _cinematicPhase = _CinematicPhase.done;
  }

  // ---------------------------------------------------------------------------
  // Camera modes
  // ---------------------------------------------------------------------------

  /// Push the current [_cameraMode]'s target + orbit onto model-viewer.
  ///
  /// Coordinate note: we exported the GLB with `export_yup=True`, so Blender's
  /// Y (arena depth) becomes model-viewer's -Z, and Blender's Z (height)
  /// becomes model-viewer's Y. All camera coords below are in
  /// model-viewer space.
  ///
  /// Configure model-viewer's lighting for the loaded TOD.
  ///
  /// Each GLB now ships with 52 KHR_lights_punctual entries:
  ///  - 1 directional sun (color+direction+intensity varies per TOD)
  ///  - 1 directional fill (opposite side softener)
  ///  - 50 point lights at each lamp post (0 intensity at day, 1358 at
  ///    evening, 6522 at night — so lamps physically light the scene at
  ///    night)
  ///
  /// Materials also carry TOD-baked emissions: window glass and lamp
  /// bulbs are dark at noon, glow warm yellow at evening/night. Same
  /// applies to awnings (subtle by day, neon at night).
  ///
  /// Since the GLB already carries all the light-source variation, this
  /// helper only needs to configure the tone-map (exposure), how much
  /// ambient IBL to add on top, and how strong the ground contact
  /// shadow should read.
  void _applyShadowConfigForTod(BattlegroundTimeOfDay tod) {
    late final double intensity;
    late final double softness;
    late final double exposure;
    late final double envIntensity;
    switch (tod) {
      case BattlegroundTimeOfDay.morning:
        intensity = 0.80;
        softness = 0.45;
        exposure = 1.00;
        envIntensity = 0.40;
        break;
      case BattlegroundTimeOfDay.afternoon:
        intensity = 1.00;
        softness = 0.25;
        exposure = 0.95;
        envIntensity = 0.35;
        break;
      case BattlegroundTimeOfDay.evening:
        intensity = 0.65;
        softness = 0.60;
        exposure = 0.75;
        envIntensity = 0.18;
        break;
      case BattlegroundTimeOfDay.night:
        intensity = 0.30;
        softness = 0.80;
        exposure = 0.55;
        envIntensity = 0.04;
        break;
    }
    _controller.setShadowConfig(
      shadowIntensity: intensity,
      shadowSoftness: softness,
      exposure: exposure,
      environmentImage: 'neutral',
      environmentIntensity: envIntensity,
    );
  }

  /// `setCameraOrbit` uses (θ, φ, radius):
  ///   • θ (azimuth) — 0° means camera sits on the +Z side of target, looking
  ///     along -Z. Increasing θ rotates counter-clockwise around the +Y axis.
  ///   • φ (polar)  — 0° means straight down from above; 90° is horizontal.
  ///   • radius     — distance from the target point.
  void _applyCameraForMode(ArenaCameraMode mode) {
    // NOTE: we ship a LOCAL FORK of flutter_3d_controller (see
    // packages/flutter_3d_controller_fork) that changes setCameraOrbit's
    // radius arg from percent-of-auto-frame ('%') to meters ('m'), and
    // exposes a separate setCameraOrbitBounds() for installing radius
    // clamps once per mode entry. Values below are meters.
    switch (mode) {
      case ArenaCameraMode.thirdPerson:
        // Eye-level walking view. Reset target/radius; install clamps for
        // zoom-out at initial radius, zoom-in down to _tpMinRadius.
        // If slot assignments are known, park the camera at YOUR slot;
        // otherwise arena centre.
        final blenderY = _slotForRank.isNotEmpty
            ? _slotBlenderY[_mySlotIndex.clamp(0, 5)]
            : 0.0;
        final mvZTarget = -(blenderY + 5);
        _tpTargetX = 0;
        _tpTargetZ = mvZTarget;
        _tpRadius = _tpInitialRadius;
        _controller.setCameraOrbitBounds(
          minRadius: _tpMinRadius,
          maxRadius: _tpInitialRadius,
        );
        _controller.setCameraTarget(0, 1.6, mvZTarget);
        _controller.setCameraOrbit(0, 90, _tpInitialRadius);
        break;
      case ArenaCameraMode.topView:
        // Reset gesture state — target starts centered, radius at the max
        // (which is also the initial framing).
        _topTargetX = 0;
        _topTargetZ = 0;
        _topRadius = _topInitialRadius;
        _controller.setCameraOrbitBounds(
          minRadius: _topMinRadius,
          maxRadius: _topInitialRadius,
        );
        _controller.setCameraTarget(0, 0, 0);
        _controller.setCameraOrbit(0, 0, _topInitialRadius);
        break;
    }
    AppLogger.battle.i('arena3d:cameraMode', fields: {'mode': mode.name});
  }

  // ---------------------------------------------------------------------------
  // Top-view gesture handling
  // ---------------------------------------------------------------------------

  void _onTopScaleStart(ScaleStartDetails details) {
    // Any new touch cancels a pending idle-reset. The timer restarts on
    // scale end.
    _topIdleResetTimer?.cancel();
    _topScaleStartRadius = _topRadius;
    _topScaleStartTargetX = _topTargetX;
    _topScaleStartTargetZ = _topTargetZ;
  }

  void _onTopScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount >= 2) {
      // 2-finger pinch → zoom. scale > 1 = fingers moved apart = zoom in.
      final newRadius = (_topScaleStartRadius / details.scale)
          .clamp(_topMinRadius, _topInitialRadius);
      AppLogger.battle.i('arena3d:topZoom', fields: {
        'scale': details.scale.toStringAsFixed(3),
        'startRadius': _topScaleStartRadius.toStringAsFixed(2),
        'newRadius': newRadius.toStringAsFixed(2),
      });
      if ((newRadius - _topRadius).abs() > 0.05) {
        _topRadius = newRadius;
        _controller.setCameraOrbit(0, 0, _topRadius);
      }
    } else if (details.pointerCount == 1) {
      // 1-finger drag → pan. Convert screen pixels to arena meters using
      // the current camera height (radius) and model-viewer's default FOV
      // (~30°). At height H, the horizontal visible width on ground is
      // 2·H·tan(FOV/2). Use screen width to derive meters-per-pixel.
      final size = MediaQuery.of(context).size;
      const halfFovRad = 15.0 * math.pi / 180.0; // half of 30° FOV
      final visibleWidthMeters = 2 * _topRadius * math.tan(halfFovRad);
      final metersPerPixel = visibleWidthMeters / size.width;

      final delta = details.focalPointDelta;

      // "Map follows finger" mapping — inverse of the finger direction.
      // Swipe right → camera goes LEFT (target.x decreases), so the arena
      // appears to slide right with the finger. Same for vertical.
      final newX = (_topTargetX - delta.dx * metersPerPixel)
          .clamp(-_topPanBoundX, _topPanBoundX);
      final newZ = (_topTargetZ - delta.dy * metersPerPixel)
          .clamp(-_topPanBoundZ, _topPanBoundZ);

      if ((newX - _topTargetX).abs() > 0.02 ||
          (newZ - _topTargetZ).abs() > 0.02) {
        _topTargetX = newX;
        _topTargetZ = newZ;
        _controller.setCameraTarget(_topTargetX, 0, _topTargetZ);
      }
    }
  }

  void _onTopScaleEnd(ScaleEndDetails details) {
    // Kick off the idle-reset timer. If the user touches again inside
    // this window, ScaleStart cancels it.
    _topIdleResetTimer?.cancel();
    _topIdleResetTimer = Timer(_idleResetDelay, _resetTopCameraToInitial);
  }

  /// Snap camera back to the initial Top-view framing.
  void _resetTopCameraToInitial() {
    _topTargetX = 0;
    _topTargetZ = 0;
    _topRadius = _topInitialRadius;
    _controller.setCameraTarget(0, 0, 0);
    _controller.setCameraOrbit(0, 0, _topInitialRadius);
    AppLogger.battle.i('arena3d:topIdleReset', fields: {});
  }

  // ---------------------------------------------------------------------------
  // Third-person gesture handling
  // ---------------------------------------------------------------------------

  void _onTpScaleStart(ScaleStartDetails details) {
    _tpIdleResetTimer?.cancel();
    _tpScaleStartRadius = _tpRadius;
    _tpScaleStartTargetX = _tpTargetX;
    _tpScaleStartTargetZ = _tpTargetZ;
  }

  void _onTpScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount >= 2) {
      // 2-finger pinch → zoom. Radius clamped to [_tpMinRadius, initial].
      final newRadius = (_tpScaleStartRadius / details.scale)
          .clamp(_tpMinRadius, _tpInitialRadius);
      AppLogger.battle.i('arena3d:tpZoom', fields: {
        'scale': details.scale.toStringAsFixed(3),
        'startRadius': _tpScaleStartRadius.toStringAsFixed(2),
        'newRadius': newRadius.toStringAsFixed(2),
        'currentRadius': _tpRadius.toStringAsFixed(2),
      });
      if ((newRadius - _tpRadius).abs() > 0.05) {
        _tpRadius = newRadius;
        _controller.setCameraOrbit(0, 90, _tpRadius);
      }
    } else if (details.pointerCount == 1) {
      // 1-finger drag → pan the target. In 3P the camera is horizontal,
      // so we treat "screen-space" pixel deltas the same way as top view
      // but scale by radius (distance to target) instead of camera height.
      final size = MediaQuery.of(context).size;
      const halfFovRad = 15.0 * math.pi / 180.0;
      final visibleWidthMeters = 2 * _tpRadius * math.tan(halfFovRad);
      final metersPerPixel = visibleWidthMeters / size.width;

      final delta = details.focalPointDelta;

      // Map-follows-finger: swipe right → target moves left; swipe up →
      // target moves toward horizon (walk forward, target.z decreases).
      final newX = (_tpTargetX - delta.dx * metersPerPixel)
          .clamp(-_tpPanBoundX, _tpPanBoundX);
      final newZ = (_tpTargetZ - delta.dy * metersPerPixel)
          .clamp(_tpPanBoundZMin, _tpPanBoundZMax);

      if ((newX - _tpTargetX).abs() > 0.02 ||
          (newZ - _tpTargetZ).abs() > 0.02) {
        _tpTargetX = newX;
        _tpTargetZ = newZ;
        _controller.setCameraTarget(_tpTargetX, 1.6, _tpTargetZ);
      }
    }
  }

  void _onTpScaleEnd(ScaleEndDetails details) {
    _tpIdleResetTimer?.cancel();
    _tpIdleResetTimer = Timer(_idleResetDelay, _resetTpCameraToInitial);
  }

  void _resetTpCameraToInitial() {
    // After the cinematic ends, camera should sit at YOUR slot, not arena
    // centre. Compute the target Z from the current mySlotIndex.
    final blenderY = _slotBlenderY[_mySlotIndex.clamp(0, 5)];
    final mvZTarget = -(blenderY + 5); // target 5m ahead of your slot
    _tpTargetX = 0;
    _tpTargetZ = mvZTarget;
    _tpRadius = _tpInitialRadius;
    _controller.setCameraTarget(0, 1.6, mvZTarget);
    _controller.setCameraOrbit(0, 90, _tpInitialRadius);
    AppLogger.battle
        .i('arena3d:tpIdleReset', fields: {'mySlot': _mySlotIndex});
  }

  void _toggleCameraMode() {
    // Any pending idle-reset for the leaving mode has to be cancelled or
    // it'd fire in the new mode and clobber that camera.
    _topIdleResetTimer?.cancel();
    _tpIdleResetTimer?.cancel();
    // Toggling the mode kills any in-progress cinematic — the user's
    // opting out of the intro.
    if (_cinematicPhase != _CinematicPhase.done) {
      _cancelCinematic();
    }
    setState(() {
      _cameraMode = _cameraMode == ArenaCameraMode.thirdPerson
          ? ArenaCameraMode.topView
          : ArenaCameraMode.thirdPerson;
    });
    _applyCameraForMode(_cameraMode);
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final battleAsync = ref.watch(battleDetailProvider(widget.battleId));
    final uid = ref.watch(authStateProvider).valueOrNull?.id ?? '';

    return Scaffold(
      backgroundColor: Colors.black,
      body: battleAsync.when(
        loading: () => Center(
            child: CircularProgressIndicator(color: AppColors.primary)),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not load battle: $e',
                style: const TextStyle(color: Colors.white)),
          ),
        ),
        data: (battle) {
          if (battle == null) {
            return const Center(
              child: Text('Battle not found',
                  style: TextStyle(color: Colors.white)),
            );
          }
          if (!_completionRequested &&
              battle.status == BattleStatus.active &&
              !DateTime.now().isBefore(battle.endTime) &&
              uid.isNotEmpty) {
            _completionRequested = true;
            ref.read(battleServiceProvider).completeExpiredBattles(uid);
          }
          return _buildArenaScene(battle, uid);
        },
      ),
    );
  }

  Widget _buildArenaScene(BattleModel battle, String uid) {
    final ctx = _arenaContext(battle, uid);
    final glbPath =
        'assets/images/battleground/cityView/city_arena_${_timeOfDay.name}.glb';

    // Viewer is created ONCE per screen open. `enableTouch` is fixed at
    // false and `activeGestureInterceptor` is fixed at false; both of
    // those props feed into the underlying WebView init, and changing
    // them per mode was rebuilding the viewer + reloading the GLB on
    // every toggle. The plugin's own gesture-interceptor also swallows
    // touches before Flutter sees them, so we kill it here — we drive
    // the camera 100% from Flutter regardless of mode.
    final Widget viewer = Flutter3DViewer(
      key: ValueKey('arena-${_timeOfDay.name}'),
      controller: _controller,
      src: glbPath,
      progressBarColor: AppColors.primary,
      enableTouch: false,
      activeGestureInterceptor: false,
      onLoad: (address) async {
        AppLogger.battle.i('arena3d:onLoad', fields: {'src': glbPath});
        _applyShadowConfigForTod(_timeOfDay);
        await Future.delayed(const Duration(milliseconds: 800));
        if (!mounted) return;
        _applyCameraForMode(_cameraMode);
        if (_cinematicPhase == _CinematicPhase.idle) {
          _startCinematic(battle, uid);
        }
      },
      onError: (err) => AppLogger.battle
          .e('arena3d:onError', fields: {'src': glbPath, 'err': err}),
    );

    // Current user's picked 3D character. If they're #1 on the battle
    // board load the Taunt GLB (baked animation plays automatically via
    // AnimatedCharacterViewer's first-anim-on-load logic); otherwise the
    // neutral pose from character.glb. Sized as a small corner tile so it
    // sits on top of the arena without covering it.
    final character = ref.watch(currentCharacter3DProvider);
    final characterGlb = _isTopRanked
        ? character.tauntGlbAssetPath
        : character.glbAssetPath;

    return Stack(
      fit: StackFit.expand,
      children: [
        viewer,
        // Top-view gesture overlay — only present in Top mode. Sits on
        // top of the viewer in the Stack so it wins the hit test.
        Positioned.fill(
          child: _cameraMode == ArenaCameraMode.topView
              ? GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onScaleStart: _onTopScaleStart,
                  onScaleUpdate: _onTopScaleUpdate,
                  onScaleEnd: _onTopScaleEnd,
                )
              : GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onScaleStart: _onTpScaleStart,
                  onScaleUpdate: _onTpScaleUpdate,
                  onScaleEnd: _onTpScaleEnd,
                ),
        ),
        // Corner character tile — shows the current user's picked 3D
        // avatar. Bottom-right so it doesn't collide with the top-left
        // close button or top-right camera-mode / XP chip. Non-blocking
        // for hit-test so the arena gestures still fire underneath.
        Positioned(
          right: 16,
          bottom: 24,
          child: IgnorePointer(
            child: Container(
              width: 120,
              height: 168,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _isTopRanked
                      ? AppColors.primary.withValues(alpha: 0.85)
                      : Colors.white.withValues(alpha: 0.2),
                  width: _isTopRanked ? 2 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: AnimatedCharacterViewer(
                key: ValueKey('arena-char-${character.id}-$_isTopRanked'),
                glbAssetPath: characterGlb,
                progressBarColor: Colors.transparent,
              ),
            ),
          ),
        ),
        ..._sharedChrome(battle, ctx),
      ],
    );
  }

  _ArenaContext _arenaContext(BattleModel battle, String uid) {
    final now = DateTime.now();
    final frozen = !now.isBefore(battle.endTime) ||
        battle.status == BattleStatus.completed;
    final total = battle.endTime.difference(battle.startTime);
    final remaining = battle.endTime.difference(now).isNegative
        ? Duration.zero
        : battle.endTime.difference(now);

    final acceptedCount = battle.participants
        .where((p) => p.inviteStatus == ParticipantInviteStatus.accepted)
        .length;
    final potXp = battle.stakeXp > 0
        ? battle.stakeXp * acceptedCount
        : battle.xpReward;

    return _ArenaContext(
      frozen: frozen,
      remaining: remaining,
      total: total,
      potXp: potXp,
      uid: uid,
    );
  }

  List<Widget> _sharedChrome(BattleModel battle, _ArenaContext ctx) {
    return [
      if (ctx.frozen)
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0x40000000)],
              ),
            ),
            child: SizedBox.expand(),
          ),
        ),
      SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _GlassIconBtn(
                icon: Icons.close,
                onTap: () => context.pop(),
              ),
              const Spacer(),
              CountdownRing(remaining: ctx.remaining, total: ctx.total),
              const Spacer(),
              _CameraModeToggle(
                mode: _cameraMode,
                onTap: _toggleCameraMode,
              ),
              const SizedBox(width: 8),
              _PotBadge(xp: ctx.potXp, isStake: battle.stakeXp > 0),
            ],
          ),
        ),
      ),
      // Skip button — only visible during the intro cinematic. Sits below
      // the main chrome row, right-aligned, low-opacity so it doesn't
      // dominate the cinematic itself.
      if (_cinematicPhase != _CinematicPhase.done &&
          _cinematicPhase != _CinematicPhase.idle)
        SafeArea(
          child: Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 60, right: 12),
              child: _SkipIntroBtn(onTap: _skipCinematic),
            ),
          ),
        ),
      SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: LeaderboardPill(
              participants: battle.participants,
              currentUserId: ctx.uid,
            ),
          ),
        ),
      ),
    ];
  }
}

class _ArenaContext {
  final bool frozen;
  final Duration remaining;
  final Duration total;
  final int potXp;
  final String uid;

  _ArenaContext({
    required this.frozen,
    required this.remaining,
    required this.total,
    required this.potXp,
    required this.uid,
  });
}

/// Two-state pill button that flips between the two camera modes. Sits in
/// the top chrome row so it's always visible without eating arena space.
class _CameraModeToggle extends StatelessWidget {
  final ArenaCameraMode mode;
  final VoidCallback onTap;
  const _CameraModeToggle({required this.mode, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final label = mode == ArenaCameraMode.topView ? 'Top' : '3P';
    final icon = mode == ArenaCameraMode.topView
        ? Icons.map_outlined
        : Icons.videocam_outlined;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 18),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  fontFamily: 'Manrope',
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Low-opacity "Skip →" pill shown top-right during the intro cinematic.
class _SkipIntroBtn extends StatelessWidget {
  final VoidCallback onTap;
  const _SkipIntroBtn({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.5,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.25)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Skip',
                  style: TextStyle(
                    fontFamily: 'Manrope',
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
                SizedBox(width: 4),
                Icon(Icons.arrow_forward, color: Colors.white, size: 14),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassIconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _GlassIconBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            shape: BoxShape.circle,
            border: Border.all(
                color: AppColors.onSurface.withValues(alpha: 0.12)),
          ),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

class _PotBadge extends StatelessWidget {
  final int xp;
  final bool isStake;
  const _PotBadge({required this.xp, required this.isStake});

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.tertiary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isStake ? Icons.casino : Icons.workspace_premium,
              size: 14, color: accent),
          const SizedBox(width: 4),
          Text(
            '${isStake ? "Pot" : "+"}$xp XP',
            style: TextStyle(
              fontFamily: 'Manrope',
              color: accent,
              fontWeight: FontWeight.w800,
              fontSize: 11,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}
