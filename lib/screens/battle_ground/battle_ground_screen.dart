import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../config/colors.dart';
import '../../models/battle_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/battle_provider.dart';
import 'widgets/countdown_ring.dart';
import 'widgets/leaderboard_pill.dart';
import 'widgets/parallax_painters.dart';
import 'widgets/runner.dart';

/// Immersive arena that visualizes an active (or recently-ended) battle
/// as an animated horizontal track. Each participant is a running figure;
/// x-position is proportional to their steps relative to the leader.
///
/// Key behaviors:
///  - All animations share a single [Ticker] for perf.
///  - Camera auto-centers on the current user; finger-drag to pan; double
///    tap to recenter.
///  - Time-of-day skybox (dawn / day / dusk / night) derived from wall clock.
///  - Lead changes trigger a screen flash + haptic + toast.
///  - When `endTime` elapses, scene freezes and a winner badge plants on
///    the leader's head.
class BattleGroundScreen extends ConsumerStatefulWidget {
  final String battleId;

  const BattleGroundScreen({super.key, required this.battleId});

  @override
  ConsumerState<BattleGroundScreen> createState() =>
      _BattleGroundScreenState();
}

class _BattleGroundScreenState extends ConsumerState<BattleGroundScreen>
    with SingleTickerProviderStateMixin {
  // Animation ticker — single source of `time` for all children.
  late final Ticker _ticker;
  double _time = 0;
  Duration _lastElapsed = Duration.zero;

  // Camera
  double _cameraX = 0.0;
  double _cameraTarget = 0.0;
  double _manualPanUntil = 0.0; // wall-clock seconds — suppress auto-follow

  // Lead tracking (for flash / haptic)
  String? _lastLeaderId;
  double _flashUntil = 0.0;
  String? _toast;
  Timer? _toastTimer;

  // Per-runner tweened world X.
  // Keys are userIds; values are current displayed x.
  final Map<String, double> _currentX = {};
  final Map<String, double> _targetX = {};

  // World / viewport dimensions — populated in layout.
  double _viewportW = 0;
  double _viewportH = 0;
  // Lane Y-positions for up to 6 runners
  final List<double> _laneY = [];

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _toastTimer?.cancel();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    final dtMs = (elapsed - _lastElapsed).inMicroseconds / 1e6;
    _lastElapsed = elapsed;
    _time = elapsed.inMicroseconds / 1e6;

    // Smooth camera tween toward target (exponential easing).
    final manual = _time < _manualPanUntil;
    if (!manual) {
      _cameraX += (_cameraTarget - _cameraX) * math.min(1.0, dtMs * 5.0);
    }

    // Runner x tween toward target
    for (final id in _targetX.keys) {
      final target = _targetX[id]!;
      final current = _currentX[id] ?? target;
      _currentX[id] = current + (target - current) * math.min(1.0, dtMs * 2.5);
    }

    if (mounted) {
      // ignore: invalid_use_of_protected_member
      setState(() {});
    }
  }

  // -----------------------------------------------------------------------
  // Position mapping — proportional to leader's steps
  // -----------------------------------------------------------------------
  static const double _worldMultiplier = 2.4; // world = multiplier × viewport
  static const double _startPadFraction = 0.08;
  static const double _leaderFraction = 0.78;

  double get _worldWidth =>
      (_viewportW <= 0 ? 600.0 : _viewportW) * _worldMultiplier;

  double _runnerWorldX(BattleParticipant p, int leaderSteps) {
    final worldW = _worldWidth;
    final startX = worldW * _startPadFraction;
    final leaderX = worldW * _leaderFraction;
    if (leaderSteps <= 0) return startX;
    final t = (p.currentSteps / leaderSteps).clamp(0.0, 1.0);
    return startX + (leaderX - startX) * t;
  }

  void _recomputeTargets(BattleModel battle, String uid) {
    if (battle.participants.isEmpty) return;
    final leaderSteps = battle.participants
        .map((p) => p.currentSteps)
        .fold<int>(0, (a, b) => a > b ? a : b);
    for (final p in battle.participants) {
      _targetX[p.userId] = _runnerWorldX(p, leaderSteps);
      // Seed current position for first paint to prevent a "fly in".
      _currentX.putIfAbsent(p.userId, () => _targetX[p.userId]!);
    }

    // Camera follows user's runner unless they're panning manually.
    final meX = _targetX[uid];
    if (meX != null) {
      _cameraTarget =
          (meX - _viewportW * 0.42).clamp(0.0, _worldWidth - _viewportW);
    }

    // Detect lead change (only for active battles).
    if (battle.status == BattleStatus.active) {
      final sorted = [...battle.participants]
        ..sort((a, b) => b.currentSteps.compareTo(a.currentSteps));
      final newLeader = sorted.first;
      if (_lastLeaderId != null &&
          _lastLeaderId != newLeader.userId &&
          newLeader.currentSteps > 0) {
        _triggerLeadChange(
            newLeader.userId == uid ? 'You' : newLeader.displayName);
      }
      _lastLeaderId = newLeader.userId;
    }
  }

  void _triggerLeadChange(String leaderLabel) {
    _flashUntil = _time + 0.6;
    HapticFeedback.mediumImpact();
    _toast = '$leaderLabel took the lead!';
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() => _toast = null);
    });
  }

  // -----------------------------------------------------------------------
  // Gestures
  // -----------------------------------------------------------------------
  void _onPanUpdate(DragUpdateDetails d) {
    setState(() {
      _cameraX = (_cameraX - d.delta.dx)
          .clamp(0.0, math.max(0.0, _worldWidth - _viewportW));
      // Suppress auto-follow for 3s after manual interaction.
      _manualPanUntil = _time + 3.0;
    });
  }

  void _onDoubleTap() {
    setState(() => _manualPanUntil = 0.0);
  }

  // -----------------------------------------------------------------------
  // Lane layout
  // -----------------------------------------------------------------------
  void _recomputeLanes(int count) {
    _laneY.clear();
    if (count == 0) return;
    // Track vertical band: roughly the lower 40% of the screen.
    final top = _viewportH * 0.50;
    final bottom = _viewportH * 0.88;
    final band = bottom - top;
    if (count == 1) {
      _laneY.add(top + band * 0.55);
    } else {
      final step = band / (count - 1);
      for (var i = 0; i < count; i++) {
        _laneY.add(top + step * i);
      }
    }
  }

  // -----------------------------------------------------------------------
  // Build
  // -----------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final battleAsync = ref.watch(battleDetailProvider(widget.battleId));
    final uid = ref.watch(authStateProvider).valueOrNull?.uid ?? '';

    return Scaffold(
      backgroundColor: Colors.black,
      body: battleAsync.when(
        loading: () => const Center(
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
          return LayoutBuilder(
            builder: (ctx, c) {
              _viewportW = c.maxWidth;
              _viewportH = c.maxHeight;
              _recomputeLanes(battle.participants.length);
              _recomputeTargets(battle, uid);
              return _buildScene(battle, uid);
            },
          );
        },
      ),
    );
  }

  Widget _buildScene(BattleModel battle, String uid) {
    final now = DateTime.now();
    final frozen = !now.isBefore(battle.endTime) ||
        battle.status == BattleStatus.completed;
    final palette = SkyPalette.forPhase(phaseFor(now));
    final flashAlpha =
        (_flashUntil - _time > 0) ? ((_flashUntil - _time) / 0.6) : 0.0;

    // Leader by steps (ties → first in list)
    String? leaderId;
    int leaderSteps = -1;
    for (final p in battle.participants) {
      if (p.currentSteps > leaderSteps) {
        leaderSteps = p.currentSteps;
        leaderId = p.userId;
      }
    }
    // Hide "leader" marker if everyone is at 0.
    if (leaderSteps == 0) leaderId = null;

    // Remaining time vs total — for countdown ring.
    final total = battle.endTime.difference(battle.startTime);
    final remaining =
        battle.endTime.difference(now).isNegative
            ? Duration.zero
            : battle.endTime.difference(now);

    final trackTop = _viewportH * 0.45;
    final trackHeight = _viewportH * 0.55;

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: _onPanUpdate,
      onDoubleTap: _onDoubleTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Skybox (fixed)
          RepaintBoundary(
            child: CustomPaint(
              painter: SkyboxPainter(palette: palette, time: _time),
            ),
          ),

          // Clouds — drift independent of camera
          RepaintBoundary(
            child: CustomPaint(
              painter: CloudsPainter(time: _time, palette: palette),
            ),
          ),

          // Distant mountains (slow parallax)
          RepaintBoundary(
            child: CustomPaint(
              painter: MountainsPainter(
                cameraX: _cameraX,
                parallax: 0.18,
                palette: palette,
                layer: 0,
              ),
            ),
          ),
          // Nearer mountains
          RepaintBoundary(
            child: CustomPaint(
              painter: MountainsPainter(
                cameraX: _cameraX,
                parallax: 0.34,
                palette: palette,
                layer: 1,
              ),
            ),
          ),

          // Hills with trees
          RepaintBoundary(
            child: CustomPaint(
              painter: HillsPainter(
                cameraX: _cameraX,
                parallax: 0.62,
                palette: palette,
              ),
            ),
          ),

          // Track (ground + centerline + milestones)
          RepaintBoundary(
            child: CustomPaint(
              painter: TrackPainter(
                cameraX: _cameraX,
                palette: palette,
                trackTop: trackTop,
                trackHeight: trackHeight * 0.45,
              ),
            ),
          ),

          // Start line marker (world X = 0 area)
          Positioned(
            left: -_cameraX + _worldWidth * _startPadFraction - 4,
            top: trackTop - 6,
            bottom: 0,
            child: _StartLine(h: trackHeight * 0.55),
          ),

          // Runners
          for (var i = 0; i < battle.participants.length; i++)
            _positionedRunner(
              battle.participants[i],
              i,
              uid,
              leaderId,
              frozen,
              battle.winnerId,
            ),

          // Lead-change flash overlay
          if (flashAlpha > 0)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: AppColors.primary.withValues(alpha: flashAlpha * 0.18),
                ),
              ),
            ),

          // Top chrome
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
                  CountdownRing(remaining: remaining, total: total),
                  const Spacer(),
                  _XpBadge(xp: battle.xpReward),
                ],
              ),
            ),
          ),

          // Toast for lead change
          if (_toast != null)
            Positioned(
              top: MediaQuery.of(context).padding.top + 86,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: AppColors.primary.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    _toast!,
                    style: const TextStyle(
                      fontFamily: 'Manrope',
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),

          // Bottom chrome
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: LeaderboardPill(
                  participants: battle.participants,
                  currentUserId: uid,
                ),
              ),
            ),
          ),

          // Frozen-battle overlay gradient
          if (frozen)
            IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.0),
                      Colors.black.withValues(alpha: 0.25),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _positionedRunner(
    BattleParticipant p,
    int index,
    String uid,
    String? leaderId,
    bool frozen,
    String? winnerId,
  ) {
    final worldX = _currentX[p.userId] ?? _targetX[p.userId] ?? 0.0;
    final targetX = _targetX[p.userId] ?? worldX;
    final pace = 1.0 + (targetX - worldX).abs() / 30.0;
    final y = _laneY.length > index ? _laneY[index] : _viewportH * 0.7;

    return Positioned(
      left: worldX - _cameraX - 55, // center the runner (width/2)
      top: y - 140, // runner widget height
      child: Runner(
        displayName: p.displayName,
        avatarURL: p.avatarURL,
        steps: p.currentSteps,
        time: _time,
        isMe: p.userId == uid,
        isLeader: leaderId == p.userId,
        pace: pace.clamp(0.7, 3.0),
        frozen: frozen,
        isWinner: frozen &&
            (winnerId != null
                ? p.userId == winnerId
                : p.userId == leaderId),
      ),
    );
  }
}

// =============================================================================
// Small chrome elements
// =============================================================================
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
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
          ),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

class _XpBadge extends StatelessWidget {
  final int xp;
  const _XpBadge({required this.xp});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppColors.tertiary.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.workspace_premium,
              size: 14, color: AppColors.tertiary),
          const SizedBox(width: 4),
          Text('+$xp XP',
              style: const TextStyle(
                fontFamily: 'Manrope',
                color: AppColors.tertiary,
                fontWeight: FontWeight.w800,
                fontSize: 11,
                letterSpacing: 0.5,
              )),
        ],
      ),
    );
  }
}

class _StartLine extends StatelessWidget {
  final double h;
  const _StartLine({required this.h});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        width: 8,
        height: h,
        child: Column(
          children: [
            for (var i = 0; i < 12; i++)
              Expanded(
                child: Container(
                  color: i.isEven
                      ? Colors.white.withValues(alpha: 0.8)
                      : Colors.black.withValues(alpha: 0.8),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
