import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/colors.dart';
import '../../models/avatar.dart';
import '../../models/battle_model.dart';
import '../../providers/arena_pack_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/battle_provider.dart';
import '../../services/battleground_path.dart';
import '../../services/battleground_tile.dart';
import '../profile/public_profile_screen.dart';
import 'widgets/countdown_ring.dart';
import 'widgets/leaderboard_pill.dart';

/// Battle-ground arena — supports two packs:
///
///   • [ArenaPack.forest] — vertical, multi-tile world; the user scrolls
///     up/down through stacked copies of a portrait tile. Camera auto-
///     follows the mid-point between leader and trailer.
///
///   • [ArenaPack.city] — single landscape tile, locked to landscape
///     orientation. Wrapped in [InteractiveViewer] for pinch-zoom and
///     two-finger pan; auto-follow drives the same controller toward the
///     runners' mid-X each tick (so the camera tracks the action while
///     leaving user zoom intact).
///
/// The user's pack choice is persisted via [arenaPackPrefProvider]. A
/// small pack icon in the top-right chrome opens a chooser sheet.
class BattleGroundScreen extends ConsumerStatefulWidget {
  final String battleId;

  const BattleGroundScreen({super.key, required this.battleId});

  @override
  ConsumerState<BattleGroundScreen> createState() =>
      _BattleGroundScreenState();
}

class _BattleGroundScreenState extends ConsumerState<BattleGroundScreen>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _time = 0;
  Duration _lastElapsed = Duration.zero;

  /// Per-participant currently-rendered progress (eased toward target).
  final Map<String, double> _displayedProgress = {};
  final Map<String, double> _targetProgress = {};

  // Lead-change UI state.
  String? _lastLeaderId;
  double _flashUntil = 0.0;
  String? _toast;
  Timer? _toastTimer;

  /// Pings the completion RPC once per screen lifetime when end_time
  /// crosses while this screen is open.
  bool _completionRequested = false;

  late final BattlegroundTimeOfDay _timeOfDay;

  // ---- Forest scroll state -------------------------------------------------
  final ScrollController _scrollController = ScrollController();
  double _manualScrollUntil = 0.0;
  static const double _manualLockoutSeconds = 3.0;

  // Geometry cached from forest LayoutBuilder.
  double _viewportH = 0;
  double _worldH = 0;
  double _pTop = 0;
  double _pBottom = 0;

  // ---- City InteractiveViewer state ---------------------------------------
  final TransformationController _cityXform = TransformationController();
  double _manualXformUntil = 0.0;
  Size _cityTile = Size.zero;
  Size _cityViewport = Size.zero;

  /// Tracks the orientation we asked the OS to lock. Allows us to skip the
  /// SystemChrome call when nothing changed (it's not free — it crosses
  /// the platform channel every time).
  ArenaPack? _appliedOrientationFor;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _timeOfDay = BattlegroundTimeOfDay.forNow();
    // Apply orientation after the first frame so MediaQuery is settled —
    // calling SystemChrome.setPreferredOrientations directly here is
    // technically fine but the post-frame guard avoids a single-frame
    // mid-build size jolt on some devices.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applyOrientationForPack(ref.read(arenaPackPrefProvider));
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _toastTimer?.cancel();
    _scrollController.dispose();
    _cityXform.dispose();
    // Restore the app's default orientation policy (portrait-only).
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
    super.dispose();
  }

  void _applyOrientationForPack(ArenaPack pack) {
    if (_appliedOrientationFor == pack) return;
    _appliedOrientationFor = pack;
    SystemChrome.setPreferredOrientations(
      pack.isLandscape
          ? const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]
          : const [DeviceOrientation.portraitUp],
    );
  }

  void _onTick(Duration elapsed) {
    final dtMs = (elapsed - _lastElapsed).inMicroseconds / 1e6;
    _lastElapsed = elapsed;
    _time = elapsed.inMicroseconds / 1e6;

    // Tween each runner's displayed progress toward target.
    bool changed = false;
    for (final id in _targetProgress.keys) {
      final target = _targetProgress[id]!;
      final current = _displayedProgress[id] ?? target;
      final next = current + (target - current) * math.min(1.0, dtMs * 2.5);
      if ((next - current).abs() > 0.0005) changed = true;
      _displayedProgress[id] = next;
    }

    // Camera follow — branches by which world is currently mounted.
    final pack = _appliedOrientationFor ?? ArenaPack.forest;
    if (pack.isLandscape) {
      _autoFollowCity(dtMs);
    } else if (_scrollController.hasClients &&
        _time > _manualScrollUntil &&
        _worldH > 0 &&
        _viewportH > 0) {
      final target = _autoScrollTargetForest();
      if (target != null) {
        final currentPx = _scrollController.position.pixels;
        final next = currentPx +
            (target - currentPx) * math.min(1.0, dtMs * 1.2);
        if ((next - currentPx).abs() > 0.5) {
          _scrollController.jumpTo(next);
        }
      }
    }

    if (changed && mounted) {
      // ignore: invalid_use_of_protected_member
      setState(() {});
    }
  }

  // ---------------------------------------------------------------------------
  // Forest auto-follow — scrolls the SingleChildScrollView.
  // ---------------------------------------------------------------------------

  double? _autoScrollTargetForest() {
    if (_displayedProgress.isEmpty) return null;
    final values = _displayedProgress.values.toList();
    final lo = values.reduce(math.min);
    final hi = values.reduce(math.max);
    final mid = (lo + hi) / 2.0;
    final midY = _avatarWorldYForest(mid);
    final raw = midY - _viewportH / 2;
    final maxScroll = _scrollController.position.maxScrollExtent;
    return raw.clamp(0.0, maxScroll);
  }

  double _avatarWorldYForest(double progress) =>
      _pTop + (1.0 - progress.clamp(0.0, 1.0)) * (_pBottom - _pTop);

  // ---------------------------------------------------------------------------
  // City auto-follow — drives the InteractiveViewer's transformation.
  // ---------------------------------------------------------------------------

  void _autoFollowCity(double dtMs) {
    if (_time < _manualXformUntil) return;
    if (_displayedProgress.isEmpty) return;
    if (_cityTile.isEmpty || _cityViewport.isEmpty) return;

    final values = _displayedProgress.values.toList();
    final lo = values.reduce(math.min);
    final hi = values.reduce(math.max);
    final mid = (lo + hi) / 2.0;

    // Translate progress → tile pixel coordinates.
    final midPoint = BattlegroundPath.positionInTile(
      mid,
      _cityTile,
      pack: ArenaPack.city,
    );

    // Preserve the user's current zoom; only nudge translation.
    final current = _cityXform.value;
    final scale = current.getMaxScaleOnAxis();
    final targetTx = _cityViewport.width / 2 - midPoint.dx * scale;
    final targetTy = _cityViewport.height / 2 - midPoint.dy * scale;

    final t = current.getTranslation();
    final factor = math.min(1.0, dtMs * 1.2);
    final nextTx = t.x + (targetTx - t.x) * factor;
    final nextTy = t.y + (targetTy - t.y) * factor;

    if ((nextTx - t.x).abs() < 0.4 && (nextTy - t.y).abs() < 0.4) return;

    final next = Matrix4.identity()
      ..translate(nextTx, nextTy)
      ..scale(scale);
    _cityXform.value = next;
  }

  /// Re-centres + zooms to fit ALL runners with comfortable padding.
  /// Triggered by the "fit to runners" button.
  void _fitCityToRunners() {
    if (_displayedProgress.isEmpty) return;
    if (_cityTile.isEmpty || _cityViewport.isEmpty) return;

    final pts = [
      for (final p in _displayedProgress.values)
        BattlegroundPath.positionInTile(p, _cityTile, pack: ArenaPack.city),
    ];
    var minX = pts.first.dx, maxX = pts.first.dx;
    var minY = pts.first.dy, maxY = pts.first.dy;
    for (final p in pts.skip(1)) {
      if (p.dx < minX) minX = p.dx;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dy > maxY) maxY = p.dy;
    }

    // Pad by 20% of viewport so avatars aren't pressed to the edges.
    final padX = _cityViewport.width * 0.2;
    final padY = _cityViewport.height * 0.2;
    final boxW = math.max(1.0, (maxX - minX) + padX * 2);
    final boxH = math.max(1.0, (maxY - minY) + padY * 2);
    final centerX = (minX + maxX) / 2;
    final centerY = (minY + maxY) / 2;

    final scaleX = _cityViewport.width / boxW;
    final scaleY = _cityViewport.height / boxH;
    final scale = math.min(scaleX, scaleY).clamp(0.6, 3.0);

    final tx = _cityViewport.width / 2 - centerX * scale;
    final ty = _cityViewport.height / 2 - centerY * scale;

    _cityXform.value = Matrix4.identity()
      ..translate(tx, ty)
      ..scale(scale);
    // Don't suppress auto-follow — once the user has fit-to-runners, the
    // tick-by-tick follow can continue tweaking the centre as runners move.
    _manualXformUntil = 0;
  }

  // ---------------------------------------------------------------------------
  // Target progress + lead-change toast.
  // ---------------------------------------------------------------------------

  void _recomputeTargets(BattleModel battle, String uid) {
    final accepted = battle.participants
        .where((p) => p.inviteStatus == ParticipantInviteStatus.accepted)
        .toList();
    if (accepted.isEmpty) return;
    final leaderSteps = accepted
        .map((p) => p.currentSteps)
        .fold<int>(0, (a, b) => a > b ? a : b);
    for (final p in accepted) {
      final progress = leaderSteps <= 0
          ? 0.0
          : (p.currentSteps / leaderSteps).clamp(0.0, 1.0);
      _targetProgress[p.userId] = progress;
      _displayedProgress.putIfAbsent(p.userId, () => progress);
    }

    if (battle.status == BattleStatus.active) {
      final sorted = [...accepted]
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

  // ---------------------------------------------------------------------------
  // Pack chooser sheet.
  // ---------------------------------------------------------------------------

  Future<void> _openPackChooser() async {
    final current = ref.read(arenaPackPrefProvider);
    final picked = await showModalBottomSheet<ArenaPack>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PackChooserSheet(current: current),
    );
    if (picked == null || picked == current) return;
    await ref.read(arenaPackPrefProvider.notifier).set(picked);
    _applyOrientationForPack(picked);
    // Reset zoom/pan so the new pack starts from a clean transform.
    _cityXform.value = Matrix4.identity();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final pack = ref.watch(arenaPackPrefProvider);
    // Eager apply on every build so a pack change picked from a sheet —
    // or restored from Hive on cold start — takes effect immediately.
    _applyOrientationForPack(pack);

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
          _recomputeTargets(battle, uid);
          return pack.isLandscape
              ? _buildCityScene(battle, uid)
              : _buildForestScene(battle, uid);
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Forest scene — vertical stack, SingleChildScrollView.
  // ---------------------------------------------------------------------------

  Widget _buildForestScene(BattleModel battle, String uid) {
    final ctx = _arenaContext(battle, uid);

    return LayoutBuilder(
      builder: (bctx, c) {
        final tileW = c.maxWidth;
        final tileH = tileW * 2; // forest tiles ship at natural 1:2 aspect
        final viewportH = c.maxHeight;

        final desiredWorldH = math.max(3 * tileH, 2.5 * viewportH);
        final tileCount = (desiredWorldH / tileH).ceil();
        final worldH = tileCount * tileH;

        _viewportH = viewportH;
        _worldH = worldH;
        _pTop = viewportH / 2;
        _pBottom = worldH - viewportH / 2;

        final tileSize = Size(tileW, tileH);

        return Stack(
          fit: StackFit.expand,
          children: [
            NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n is UserScrollNotification &&
                    n.direction != ScrollDirection.idle) {
                  _manualScrollUntil = _time + _manualLockoutSeconds;
                }
                return false;
              },
              child: SingleChildScrollView(
                controller: _scrollController,
                physics: const BouncingScrollPhysics(),
                child: SizedBox(
                  width: tileW,
                  height: worldH,
                  child: Stack(
                    children: [
                      for (int i = 0; i < tileCount; i++)
                        Positioned(
                          left: 0,
                          top: i * tileH,
                          width: tileW,
                          height: tileH,
                          child: Image.asset(
                            ArenaPack.forest.assetFor(_timeOfDay),
                            fit: BoxFit.fill,
                            gaplessPlayback: true,
                          ),
                        ),
                      for (final p in battle.participants.where((p) =>
                          p.inviteStatus ==
                          ParticipantInviteStatus.accepted))
                        _ForestAvatar(
                          participant: p,
                          worldY: _avatarWorldYForest(
                              _displayedProgress[p.userId] ?? 0.0),
                          tileSize: tileSize,
                          avatarHeight: tileH * 0.085,
                          isMe: p.userId == uid,
                          isLeader: ctx.leaderId == p.userId,
                          isWinner: ctx.frozen &&
                              (battle.winnerId != null
                                  ? p.userId == battle.winnerId
                                  : p.userId == ctx.leaderId),
                          onTap: p.userId == uid
                              ? null
                              : () =>
                                  showArenaProfilePeek(context, p.userId),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            ..._sharedChrome(battle, ctx, showFit: false),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // City scene — single landscape tile, InteractiveViewer.
  // ---------------------------------------------------------------------------

  Widget _buildCityScene(BattleModel battle, String uid) {
    final ctx = _arenaContext(battle, uid);

    return LayoutBuilder(
      builder: (bctx, c) {
        // Render the tile at viewport HEIGHT so it always fills vertically;
        // its width follows the natural 2:1 aspect so the trail is generous
        // and the user can pan/zoom to explore it.
        final tileH = c.maxHeight;
        final tileW = tileH * 2;
        _cityTile = Size(tileW, tileH);
        _cityViewport = Size(c.maxWidth, c.maxHeight);

        final avatarSize = tileH * 0.075;

        return Stack(
          fit: StackFit.expand,
          children: [
            // The world (tile + avatars), wrapped in InteractiveViewer so
            // pinch-zoom and two-finger pan work out of the box. We allow
            // a wide zoom range and let the user explore freely; auto-
            // follow runs in parallel via `_cityXform`.
            InteractiveViewer(
              transformationController: _cityXform,
              minScale: 0.6,
              maxScale: 4.0,
              constrained: false,
              boundaryMargin: EdgeInsets.symmetric(
                horizontal: c.maxWidth,
                vertical: c.maxHeight,
              ),
              onInteractionStart: (_) {
                _manualXformUntil = _time + _manualLockoutSeconds;
              },
              child: SizedBox(
                width: tileW,
                height: tileH,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Image.asset(
                        ArenaPack.city.assetFor(_timeOfDay),
                        fit: BoxFit.fill,
                        gaplessPlayback: true,
                      ),
                    ),
                    for (final p in battle.participants.where((p) =>
                        p.inviteStatus ==
                        ParticipantInviteStatus.accepted))
                      _CityAvatar(
                        participant: p,
                        progress: _displayedProgress[p.userId] ?? 0.0,
                        tileSize: _cityTile,
                        avatarSize: avatarSize,
                        isMe: p.userId == uid,
                        isLeader: ctx.leaderId == p.userId,
                        isWinner: ctx.frozen &&
                            (battle.winnerId != null
                                ? p.userId == battle.winnerId
                                : p.userId == ctx.leaderId),
                        onTap: p.userId == uid
                            ? null
                            : () =>
                                showArenaProfilePeek(context, p.userId),
                      ),
                  ],
                ),
              ),
            ),
            ..._sharedChrome(battle, ctx, showFit: true),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Shared chrome (top bar, toast, leaderboard pill).
  // ---------------------------------------------------------------------------

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

    String? leaderId;
    int leaderSteps = -1;
    for (final p in battle.participants) {
      if (p.inviteStatus != ParticipantInviteStatus.accepted) continue;
      if (p.currentSteps > leaderSteps) {
        leaderSteps = p.currentSteps;
        leaderId = p.userId;
      }
    }
    if (leaderSteps <= 0) leaderId = null;

    return _ArenaContext(
      frozen: frozen,
      remaining: remaining,
      total: total,
      potXp: potXp,
      leaderId: leaderId,
      uid: uid,
    );
  }

  List<Widget> _sharedChrome(
    BattleModel battle,
    _ArenaContext ctx, {
    required bool showFit,
  }) {
    final flashAlpha =
        (_flashUntil - _time > 0) ? ((_flashUntil - _time) / 0.6) : 0.0;
    return [
      if (flashAlpha > 0)
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              color: AppColors.primary
                  .withValues(alpha: flashAlpha * 0.18),
            ),
          ),
        ),
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
              const SizedBox(width: 6),
              _GlassIconBtn(
                icon: Icons.layers_outlined,
                onTap: _openPackChooser,
              ),
              if (showFit) ...[
                const SizedBox(width: 6),
                _GlassIconBtn(
                  icon: Icons.center_focus_strong,
                  onTap: _fitCityToRunners,
                ),
              ],
              const Spacer(),
              CountdownRing(remaining: ctx.remaining, total: ctx.total),
              const Spacer(),
              _PotBadge(xp: ctx.potXp, isStake: battle.stakeXp > 0),
            ],
          ),
        ),
      ),
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
  final String? leaderId;
  final String uid;

  _ArenaContext({
    required this.frozen,
    required this.remaining,
    required this.total,
    required this.potXp,
    required this.leaderId,
    required this.uid,
  });
}

// =============================================================================
// Forest avatar — positioned by absolute world Y; tile-modulo sampling
// keeps it on the path within whichever tile copy it's in.
// =============================================================================

class _ForestAvatar extends StatelessWidget {
  final BattleParticipant participant;
  final double worldY;
  final Size tileSize;
  final double avatarHeight;
  final bool isMe;
  final bool isLeader;
  final bool isWinner;
  final VoidCallback? onTap;

  const _ForestAvatar({
    required this.participant,
    required this.worldY,
    required this.tileSize,
    required this.avatarHeight,
    required this.isMe,
    required this.isLeader,
    required this.isWinner,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tileH = tileSize.height;
    final yWithinTile = worldY % tileH;
    final progressInTile = (yWithinTile / tileH).clamp(0.0, 1.0);

    final pathPoint = BattlegroundPath.positionInTile(
      progressInTile,
      tileSize,
      pack: ArenaPack.forest,
    );
    final naturalTangent =
        BattlegroundPath.tangentAt(progressInTile, pack: ArenaPack.forest);
    // Forest path runs top→bottom; runners move bottom→top through the
    // stacked world, so the visual tangent is the opposite of natural.
    final tangent = Offset(-naturalTangent.dx, -naturalTangent.dy);
    final angle = math.atan2(tangent.dx, -tangent.dy);

    final size = avatarHeight;
    final left = pathPoint.dx - size / 2;
    final top = worldY - size / 2;

    return Positioned(
      left: left,
      top: top,
      width: size,
      height: size,
      child: _RunnerSprite(
        participant: participant,
        angle: angle,
        isMe: isMe,
        isLeader: isLeader,
        isWinner: isWinner,
        onTap: onTap,
      ),
    );
  }
}

// =============================================================================
// City avatar — positioned within a single landscape tile by progress.
// =============================================================================

class _CityAvatar extends StatelessWidget {
  final BattleParticipant participant;
  final double progress;
  final Size tileSize;
  final double avatarSize;
  final bool isMe;
  final bool isLeader;
  final bool isWinner;
  final VoidCallback? onTap;

  const _CityAvatar({
    required this.participant,
    required this.progress,
    required this.tileSize,
    required this.avatarSize,
    required this.isMe,
    required this.isLeader,
    required this.isWinner,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final pathPoint = BattlegroundPath.positionInTile(
      progress,
      tileSize,
      pack: ArenaPack.city,
    );
    final tangent =
        BattlegroundPath.tangentAt(progress, pack: ArenaPack.city);
    // City path runs left→right and runners move left→right too — no
    // tangent negation needed.
    final angle = math.atan2(tangent.dx, -tangent.dy);

    return Positioned(
      left: pathPoint.dx - avatarSize / 2,
      top: pathPoint.dy - avatarSize / 2,
      width: avatarSize,
      height: avatarSize,
      child: _RunnerSprite(
        participant: participant,
        angle: angle,
        isMe: isMe,
        isLeader: isLeader,
        isWinner: isWinner,
        onTap: onTap,
      ),
    );
  }
}

// =============================================================================
// Shared runner sprite — visual stack (glow + sprite + badges + step chip).
// =============================================================================

class _RunnerSprite extends StatelessWidget {
  final BattleParticipant participant;
  final double angle;
  final bool isMe;
  final bool isLeader;
  final bool isWinner;
  final VoidCallback? onTap;

  const _RunnerSprite({
    required this.participant,
    required this.angle,
    required this.isMe,
    required this.isLeader,
    required this.isWinner,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final avatarId = participant.battleAvatarId ?? Avatar.defaultAvatar.id;
    final assetPath = Avatar.byId(avatarId).assetPath;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (isMe)
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.55),
                      blurRadius: 14,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              ),
            ),
          Transform.rotate(
            angle: angle,
            child: Image.asset(
              assetPath,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          ),
          if (isLeader && !isWinner)
            Positioned(
              top: -10,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.amber,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'LEAD',
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      fontSize: 8,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.2,
                      color: Colors.black,
                    ),
                  ),
                ),
              ),
            ),
          if (isWinner)
            Positioned(
              top: -14,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.tertiary,
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.tertiary.withValues(alpha: 0.5),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                  child: const Text(
                    'WINNER',
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.5,
                      color: Colors.black,
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            bottom: -16,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${participant.currentSteps}',
                  style: const TextStyle(
                    fontFamily: 'Manrope',
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Pack chooser bottom sheet — two cards, side by side.
// =============================================================================

class _PackChooserSheet extends StatelessWidget {
  final ArenaPack current;
  const _PackChooserSheet({required this.current});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 18),
                  decoration: BoxDecoration(
                    color: AppColors.onSurface.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                'Choose your arena',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Forest is portrait. City is landscape — flip your phone.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: _PackCard(
                      pack: ArenaPack.forest,
                      previewAsset:
                          ArenaPack.forest.assetFor(BattlegroundTimeOfDay.afternoon),
                      selected: current == ArenaPack.forest,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _PackCard(
                      pack: ArenaPack.city,
                      previewAsset:
                          ArenaPack.city.assetFor(BattlegroundTimeOfDay.afternoon),
                      selected: current == ArenaPack.city,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PackCard extends StatelessWidget {
  final ArenaPack pack;
  final String previewAsset;
  final bool selected;
  const _PackCard({
    required this.pack,
    required this.previewAsset,
    required this.selected,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.of(context).pop(pack),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.16)
              : AppColors.onSurface.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? AppColors.primary
                : AppColors.onSurface.withValues(alpha: 0.08),
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.asset(
                  previewAsset,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  pack.label,
                  style: const TextStyle(
                    fontFamily: 'Manrope',
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
                const Spacer(),
                if (selected)
                  Icon(
                    Icons.check_circle,
                    color: AppColors.primary,
                    size: 18,
                  ),
              ],
            ),
            Text(
              pack.isLandscape ? 'Landscape · zoomable' : 'Portrait · scroll',
              style: TextStyle(
                fontFamily: 'Manrope',
                color: AppColors.onSurface.withValues(alpha: 0.55),
                fontSize: 10,
              ),
            ),
          ],
        ),
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
            border: Border.all(color: AppColors.onSurface.withValues(alpha: 0.12)),
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

