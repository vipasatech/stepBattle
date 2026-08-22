import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/colors.dart';
import '../../models/battle_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/battle_provider.dart';
import '../../services/battleground_tile.dart';
import '../../widgets/shimmer_loader.dart';
import 'widgets/countdown_ring.dart';
import 'widgets/leaderboard_pill.dart';

/// Battle-ground arena — top-down 2D scroll of a Blender-rendered city
/// with runner avatars overlaid on the road.
///
/// Layout:
///   • Single PNG per TOD at `assets/images/battleground/cityView/
///     arena_{tod}.png` (1080 × 4320, rendered from Blender)
///   • Image scaled to viewport width, height proportional
///   • Runner sprites overlaid at rank-derived positions on the central
///     cobblestone road, side-by-side when steps tie
///   • Rank badges (gold/silver/bronze/purple) on each avatar
///   • Tap avatar → floating profile card → navigate to user page
///   • Opening cinematic: pans top → bottom → user, skip pill top-right
class BattleGroundScreen extends ConsumerStatefulWidget {
  final String battleId;

  const BattleGroundScreen({super.key, required this.battleId});

  @override
  ConsumerState<BattleGroundScreen> createState() =>
      _BattleGroundScreenState();
}

class _BattleGroundScreenState extends ConsumerState<BattleGroundScreen>
    with TickerProviderStateMixin {
  // Arena PNG intrinsic size — must match the Blender export.
  static const double _kArenaImgWidth = 1080.0;
  static const double _kArenaImgHeight = 4320.0;
  static const double _kArenaAspect = _kArenaImgHeight / _kArenaImgWidth;

  /// Peak zoom during the cinematic. 1.5 gives a noticeable "camera in
  /// close" feel without cropping so much that the road disappears.
  static const double _kCinematicZoom = 1.5;

  late final BattlegroundTimeOfDay _timeOfDay;

  final ScrollController _scrollController = ScrollController();

  /// Drives the cinematic zoom. value 0.0 → scale 1.0 (normal),
  /// value 1.0 → scale `_kCinematicZoom` (fully zoomed). Runs in parallel
  /// with the scroll animation.
  late final AnimationController _zoomController;

  /// Drives the cinematic Y translate (Option C centering compensation).
  /// When a target row's ideal scroll position is outside `[0, maxScroll]`
  /// the scroll clamps and the row would end up off-centre. Translating
  /// the whole scaled view by `clampedScroll − idealScroll` slides the
  /// row exactly to viewport centre. Value interpolates `_translateStart`
  /// → `_translateEnd` under an easeInOutCubic curve.
  late final AnimationController _translateController;
  double _translateStart = 0;
  double _translateEnd = 0;

  /// The opening cinematic runs on the first LayoutBuilder pass that
  /// has battle data. Flag prevents it re-firing on rebuilds.
  bool _cinematicStarted = false;

  /// True while the cinematic is actively animating. Blocks user
  /// scroll input (via `NeverScrollableScrollPhysics`) and shows the
  /// Skip pill top-right.
  bool _cinematicRunning = false;

  /// The current user's avatar position — cached each build so the
  /// auto-recentre timer can animate scroll back to them without
  /// having to re-derive positions from the battle. Null before the
  /// first arena build, or if the user is not an accepted participant.
  _AvatarPos? _userPos;

  /// The leader's avatar position — cached each build so the step-gap
  /// indicator can render without recomputing positions.
  _AvatarPos? _leaderPos;

  /// Fires 3 s after the last user scroll gesture ends. Callback
  /// animates the scroll view back to the current user's row.
  Timer? _autoRecentreTimer;

  static const Duration _kAutoRecentreDelay = Duration(seconds: 3);
  static const Duration _kAutoRecentreAnimation = Duration(milliseconds: 800);

  @override
  void initState() {
    super.initState();
    _timeOfDay = BattlegroundTimeOfDay.forNow();
    _zoomController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    _translateController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    // Self-refresh the current user's snapshotted battle avatar to
    // whatever they currently have picked in their profile. Cheap
    // no-op when they haven't changed avatars since the battle was
    // created. Fixes the case where a user picked Runner 10 AFTER
    // joining a battle and expected the arena to reflect that; the
    // creator's snapshot took the older value. Post-frame so
    // widget-tree init isn't blocked on a Supabase round-trip.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final uid = ref.read(authStateProvider).valueOrNull?.id;
      if (uid == null) return;
      ref
          .read(battleServiceProvider)
          .refreshOwnBattleAvatar(
            battleId: widget.battleId,
            userId: uid,
          );
    });
  }

  @override
  void dispose() {
    _autoRecentreTimer?.cancel();
    _zoomController.dispose();
    _translateController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Animate the scroll view back to the current user's row after
  /// [_kAutoRecentreDelay] of inactivity. No-op if the user is already
  /// centred, if the cinematic is running, or if we lost the cached
  /// position for some reason.
  void _returnToUser() {
    if (!mounted || _cinematicRunning) return;
    final pos = _userPos;
    if (pos == null || !_scrollController.hasClients) return;
    final target = _scrollTargetFor(pos);
    final current = _scrollController.offset;
    // Already within 5 px — don't fire a useless animation and don't
    // trigger a self-perpetuating ScrollEndNotification loop.
    if ((target - current).abs() < 5) return;
    _scrollController.animateTo(
      target,
      duration: _kAutoRecentreAnimation,
      curve: Curves.easeInOutCubic,
    );
  }

  /// Current scale factor derived from the zoom controller.
  double get _currentZoomScale =>
      1.0 + _zoomController.value * (_kCinematicZoom - 1.0);

  /// Current translate value — eased interpolation between the beat's
  /// start and end targets. Applied INSIDE the scale transform so the
  /// centring correction is scale-invariant.
  double get _currentTranslateY {
    final t = Curves.easeInOutCubic.transform(_translateController.value);
    return _translateStart + (_translateEnd - _translateStart) * t;
  }

  /// Compute the translate needed to bring [pos] to exact viewport centre
  /// at any zoom level. Non-zero only when the ideal scroll target for
  /// the row falls outside the scroll extent (i.e., the row is close
  /// enough to the top or bottom of the arena that scroll alone can't
  /// centre it). Formula: `translate = clampedScroll − idealScroll`.
  double _translateFor(_AvatarPos pos) {
    if (!_scrollController.hasClients) return 0;
    final vp = _scrollController.position.viewportDimension;
    final centreY = pos.top + pos.size / 2;
    final ideal = centreY - vp / 2;
    final clamped =
        ideal.clamp(0.0, _scrollController.position.maxScrollExtent);
    return clamped - ideal;
  }

  /// Kick off a new translate animation to [target] over [duration].
  /// Sets [_translateStart] to the current translate so the animation
  /// starts smoothly from wherever the previous beat left off.
  Future<void> _animateTranslate(double target, Duration duration) async {
    _translateStart = _currentTranslateY;
    _translateEnd = target;
    _translateController.duration = duration;
    await _translateController.forward(from: 0.0);
  }

  // ---------------------------------------------------------------------------
  // Opening cinematic
  // ---------------------------------------------------------------------------

  /// Video-style cinematic:
  ///   1. Zoom in on the leader (rank #1) — scroll and scale animate together.
  ///   2. Stay zoomed. Pan along the road from leader → trailing player.
  ///   3. Stay zoomed. Pan to the current user.
  ///   4. Zoom out — settle at scale 1.0 with the user centred.
  Future<void> _runCinematic(List<_AvatarPos> positions, String uid) async {
    if (_cinematicRunning || positions.isEmpty) return;
    final leader = positions.first;
    final trailing = positions.last;
    _AvatarPos? me;
    for (final p in positions) {
      if (p.participant.userId == uid) {
        me = p;
        break;
      }
    }
    me ??= trailing;

    setState(() => _cinematicRunning = true);

    // Give the scroll controller a beat to attach after the first
    // build so animateTo doesn't no-op.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (!mounted || !_cinematicRunning) return;

    Future<void> panTo(_AvatarPos p, Duration d) async {
      if (!_scrollController.hasClients) return;
      final target = _scrollTargetFor(p);
      await _scrollController.animateTo(
        target,
        duration: d,
        curve: Curves.easeInOutCubic,
      );
    }

    Future<void> hold(Duration d) => Future<void>.delayed(d);

    // Beat 1: zoom IN + scroll to leader + translate to centre leader.
    await Future.wait<void>([
      _zoomController.animateTo(
        1.0,
        duration: const Duration(milliseconds: 1600),
        curve: Curves.easeInOutCubic,
      ),
      panTo(leader, const Duration(milliseconds: 1600)),
      _animateTranslate(
          _translateFor(leader), const Duration(milliseconds: 1600)),
    ]);
    if (!mounted || !_cinematicRunning) return;
    await hold(const Duration(milliseconds: 350));
    if (!mounted || !_cinematicRunning) return;

    // Beat 2: stay zoomed, pan leader → trailing, translate to centre
    // trailing.
    await Future.wait<void>([
      panTo(trailing, const Duration(milliseconds: 1600)),
      _animateTranslate(
          _translateFor(trailing), const Duration(milliseconds: 1600)),
    ]);
    if (!mounted || !_cinematicRunning) return;
    await hold(const Duration(milliseconds: 350));
    if (!mounted || !_cinematicRunning) return;

    // Beat 3: stay zoomed, pan to the user's row + centre-translate.
    await Future.wait<void>([
      panTo(me, const Duration(milliseconds: 1200)),
      _animateTranslate(
          _translateFor(me), const Duration(milliseconds: 1200)),
    ]);
    if (!mounted || !_cinematicRunning) return;

    // Beat 4: zoom OUT + settle translate to 0 (restore normal scroll
    // framing at the user's row).
    await Future.wait<void>([
      _zoomController.animateBack(
        0.0,
        duration: const Duration(milliseconds: 800),
        curve: Curves.easeInOutCubic,
      ),
      _animateTranslate(0, const Duration(milliseconds: 800)),
    ]);
    if (!mounted) return;
    setState(() => _cinematicRunning = false);
  }

  /// User tapped Skip during the cinematic — cancel every in-flight
  /// animation, reset zoom to 1.0, jump straight to their own row.
  void _skipCinematic(List<_AvatarPos> positions, String uid) {
    if (!_cinematicRunning) return;
    _AvatarPos? me;
    for (final p in positions) {
      if (p.participant.userId == uid) {
        me = p;
        break;
      }
    }
    me ??= positions.isNotEmpty ? positions.last : null;
    _zoomController.stop();
    _zoomController.value = 0.0;
    _translateController.stop();
    _translateStart = 0;
    _translateEnd = 0;
    _translateController.value = 0.0;
    if (me != null && _scrollController.hasClients) {
      _scrollController.jumpTo(_scrollTargetFor(me));
    }
    setState(() => _cinematicRunning = false);
  }

  /// Scroll offset that vertically centres [pos] in the viewport,
  /// clamped so we don't overshoot the top / bottom of the scroll area.
  double _scrollTargetFor(_AvatarPos pos) {
    if (!_scrollController.hasClients) return 0.0;
    final viewportHeight = _scrollController.position.viewportDimension;
    final centreY = pos.top + pos.size / 2;
    final target = centreY - viewportHeight / 2;
    return target.clamp(0.0, _scrollController.position.maxScrollExtent);
  }

  // ---------------------------------------------------------------------------
  // Profile card popup
  // ---------------------------------------------------------------------------

  Future<void> _showProfileCard(
      _AvatarPos pos, int totalParticipants) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (dialogCtx) => _ProfileCard(
        pos: pos,
        totalParticipants: totalParticipants,
        onOpenProfile: () {
          Navigator.of(dialogCtx).pop();
          context.push('/users/${pos.participant.userId}');
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final battleAsync = ref.watch(battleDetailProvider(widget.battleId));
    final goalsAsync =
        ref.watch(battleParticipantGoalsProvider(widget.battleId));
    final uid = ref.watch(authStateProvider).valueOrNull?.id ?? '';

    return Scaffold(
      backgroundColor: Colors.black,
      body: battleAsync.when(
        loading: () => const _ArenaShimmer(),
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
          // Arena no longer auto-completes battles client-side (see
          // battle_service.completeExpiredBattles block comment). If
          // the user lands here on an active-past-end-time battle,
          // the server cron settles it within ~60 s and the arena
          // rebuilds when battleDetailProvider streams the completed
          // state. In the interim the arena still animates against
          // whatever current_steps are cached.
          // Block the arena on step-goals fetch — the positions depend
          // on the collective daily-goal average and starting the
          // cinematic against a fallback map would then jitter runners
          // when the fetch resolves. Fetch is one batched query, ~100
          // ms typical; a brief spinner is cleaner than mid-cinematic
          // jump. On error, fall back to a synthetic goals map keyed
          // to defaults so the arena still opens.
          return goalsAsync.when(
            loading: () => const _ArenaShimmer(),
            error: (_, __) =>
                _buildArenaScene(battle, uid, const <String, int>{}),
            data: (goals) => _buildArenaScene(battle, uid, goals),
          );
        },
      ),
    );
  }

  Widget _buildArenaScene(
      BattleModel battle, String uid, Map<String, int> stepGoals) {
    final ctx = _arenaContext(battle, uid);
    final assetPath =
        'assets/images/battleground/cityView/arena_${_timeOfDay.name}.png';
    final durationDays = _battleDurationDays(battle);

    return LayoutBuilder(builder: (context, constraints) {
      final viewportWidth = constraints.maxWidth;
      final scaledImgHeight = viewportWidth * _kArenaAspect;

      // Compute avatar positions once — used both for the visual overlay
      // and for the cinematic scroll targets.
      final positions = _computeAvatarPositions(
        battle,
        uid,
        viewportWidth,
        scaledImgHeight,
        stepGoals,
        durationDays,
      );

      // Cache leader + current-user positions for the auto-recentre
      // timer and the step-gap indicator. Iterate once instead of
      // filtering the list twice.
      _AvatarPos? me;
      for (final p in positions) {
        if (p.isMe) {
          me = p;
          break;
        }
      }
      _userPos = me;
      _leaderPos = positions.isNotEmpty ? positions.first : null;

      // Kick off the cinematic on the first pass that has real viewport
      // dimensions. Post-frame callback so the ScrollController is
      // attached before animateTo tries to run.
      if (!_cinematicStarted && positions.isNotEmpty) {
        _cinematicStarted = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _runCinematic(positions, uid);
        });
      }

      // Step-gap indicator visibility. Hidden during the cinematic (so
      // it doesn't jitter under the zoom+pan). Otherwise ALWAYS shown
      // between the #1 and #2 spots (regardless of who "me" is) —
      // this way both devices in a 1v1 see the same on-road arrow +
      // gap number (fixed 1.1.6+27; prior implementation only rendered
      // on the trailer's device because it anchored between leader
      // and `me`, meaning the leader saw nothing).
      final leader = _leaderPos;
      final runnerUp = positions.length > 1 ? positions[1] : null;
      final gapSteps = (leader != null && runnerUp != null)
          ? leader.participant.currentSteps -
              runnerUp.participant.currentSteps
          : 0;
      final showGap = !_cinematicRunning &&
          leader != null &&
          runnerUp != null &&
          gapSteps > 0;

      // The scroll view is wrapped in ClipRect + Transform.scale so the
      // cinematic can "zoom in" on the arena. Transform.scale is
      // centred on the viewport, so the row currently centred by
      // scroll position stays visually centred at any zoom level —
      // scroll-target math is unchanged. ClipRect prevents the scaled
      // view from spilling outside its layout bounds.
      final scrollView = SingleChildScrollView(
        controller: _scrollController,
        physics: _cinematicRunning
            ? const NeverScrollableScrollPhysics()
            : const BouncingScrollPhysics(),
        child: SizedBox(
          width: viewportWidth,
          height: scaledImgHeight,
          child: Stack(
            children: [
              Positioned.fill(
                child: Image.asset(
                  assetPath,
                  fit: BoxFit.fill,
                  filterQuality: FilterQuality.high,
                ),
              ),
              // Step-gap indicator sits BELOW the avatars in Z-order,
              // so runners always draw on top of the line/pill.
              // Anchors between the #1 and #2 spots so both devices
              // in a 1v1 see the same arrow.
              if (showGap)
                _StepGapIndicator(
                  leaderPos: leader,
                  trailerPos: runnerUp,
                  gapSteps: gapSteps,
                  viewportWidth: viewportWidth,
                ),
              for (final pos in positions)
                _AvatarSpot(
                  key: ValueKey('avatar-${pos.participant.userId}'),
                  pos: pos,
                  onTap: () => _showProfileCard(pos, positions.length),
                ),
            ],
          ),
        ),
      );

      // Auto-recentre: any user-driven scroll cancels the pending
      // return, and on scroll-end we schedule a new one for 3 s later.
      // Programmatic scrolls (cinematic beats, our own animateTo)
      // still fire notifications but we filter them: only
      // `ScrollUpdateNotification.dragDetails != null` counts as user
      // input, and we skip scheduling once the scroll is at the
      // user's target (avoids a self-perpetuating loop).
      final scrollListened = NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (_cinematicRunning) return false;
          if (n is ScrollStartNotification ||
              n is ScrollUpdateNotification) {
            _autoRecentreTimer?.cancel();
          } else if (n is ScrollEndNotification) {
            _autoRecentreTimer?.cancel();
            final target = me == null ? null : _scrollTargetFor(me);
            if (target != null &&
                _scrollController.hasClients &&
                (_scrollController.offset - target).abs() > 5) {
              _autoRecentreTimer = Timer(
                  _kAutoRecentreDelay, _returnToUser);
            }
          }
          return false;
        },
        child: scrollView,
      );

      return Stack(
        fit: StackFit.expand,
        children: [
          ClipRect(
            // Transform.translate is INSIDE Transform.scale so the
            // centring correction lives in the scaled child's local
            // coordinate space. That makes the translate scale-
            // invariant: the same `T = clampedScroll − idealScroll`
            // centres the target row at any zoom level.
            child: AnimatedBuilder(
              animation: Listenable.merge(
                  [_zoomController, _translateController]),
              builder: (context, child) => Transform.scale(
                scale: _currentZoomScale,
                alignment: Alignment.center,
                child: Transform.translate(
                  offset: Offset(0, _currentTranslateY),
                  child: child,
                ),
              ),
              child: scrollListened,
            ),
          ),
          ..._sharedChrome(battle, ctx, positions, uid),
        ],
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Avatar positioning
  // ---------------------------------------------------------------------------

  /// Battle length in whole days (min 1). Used with the participants'
  /// average daily step goal to derive the arena's positioning scale:
  /// `MIN_SCALE = avgDailyGoal × durationDays`. A 3-day battle with
  /// 8000-step average → 24000-step scale, so a runner has to walk
  /// 24000 steps before they anchor at the top of the arena.
  int _battleDurationDays(BattleModel battle) {
    final delta = battle.endTime.difference(battle.startTime);
    final days = (delta.inMinutes / (24 * 60)).ceil();
    return days < 1 ? 1 : days;
  }

  /// Turn a battle's participants into runner-sprite positions on the
  /// arena.
  ///
  /// **Step-anchored positioning.** Rows are placed by each runner's
  /// step-count relative to a `scale` value, NOT by rank. That means
  /// two runners at 200 vs 202 steps end up nearly on top of each
  /// other (they're neck-and-neck), while a leader at 5000 and a
  /// trailing player at 200 have a large visible road between them —
  /// the arena's vertical distance means "actual step gap", not
  /// "position in the standings".
  ///
  /// **Adaptive scale.** The old formula was
  /// `scale = max(leaderSteps, avgDailyGoal × durationDays)`, which
  /// meant early in a battle EVERYONE clustered near the start line
  /// because they were all only a few percent of the way to the
  /// daily goal — a 425-vs-19 lead (~22× ratio) rendered visually
  /// indistinguishable from a 425-vs-400 lead. Now the scale
  /// switches based on how far the leader has come:
  ///
  ///   • Leader hasn't reached the collective daily target yet:
  ///     `scale = max(leaderSteps × 1.15, 100)`. The leader
  ///     anchors near the top of the arena and everyone else scales
  ///     against them. Small absolute step counts now produce a
  ///     visible spread because the frame zooms in on the current
  ///     pack instead of the full unwalked road.
  ///   • Leader has crossed the collective daily target:
  ///     `scale = leaderSteps`. Same as before — leader anchors at
  ///     the very top, everyone else scales relative to their own
  ///     step total. Preserves the "road to the goal" visual for
  ///     the endgame of a battle.
  ///
  /// Ties (**exact** step-count matches only) render side-by-side on
  /// one row. Near-ties (different step counts but similar positions)
  /// stay on separate rows.
  List<_AvatarPos> _computeAvatarPositions(
    BattleModel battle,
    String currentUid,
    double viewportWidth,
    double scaledImgHeight,
    Map<String, int> stepGoals,
    int durationDays,
  ) {
    final accepted = battle.participants
        .where((p) => p.inviteStatus == ParticipantInviteStatus.accepted)
        .toList()
      ..sort((a, b) => b.currentSteps.compareTo(a.currentSteps));
    if (accepted.isEmpty) return const [];

    final avatarSize = viewportWidth * 0.14;
    final gap = avatarSize * 0.30;

    // Runners occupy this vertical band on the arena. Leader anchored
    // at 10% (front of the pack); start-line at 85% (bottom of arena
    // with breathing room below the last runner).
    const double topFrac = 0.10;
    const double bottomFrac = 0.85;

    // Collective daily step goal — mean over the accepted participants.
    // Missing rows (RLS, race, or new user) fall back to the default
    // 8000-step goal so one missing lookup doesn't skew the average.
    double sum = 0;
    for (final p in accepted) {
      final g = stepGoals[p.userId];
      sum += (g != null && g > 0) ? g : 8000;
    }
    final avgGoal = sum / accepted.length;
    final collectiveTarget = avgGoal * durationDays;
    final leaderSteps = accepted.first.currentSteps.toDouble();

    // Adaptive scale — see the docstring above for the full
    // rationale. In short: if the leader hasn't reached the daily
    // target yet, we zoom the arena in on the current pack so
    // step-ratio differences at low absolute counts stay visible.
    // Otherwise we use the leader-anchored scale so the endgame
    // reads as "how close is everyone to the winner."
    //
    // The `× 1.15` headroom leaves ~13% of the runway above the
    // leader so their sprite isn't clipped by the top of the arena.
    // The `100.0` floor guards a fresh battle where every runner
    // has 0 steps — without it, `leaderSteps × 1.15` collapses to
    // 0 and we'd divide by zero downstream. `100` is small enough
    // that the first real step still shifts a runner visibly off
    // the start line.
    final double scale;
    if (leaderSteps >= collectiveTarget) {
      scale = leaderSteps;
    } else {
      final compressed = leaderSteps * 1.15;
      scale = compressed > 100.0 ? compressed : 100.0;
    }

    // Group runners into shared rows by **pixel proximity**, not
    // exact-tie step counts. The old exact-tie rule left every
    // near-neck-and-neck pair on separate rows whose step-based Y
    // positions could land within one avatar height of each other —
    // sprites then overlapped visibly (11-vs-0 with scale=100 =
    // ~66 px vertical gap, avatar height ~100 px, ~35 px overlap).
    //
    // Two-pass:
    //   1) Compute each accepted runner's ideal center-Y from their
    //      step count (unchanged formula).
    //   2) Walk the rank-ordered list; if the current runner's Y is
    //      within `avatarSize + minVerticalGap` of the previous
    //      row's Y, merge them into the same row (side-by-side).
    //      Otherwise start a new row at the current Y.
    //
    // Grouped runners render at the FIRST member's Y (the leader
    // among tied/near-tied runners), preserving "leader anchors the
    // row" reading. Exact ties still work because their Y positions
    // are identical, which trivially passes the proximity check.
    const double minVerticalGap = 8.0;
    final rowMergeThreshold = avatarSize + minVerticalGap;

    double centreYFor(BattleParticipant p) {
      final progress = scale > 0 ? p.currentSteps / scale : 0.0;
      final vFrac = bottomFrac - progress * (bottomFrac - topFrac);
      return scaledImgHeight * vFrac;
    }

    final List<List<BattleParticipant>> groups = [];
    final List<double> groupYs = [];
    for (final p in accepted) {
      final y = centreYFor(p);
      if (groups.isNotEmpty && (y - groupYs.last).abs() < rowMergeThreshold) {
        // Close enough to the previous row's Y — pack side-by-side.
        // Row keeps the leader's Y so the leader appears to anchor
        // the row rather than the row drifting toward the trailer.
        groups.last.add(p);
      } else {
        groups.add([p]);
        groupYs.add(y);
      }
    }

    final positions = <_AvatarPos>[];
    int flatRank = 0;

    for (int gi = 0; gi < groups.length; gi++) {
      final group = groups[gi];
      final centreY = groupYs[gi];

      final n = group.length;
      final rowWidth = n * avatarSize + (n - 1) * gap;
      // Shift by _kRoadOffsetFrac so runners sit on the cobblestone's
      // true centre, not the viewport's centre (see the constant's doc).
      final rowCentreX = viewportWidth / 2 + viewportWidth * _kRoadOffsetFrac;
      final rowStartX = rowCentreX - rowWidth / 2;

      for (int i = 0; i < n; i++) {
        final p = group[i];
        flatRank++;
        positions.add(_AvatarPos(
          participant: p,
          rank: flatRank,
          isMe: p.userId == currentUid,
          top: centreY - avatarSize / 2,
          left: rowStartX + i * (avatarSize + gap),
          size: avatarSize,
        ));
      }
    }
    return positions;
  }

  // ---------------------------------------------------------------------------
  // Chrome
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

    return _ArenaContext(
      frozen: frozen,
      remaining: remaining,
      total: total,
      potXp: potXp,
      uid: uid,
    );
  }

  List<Widget> _sharedChrome(BattleModel battle, _ArenaContext ctx,
      List<_AvatarPos> positions, String uid) {
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
          // Stack instead of Row-with-Spacers so the countdown ring
          // anchors to the SCREEN centre regardless of how wide the
          // side chips are. With a Row + Spacers, the ring drifts left
          // when the pot badge (right) is wider than the close button
          // (left) — which it usually is.
          child: Stack(
            alignment: Alignment.topCenter,
            children: [
              CountdownRing(remaining: ctx.remaining, total: ctx.total),
              Align(
                alignment: Alignment.topLeft,
                child: _GlassIconBtn(
                  icon: Icons.close,
                  onTap: () => context.pop(),
                ),
              ),
              Align(
                alignment: Alignment.topRight,
                child: _PotBadge(
                    xp: ctx.potXp, isStake: battle.stakeXp > 0),
              ),
            ],
          ),
        ),
      ),
      // Skip pill — only visible while cinematic is running. Positioned
      // just under the top chrome row so it doesn't fight the close /
      // XP badge for the corner.
      if (_cinematicRunning)
        SafeArea(
          child: Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 60, right: 12),
              child: _SkipCinematicBtn(
                onTap: () => _skipCinematic(positions, uid),
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
              // Pill filters internally to accepted participants via
              // buildPlayerRows / buildTeamGroups — passing the whole
              // battle here lets it distinguish group vs team format
              // and render the right board variant.
              battle: battle,
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

/// Position + metadata for a single runner sprite on the arena.
class _AvatarPos {
  final BattleParticipant participant;

  /// 1-based rank in the sorted-by-steps list. Ties get sequential
  /// ranks (leader tied → 1 and 2, then the next player is 3).
  final int rank;

  final bool isMe;
  final double top;
  final double left;
  final double size;

  const _AvatarPos({
    required this.participant,
    required this.rank,
    required this.isMe,
    required this.top,
    required this.left,
    required this.size,
  });
}

/// One runner sprite on the arena. Tap opens the profile card popup.
///
/// `GestureDetector` catches taps only — no drag callbacks, so vertical
/// scroll gestures pass through to the ScrollView underneath.
class _AvatarSpot extends StatelessWidget {
  final _AvatarPos pos;
  final VoidCallback onTap;
  const _AvatarSpot({super.key, required this.pos, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final avatarId = pos.participant.battleAvatarId ?? 'avatar_01';
    final assetPath = 'assets/images/avatars/$avatarId.png';
    final badgeSize = pos.size * 0.35;

    return Positioned(
      top: pos.top,
      left: pos.left,
      width: pos.size,
      height: pos.size,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Ground shadow: soft dark ellipse just below the avatar so
            // every runner reads as "on the road" instead of "flat on
            // the pixel plane". Subtle by design — 30% black, 6px blur.
            Positioned(
              bottom: -pos.size * 0.02,
              left: pos.size * 0.18,
              right: pos.size * 0.18,
              height: pos.size * 0.10,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.30),
                  borderRadius: BorderRadius.circular(pos.size),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.35),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
            ),
            // Subtle purple glow behind the current user's avatar —
            // makes them findable without shouting. Kept lower-intensity
            // than the initial pass (0.65 α, 14 blur, +2 spread) which
            // was too heavy: 0.30 α, 10 blur, 0 spread reads as
            // "faint aura", not "burning halo".
            if (pos.isMe)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.primary.withValues(alpha: 0.30),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                ),
              ),
            Positioned.fill(
              child: Image.asset(
                assetPath,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
              ),
            ),
            // Rank badge — floats above the head, horizontally centred
            // with a 4-px gap so it never touches the character. Colour
            // by rank so #1 pops (gold) vs the pack.
            Positioned(
              top: -(badgeSize + 4),
              left: (pos.size - badgeSize) / 2,
              child: _RankBadge(rank: pos.rank, size: badgeSize),
            ),
            // "You" label below the current-user's avatar so they can
            // spot themselves at a glance without opening the popup.
            if (pos.isMe)
              Positioned(
                bottom: -pos.size * 0.20,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'You',
                      style: TextStyle(
                        color: Colors.white,
                        fontFamily: 'Manrope',
                        fontWeight: FontWeight.w800,
                        fontSize: 9,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Small circular badge showing the runner's rank in the battle.
/// Colour-graded: gold for #1, silver #2, bronze #3, purple for the rest.
class _RankBadge extends StatelessWidget {
  final int rank;
  final double size;
  const _RankBadge({required this.rank, required this.size});

  static const Color _gold = Color(0xFFFFD700);
  static const Color _silver = Color(0xFFC0C0C0);
  static const Color _bronze = Color(0xFFCD7F32);

  Color get _color {
    switch (rank) {
      case 1:
        return _gold;
      case 2:
        return _silver;
      case 3:
        return _bronze;
      default:
        return AppColors.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: _color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Text(
        '$rank',
        style: TextStyle(
          color: Colors.white,
          fontFamily: 'Manrope',
          fontSize: size * 0.55,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

/// Floating game-style profile card. Bigger avatar + name + rank + steps
/// on a rounded dark card, with a "View profile" affordance. Tap card
/// body → navigate; tap backdrop → dismiss.
class _ProfileCard extends StatelessWidget {
  final _AvatarPos pos;
  final int totalParticipants;
  final VoidCallback onOpenProfile;
  const _ProfileCard({
    required this.pos,
    required this.totalParticipants,
    required this.onOpenProfile,
  });

  @override
  Widget build(BuildContext context) {
    final p = pos.participant;
    final avatarId = p.battleAvatarId ?? 'avatar_01';
    final name = (p.preferredName?.trim().isNotEmpty ?? false)
        ? p.preferredName!.trim()
        : p.displayName;

    return Center(
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          onTap: onOpenProfile,
          child: Container(
            width: 280,
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1F),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.4)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.6),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Big avatar with rank badge overlaid
                SizedBox(
                  width: 100,
                  height: 100,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: Image.asset(
                          'assets/images/avatars/$avatarId.png',
                          fit: BoxFit.contain,
                        ),
                      ),
                      Positioned(
                        top: -6,
                        left: -6,
                        child: _RankBadge(rank: pos.rank, size: 34),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontFamily: 'Space Grotesk',
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  'Rank ${pos.rank} of $totalParticipants',
                  style: TextStyle(
                    color: AppColors.onSurfaceVariant,
                    fontFamily: 'Manrope',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: AppColors.primary.withValues(alpha: 0.35)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.directions_walk,
                          color: AppColors.primary, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        '${p.currentSteps} steps',
                        style: TextStyle(
                          color: AppColors.primary,
                          fontFamily: 'Manrope',
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.person_outline,
                        color: Colors.white.withValues(alpha: 0.7), size: 14),
                    const SizedBox(width: 4),
                    Text(
                      'View profile',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontFamily: 'Manrope',
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.chevron_right,
                        color: Colors.white.withValues(alpha: 0.7), size: 14),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Low-opacity "Skip →" pill shown top-right during the opening cinematic.
class _SkipCinematicBtn extends StatelessWidget {
  final VoidCallback onTap;
  const _SkipCinematicBtn({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.6,
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

// ─── Step-gap indicator ──────────────────────────────────────────────────
//
// Painted-on-the-road markings that visually communicate the step-gap
// between the current user and the leader. Two pieces:
//
//   1. An arrow (arrowhead + stem) painted on the cobblestone in a
//      dark path-toned ink (looks engraved / carved into the road
//      rather than pasted on top).
//   2. The gap number in WHITE, rotated 90° so the digits progress
//      along the direction of travel — like the "WELCOME" road-
//      painting reference: first digit near the user, last digit near
//      the leader, tops of the letters facing the road's left side.
//
// The arrow sits OFF the runner column (offset ~11% right of viewport
// centre) so avatars never sit on top of it. The stem splits around
// the rotated number so the two markings share the same X band
// without visually clashing.

/// Fraction of viewport width the cobblestone road is offset from
/// the arena PNG's horizontal centre. The Blender render was set up
/// with `camera.location.x = -1.0` and `ortho_scale = 130` on a
/// 1080 × 4320 portrait frame — that puts the road (world X=0)
/// about `1 / 32.5 ≈ 3.1 %` to the RIGHT of image centre. Every
/// arena element that should sit ON the road (avatars, step-gap
/// arrow, indicator text) shifts by this fraction of viewport width
/// so it lands on the road's actual centre, not the viewport's.
const double _kRoadOffsetFrac = 0.031;

/// Neutral grey "ink" for the arrow markings. Applied at gradient
/// alpha values (~0.25 near the user end to ~1.0 near the arrowhead)
/// so the arrow fades in from the tail and solidifies toward the
/// leader — visually reinforces "you're chasing that direction".
const Color _kArrowGrey = Color(0xFF606060);

/// Alpha at the arrowhead / leader end. Fully painted.
const double _kArrowAlphaTop = 1.00;

/// Alpha at the stem-tail / user end. Faint — dissolves into the road.
const double _kArrowAlphaBottom = 0.25;

class _StepGapIndicator extends StatelessWidget {
  final _AvatarPos leaderPos;

  /// The runner-up (2nd place) position. Renamed from `userPos` in
  /// 1.1.6+27 — previously this was the CURRENT user's position and
  /// the indicator only rendered on the trailer's device. Now it's
  /// anchored between #1 and #2 so both devices in a 1v1 see the
  /// same on-road arrow + gap number.
  final _AvatarPos trailerPos;
  final int gapSteps;
  final double viewportWidth;

  const _StepGapIndicator({
    required this.leaderPos,
    required this.trailerPos,
    required this.gapSteps,
    required this.viewportWidth,
  });

  /// Linear alpha at a Y in the [spanTop, spanBottom] range —
  /// [_kArrowAlphaTop] at the top edge, [_kArrowAlphaBottom] at the
  /// bottom edge. Used so every arrow segment can pick up the correct
  /// slice of the overall gradient (no manual shader continuity).
  double _alphaAtY(double y, double spanTop, double spanBottom) {
    if (spanBottom <= spanTop) return _kArrowAlphaTop;
    final t = ((y - spanTop) / (spanBottom - spanTop)).clamp(0.0, 1.0);
    return _kArrowAlphaTop + (_kArrowAlphaBottom - _kArrowAlphaTop) * t;
  }

  @override
  Widget build(BuildContext context) {
    // Buffer keeps the arrow's tip / stem's tail off the sprite outlines.
    const double endBuffer = 10;
    // Shift by _kRoadOffsetFrac to sit on the cobblestone's true centre —
    // aligns with the runners, who use the same shift.
    final arrowCentreX =
        viewportWidth / 2 + viewportWidth * _kRoadOffsetFrac;

    final spanTop = leaderPos.top + leaderPos.size + endBuffer;
    final spanBottom = trailerPos.top - endBuffer;
    final spanHeight = spanBottom - spanTop;

    if (spanHeight <= 0) return const SizedBox.shrink();

    // Marking dimensions — scaled to the arena's viewport so the arrow
    // reads roughly the same physical size on every device.
    final stemWidth = viewportWidth * 0.020; // ~8 px on 400-px viewport
    final arrowHeight = viewportWidth * 0.060; // ~24 px
    final arrowWidth = viewportWidth * 0.070; // ~28 px
    final textFontSize = viewportWidth * 0.045; // ~18 px

    final numText = gapSteps.toString(); // no comma per spec
    final midY = (spanTop + spanBottom) / 2;

    // Measure the rotated text block. Rotated 90° CCW → the original
    // text WIDTH becomes the rotated widget's HEIGHT (space taken along
    // the road), and the original text HEIGHT becomes the rotated
    // widget's WIDTH (space across the road).
    final textStyle = TextStyle(
      color: Colors.white,
      fontFamily: 'Manrope',
      fontSize: textFontSize,
      fontWeight: FontWeight.w900,
      letterSpacing: 1.5,
      height: 1.0,
      shadows: [
        Shadow(
          color: Colors.black.withValues(alpha: 0.65),
          blurRadius: 3,
          offset: const Offset(0, 1),
        ),
      ],
    );
    final tp = TextPainter(
      text: TextSpan(text: numText, style: textStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    final rotatedTextWidth = tp.height;
    final rotatedTextHeight = tp.width;

    // When the span is too small to fit arrow + rotated-text + both
    // stems, fall back to just the text at midpoint.
    const stemTextPad = 6.0;
    final minForFull =
        arrowHeight + rotatedTextHeight + stemTextPad * 2 + 8;

    Widget rotatedText() => RotatedBox(
          quarterTurns: 3, // 90° CCW — first digit at bottom, last at top
          child: Text(numText, style: textStyle),
        );

    if (spanHeight < minForFull) {
      return Positioned(
        top: midY - rotatedTextHeight / 2,
        left: arrowCentreX - rotatedTextWidth / 2,
        width: rotatedTextWidth,
        height: rotatedTextHeight,
        child: rotatedText(),
      );
    }

    final arrowTop = spanTop;
    final upperStemTop = arrowTop + arrowHeight;
    final upperStemBottom = midY - rotatedTextHeight / 2 - stemTextPad;
    final lowerStemTop = midY + rotatedTextHeight / 2 + stemTextPad;
    final lowerStemBottom = spanBottom;

    // Precompute the alpha at each segment boundary so every piece
    // renders its correct slice of the overall arrow gradient.
    final aArrowTop = _alphaAtY(arrowTop, spanTop, spanBottom);
    final aArrowBottom =
        _alphaAtY(arrowTop + arrowHeight, spanTop, spanBottom);
    final aUpperTop = _alphaAtY(upperStemTop, spanTop, spanBottom);
    final aUpperBottom = _alphaAtY(upperStemBottom, spanTop, spanBottom);
    final aLowerTop = _alphaAtY(lowerStemTop, spanTop, spanBottom);
    final aLowerBottom = _alphaAtY(lowerStemBottom, spanTop, spanBottom);

    LinearGradient stemGradient(double topAlpha, double bottomAlpha) =>
        LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            _kArrowGrey.withValues(alpha: topAlpha),
            _kArrowGrey.withValues(alpha: bottomAlpha),
          ],
        );

    return Stack(
      children: [
        // Arrowhead — pointing UP toward the leader, near-solid alpha.
        Positioned(
          top: arrowTop,
          left: arrowCentreX - arrowWidth / 2,
          width: arrowWidth,
          height: arrowHeight,
          child: CustomPaint(
            painter: _ArrowheadPainter(
              color: _kArrowGrey,
              topAlpha: aArrowTop,
              bottomAlpha: aArrowBottom,
            ),
          ),
        ),
        // Upper stem — takes its slice of the overall gradient.
        if (upperStemBottom > upperStemTop)
          Positioned(
            top: upperStemTop,
            left: arrowCentreX - stemWidth / 2,
            width: stemWidth,
            height: upperStemBottom - upperStemTop,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: stemGradient(aUpperTop, aUpperBottom),
              ),
            ),
          ),
        // Rotated number — white, running along the road.
        Positioned(
          top: midY - rotatedTextHeight / 2,
          left: arrowCentreX - rotatedTextWidth / 2,
          width: rotatedTextWidth,
          height: rotatedTextHeight,
          child: rotatedText(),
        ),
        // Lower stem — fades toward the tail near the user.
        if (lowerStemBottom > lowerStemTop)
          Positioned(
            top: lowerStemTop,
            left: arrowCentreX - stemWidth / 2,
            width: stemWidth,
            height: lowerStemBottom - lowerStemTop,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: stemGradient(aLowerTop, aLowerBottom),
              ),
            ),
          ),
      ],
    );
  }
}

/// Filled triangle apex-up — the arrowhead atop the road-marking
/// stem. Rendered with a linear alpha gradient so it sits inside the
/// overall arrow-opacity ramp (top-alpha near the apex, bottom-alpha
/// where the arrowhead meets the stem).
class _ArrowheadPainter extends CustomPainter {
  final Color color;
  final double topAlpha;
  final double bottomAlpha;

  _ArrowheadPainter({
    required this.color,
    required this.topAlpha,
    required this.bottomAlpha,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = true
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: topAlpha),
          color.withValues(alpha: bottomAlpha),
        ],
      ).createShader(rect);
    final path = Path()
      ..moveTo(size.width / 2, 0) // apex
      ..lineTo(0, size.height) // bottom-left
      ..lineTo(size.width, size.height) // bottom-right
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _ArrowheadPainter old) =>
      old.color != color ||
      old.topAlpha != topAlpha ||
      old.bottomAlpha != bottomAlpha;
}

/// Full-viewport shimmer used while the arena is loading. Fills the
/// entire Scaffold body (over the black backdrop) so the whole
/// battleground area reads as loading rather than a floating card in
/// the middle.
class _ArenaShimmer extends StatelessWidget {
  const _ArenaShimmer();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (_, constraints) => ShimmerLoader(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          borderRadius: 0,
        ),
      ),
    );
  }
}
