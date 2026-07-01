import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../config/colors.dart';
import '../../../models/step_log_model.dart';
import '../../../providers/streak_provider.dart';
import '../../../providers/user_provider.dart';

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

class _StreakStripState extends ConsumerState<StreakStrip> {
  /// 4 weeks loaded: index 0 = 3 weeks back; index 3 = current week.
  static const _weekCount = 4;

  /// Deep orange — the streak signal colour. Kept theme-invariant per
  /// user request so the flame reads the same on both dark and light
  /// surfaces. Matches `AppColors.lightAmber` (#D97706).
  static const _streakOrange = Color(0xFFD97706);
  late final PageController _pageController;
  int _page = _weekCount - 1;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _page);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
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
    final streakDays =
        ref.watch(userProfileProvider).valueOrNull?.currentStreak ?? 0;
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
                child: Center(
                  child: Icon(
                    Icons.local_fire_department,
                    color: _streakOrange,
                    size: 48,
                  ),
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
                  child: _StreakCaption(
                    days: streakDays,
                    accent: _streakOrange,
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
                    onPageChanged: (i) => setState(() => _page = i),
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
