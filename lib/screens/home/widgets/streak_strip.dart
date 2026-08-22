import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../config/colors.dart';
import '../../../config/motion.dart';
import '../../../models/step_log_model.dart';
import '../../../providers/step_provider.dart';
import '../../../providers/streak_provider.dart';
import '../../../providers/user_provider.dart';
import '../../../services/streak_celebration_bus.dart';
import '../../../widgets/fire_particles.dart';
import '../../../widgets/streak_grey_tooltip.dart';

/// Streak strip — pinned just under the Home AppBar.
///
///   ┌──────┐  M    T    W    T    F    S    S
///   │ 🔥 2 │
///   │ Days │  29   30   01   👟   03   04   05
///   └──────┘
///                       ●  ○  ○  ○
///
/// Layout split:
///   • Left  — fixed flame badge showing the user's current streak.
///   • Right — static weekday-label row + a horizontal [PageView] of
///             week tiles. Each page = 7 day cells starting Monday.
///   • Below — page dots indicating which week is on screen.
///
/// Day-cell semantics:
///   • Today                  → filled violet circle, running-figure
///                              icon (the StepBattle brand mark).
///   • Past day               → outlined circle with date number, full
///                              opacity, tappable → /day-summary/:date.
///   • Future day in current  → outlined circle with date number, ~30 %
///     visible week             opacity, NOT tappable.
///   • Day before account     → just the date number, fully faded; the
///     creation                  step_logs row is absent so it reads as
///                              "no data".
///
/// Data: [recentStepLogsProvider] returns the last ~4 weeks of
/// `step_logs` rows as a `yyyy-MM-dd → row` map. The strip uses it to
/// know which past days had recorded activity (kept available for a
/// future "dot under date if you logged steps" affordance — currently
/// we don't paint a marker; the Day Summary screen makes the data
/// difference visible on tap).
class StreakStrip extends ConsumerStatefulWidget {
  const StreakStrip({super.key});

  @override
  ConsumerState<StreakStrip> createState() => _StreakStripState();
}

class _StreakStripState extends ConsumerState<StreakStrip>
    with SingleTickerProviderStateMixin {
  /// 4 weeks loaded: index 0 = 3 weeks back; index 3 = current week.
  static const _weekCount = 4;

  late final PageController _pageController;
  int _page = _weekCount - 1;

  /// After 3 s of no page changes on a non-current week, we slide
  /// the view back to the current week so the user doesn't get
  /// stranded on a past week and confused when reopening the app.
  static const _idleReturn = Duration(seconds: 3);
  Timer? _returnTimer;

  // ---------------------------------------------------------------------------
  // Real-time tick-up animation (Case A/B/C from the streak spec).
  //
  // When advance_daily_progress lands, StreakCelebrationBus emits a
  // (before, after) pair. We drive a 900 ms scale + count-up so the
  // flame throbs and the "N Days" caption walks from before → after.
  // ---------------------------------------------------------------------------
  late final AnimationController _tickController;
  StreamSubscription<StreakCelebration>? _celebrationSub;
  int? _fromStreak;
  int? _toStreak;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _page);
    _tickController = AnimationController(
      vsync: this,
      // xslow (620ms) gives the elastic wobble in Motion.springBounce
      // room to settle without dragging out the celebration.
      duration: Motion.d.xslow,
    );
    // subscribe() replays the last event if it happened within the
    // bus's replay window — covers the "user switched tabs while the
    // RPC was in-flight, celebration fires on remount" case.
    _celebrationSub = StreakCelebrationBus.instance.subscribe((event) {
      if (!mounted) return;
      if (event.streakAfter <= event.streakBefore) return;
      setState(() {
        _fromStreak = event.streakBefore;
        _toStreak = event.streakAfter;
      });
      _tickController.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _returnTimer?.cancel();
    _celebrationSub?.cancel();
    _tickController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  /// Called from the PageView's onPageChanged. Resets the idle
  /// timer; when it fires and we're still off the current week,
  /// animate the strip back to it.
  void _scheduleReturnIfNeeded() {
    _returnTimer?.cancel();
    if (_page == _weekCount - 1) return; // already on current
    _returnTimer = Timer(_idleReturn, () {
      if (!mounted) return;
      if (_page == _weekCount - 1) return;
      _pageController.animateToPage(
        _weekCount - 1,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
    });
  }

  /// Monday (local midnight) of the week whose page-index is [weekIdx].
  /// `weekIdx = _weekCount - 1` is the current week.
  DateTime _mondayFor(int weekIdx) {
    final now = DateTime.now();
    final mondayThisWeek =
        DateTime(now.year, now.month, now.day).subtract(
      Duration(days: now.weekday - 1),
    );
    final weeksBack = (_weekCount - 1) - weekIdx;
    return mondayThisWeek.subtract(Duration(days: weeksBack * 7));
  }

  @override
  Widget build(BuildContext context) {
    // `select` narrows the subscription to just the two fields we
    // care about (streak count + recovery state) so the strip only
    // rebuilds on streak-relevant ticks. `Object?`-typed record so
    // `.select` can compare with default equality.
    final streakState = ref.watch(userProfileProvider.select((async) {
      final p = async.valueOrNull;
      return (
        p?.currentStreak ?? 0,
        p?.isInStreakRecovery ?? false,
      );
    }));
    final streakDays = streakState.$1;
    final inRecovery = streakState.$2;
    // 'Dormant' visual state — grey flame + grey caption instead of
    // the celebratory orange. Fires when the user is either in the
    // recovery window (streak broken, grace period active) OR has
    // never started / just reset to 0. A 0-day streak in bright
    // orange reads as "you're on fire!" which is dishonest — nothing
    // to celebrate yet. Grey communicates "start today to light it
    // up" without the awkward mismatch. Added in 1.1.6+29 per user
    // feedback that "For 0 streak we should have in grey."
    final dormant = inRecovery || streakDays == 0;
    // Today-mission-done signal for the grey-flame tooltip copy —
    // "hit your step goal" reads wrong if the goal is already met.
    final dailyGoal = ref.watch(userProfileProvider.select(
      (async) => async.valueOrNull?.dailyStepGoal ?? 8000,
    ));
    final todaySteps = ref.watch(todayStepsProvider);
    final todayMissionDone = todaySteps >= dailyGoal;
    final logsAsync = ref.watch(recentStepLogsProvider);
    final logs =
        logsAsync.valueOrNull ?? const <String, StepLogModel>{};

    // Pull surface colours from Theme so this widget is subscribed to
    // the InheritedWidget — the strip otherwise reads a stale
    // background after a light/dark toggle until the next touch.
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.4),
          width: 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Row-by-row layout, sharing the SAME `Row` between the left
          // and right groups so the "X Days" caption baselines exactly
          // with the date numbers (they sit in one shared Row centered
          // vertically). The previous spaceBetween layout pushed the
          // caption all the way to the bottom of the column, slightly
          // below the date row's text centre.
          //
          //   Row 1 (top-align):
          //     [   flame   ] | M  T  W  T  F  S  S
          //
          //   Row 2 (centre-align — caption and dates share centre):
          //     [  X Days  ] | 22 23 24 25 26 27 28
          //
          // Inter-row gap is tight (6 px) so the visible space between
          // the flame and the caption is small — the flame's tail
          // extends most of the way down to the caption.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 64,
                // Restored to 64x64 so the parent Row's cross-axis
                // sizing (and thus the weekday labels' alignment with
                // the flame tip) stays where it always was. Extra
                // "sky" for the rising sparks comes from an
                // overflowing Positioned INSIDE the Stack — the
                // paint area extends 24dp ABOVE the SizedBox via
                // clipBehavior.none, but layout stays 64x64.
                height: 64,
                child: Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    // Fire embers rising FROM the flame INTO the air.
                    // Paint area extends 24dp above the SizedBox so
                    // particles have visible sky to travel through
                    // after emerging from the icon top. Colour tracks
                    // the flame — orange when active, grey when in
                    // recovery. Only on Home; profile stats strip
                    // renders the icon without particles.
                    Positioned(
                      top: -24,
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        child: FireParticles(
                          colour: (dormant
                                  ? AppColors.streakGrey
                                  : AppColors.streakActive)
                              .withValues(alpha: 0.9),
                        ),
                      ),
                    ),
                    StreakGreyTooltip(
                      // Tap only does something when the flame is grey
                      // (recovery mode) — the coloured flame stays
                      // non-interactive on Home.
                      enabled: inRecovery,
                      inRecovery: inRecovery,
                      todayMissionDone: todayMissionDone,
                      child: AnimatedBuilder(
                        animation: _tickController,
                        builder: (_, __) {
                          // Spring bounce with elastic settle — see
                          // Motion.springBounce docs.
                          final bounce =
                              Motion.springBounce(_tickController.value);
                          return Transform.scale(
                            scale: bounce,
                            child: Icon(
                              Icons.local_fire_department,
                              color: dormant
                                  ? AppColors.streakGrey
                                  : AppColors.streakActive,
                              size: 48,
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              // Weekday labels sit a few pixels lower so they aren't
              // pinned to the very top edge alongside the flame's
              // pointy tip — the offset matches what the user wanted
              // visually ("bring week days little down").
              const Expanded(
                child: Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: _WeekdayLabelsRow(),
                ),
              ),
            ],
          ),
          // No gap between rows: the bigger flame's tail extends into
          // Row 2's vertical zone, so an explicit SizedBox here would
          // re-introduce the spacing the user wanted to collapse.
          const SizedBox(height: 0),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 64,
                child: Center(
                  child: AnimatedBuilder(
                    animation: _tickController,
                    builder: (_, __) {
                      // Count-up in progress? Interpolate from
                      // _fromStreak to _toStreak. Otherwise render
                      // the live streak from the profile stream.
                      final anim = _tickController.value;
                      int displayDays;
                      if (_fromStreak != null &&
                          _toStreak != null &&
                          anim < 1.0) {
                        final range = _toStreak! - _fromStreak!;
                        displayDays = _fromStreak! + (range * anim).round();
                      } else {
                        displayDays = streakDays;
                      }
                      return _StreakCaption(
                        days: displayDays,
                        accent:
                            dormant ? AppColors.streakGrey : AppColors.streakActive,
                      );
                    },
                  ),
                ),
              ),
              Expanded(
                child: SizedBox(
                  height: 30,
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: _weekCount,
                    physics: const BouncingScrollPhysics(),
                    onPageChanged: (i) {
                      setState(() => _page = i);
                      _scheduleReturnIfNeeded();
                    },
                    itemBuilder: (_, weekIdx) {
                      return _WeekRow(
                        mondayDate: _mondayFor(weekIdx),
                        logs: logs,
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _PageDots(count: _weekCount, active: _page),
        ],
      ),
    );
  }
}

// =============================================================================
// Streak caption — sits in the bottom-left Table cell, vertically
// aligned with the date number row. Inline "N Days" pair so the
// caption reads as one breath.
// =============================================================================

class _StreakCaption extends StatelessWidget {
  final int days;
  final Color accent;
  const _StreakCaption({required this.days, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          '$days',
          style: TextStyle(
            fontFamily: 'Manrope',
            fontSize: 16,
            fontWeight: FontWeight.w900,
            color: AppColors.onSurface,
            height: 1,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          'Days',
          style: TextStyle(
            fontFamily: 'Manrope',
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.4,
            color: accent,
            height: 1,
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Weekday-label row (static — sits above the swipeable week PageView)
// =============================================================================

class _WeekdayLabelsRow extends StatelessWidget {
  const _WeekdayLabelsRow();

  static const _labels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final l in _labels)
          Expanded(
            child: Center(
              child: Text(
                l,
                style: TextStyle(
                  fontFamily: 'Manrope',
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.onSurfaceVariant,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// =============================================================================
// One week's row of 7 day cells
// =============================================================================

class _WeekRow extends StatelessWidget {
  final DateTime mondayDate;
  final Map<String, StepLogModel> logs;
  const _WeekRow({required this.mondayDate, required this.logs});

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final todayMidnight = DateTime(today.year, today.month, today.day);

    return Row(
      children: [
        for (int i = 0; i < 7; i++)
          Expanded(
            child: _DayCell(
              date: mondayDate.add(Duration(days: i)),
              today: todayMidnight,
              logs: logs,
            ),
          ),
      ],
    );
  }
}

// =============================================================================
// One day cell
// =============================================================================

class _DayCell extends StatelessWidget {
  final DateTime date;
  final DateTime today;
  final Map<String, StepLogModel> logs;
  const _DayCell({
    required this.date,
    required this.today,
    required this.logs,
  });

  @override
  Widget build(BuildContext context) {
    final isToday = date.year == today.year &&
        date.month == today.month &&
        date.day == today.day;
    final isFuture = date.isAfter(today);
    final dateKey = DateFormat('yyyy-MM-dd').format(date);
    final hasData = logs.containsKey(dateKey);

    final cell = isToday
        ? _todayCircle()
        : _dateCircle(
            day: date.day,
            faded: isFuture,
            hasData: hasData,
          );

    if (isToday || isFuture) {
      return Center(child: cell);
    }

    // Past day — tap opens Day Summary for that date.
    return Center(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => context.push('/day-summary/$dateKey'),
        child: cell,
      ),
    );
  }

  Widget _todayCircle() {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: AppColors.primary,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.35),
            blurRadius: 8,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Icon(
        // The StepBattle brand mark in the bottom-nav uses
        // Icons.sports_score; for "today" inside the streak strip we
        // use the running figure to match the activity context.
        Icons.directions_run,
        size: 18,
        color: AppColors.onPrimary,
      ),
    );
  }

  /// Past and future day cells are bare text — no rings or borders.
  /// Today is the only emphasised cell (filled violet circle with the
  /// running-figure icon). [hasData] is plumbed through for a future
  /// "subtle dot beneath active days" affordance but currently unused
  /// at the user's request: a clean strip.
  Widget _dateCircle({
    required int day,
    required bool faded,
    required bool hasData,
  }) {
    return SizedBox(
      width: 32,
      height: 32,
      child: Center(
        child: Text(
          '$day',
          style: TextStyle(
            fontFamily: 'Manrope',
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: faded
                ? AppColors.onSurfaceVariant.withValues(alpha: 0.3)
                : AppColors.onSurface,
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Page dots
// =============================================================================

class _PageDots extends StatelessWidget {
  final int count;
  final int active;
  const _PageDots({required this.count, required this.active});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (int i = 0; i < count; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: i == active ? 14 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: i == active
                    ? AppColors.primary
                    : AppColors.outlineVariant.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
      ],
    );
  }
}
