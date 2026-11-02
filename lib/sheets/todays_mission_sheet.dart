import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/colors.dart';
import '../features/onboarding_tour/tour_step.dart';
import '../features/onboarding_tour/tour_target.dart';
import '../providers/auth_provider.dart';
import '../providers/step_provider.dart';
import '../services/goal_formula.dart';
import '../widgets/bottom_sheet_handle.dart';
import 'set_goal_sheet.dart';

/// Modal bottom sheet that mirrors the Home tab's Today's Mission card.
///
/// **Why this exists** (2026-08-31): tapping the "daily mission" link
/// or "Open Today's Mission" CTA in the streak history sheet used to
/// open the generic [MissionDetailSheet] for the catalog's
/// `daily_streak` mission — but that mission's progress is stored as
/// a boolean-completion (0/1 or 1/1) rather than the actual step
/// count, so users saw "0/1" and 0% progress bar even when they had
/// 2,113 out of 2,500 steps done. The Home tab's
/// [DailyTargetCard] shows the real step-count progress via
/// [localTodayStepsProvider] + [currentUserProvider.dailyStepGoal] —
/// this sheet reuses that exact data source and layout so both
/// surfaces stay in sync.
///
/// **What's shown**:
///   • Flame hero icon (matches the streak sheet's family)
///   • Title + subtitle
///   • Step count `X / Y` and km derivation
///   • Violet progress bar
///   • XP reward chip (`+100 XP on completion`)
///   • Streak note (`Hits your streak on completion`)
///   • CTA to change the goal (reuses [SetGoalSheet])
///
/// Unlike the Home card, this is a MODAL — tapping the card body does
/// nothing; the Change Goal action lives in its own button. This keeps
/// the sheet a read-only summary + one explicit action.
class TodaysMissionSheet extends ConsumerWidget {
  const TodaysMissionSheet({super.key});

  /// Opens the sheet. `useRootNavigator` defaults true (matches
  /// existing call sites); the new-user tour passes `false` so the
  /// sheet renders inside the shell's local navigator and stays
  /// UNDER the shell-mounted OnboardingTourOverlay.
  ///
  /// `barrierColor` defaults to Material's ~32% black scrim; the tour
  /// passes `Colors.transparent` so its own 10% dim isn't layered on
  /// top of Flutter's default scrim (would read as "everything
  /// blurred" on tour steps).
  static Future<void> show(
    BuildContext context, {
    bool useRootNavigator = true,
    Color? barrierColor,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: useRootNavigator,
      backgroundColor: Colors.transparent,
      barrierColor: barrierColor,
      builder: (_) => const TodaysMissionSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Same data sources as the Home DailyTargetCard so both surfaces
    // show identical numbers frame-for-frame. `.select` on the goal
    // narrows the profile watch to just the one field so this sheet
    // doesn't rebuild on every step tick or XP award.
    final goal = ref.watch(currentUserProvider.select((async) =>
                async.valueOrNull?.dailyStepGoal)) ??
            GoalFormula.fallback.target;
    final steps = ref.watch(localTodayStepsProvider).valueOrNull ?? 0;

    final progress = (steps / goal).clamp(0.0, 1.0);
    final reached = steps >= goal;
    final remaining = (goal - steps).clamp(0, goal);
    final km = GoalFormula.stepsToKm(steps).toStringAsFixed(1);
    final goalKm = GoalFormula.stepsToKm(goal).toStringAsFixed(1);

    final accent = reached ? AppColors.success : AppColors.primary;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const BottomSheetHandle(),

              // Hero disc — the walking figure carries the mission
              // identity; the flame badge overlaid in the bottom-right
              // carries the streak identity (this mission extends the
              // streak on completion). Two-icon composite so the sheet
              // reads as "today's mission + streak" at a glance,
              // matching the streak flame the user tapped from the
              // profile / streak history to open this sheet.
              // 2026-09-04 fix — flame overlay added on user request.
              SizedBox(
                width: 84,
                height: 84,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Base disc — mission icon.
                    Positioned(
                      left: 0,
                      top: 0,
                      child: Container(
                        width: 68,
                        height: 68,
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          reached
                              ? Icons.check_circle_outline
                              : Icons.directions_walk,
                          color: accent,
                          size: 34,
                        ),
                      ),
                    ),
                    // Streak flame badge — orange when the mission
                    // still contributes to the streak (default), muted
                    // once already reached today so the badge doesn't
                    // over-shout on a completed mission.
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: AppColors.streakActive
                              .withValues(alpha: 0.18),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: AppColors.surfaceContainer,
                            width: 2,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.local_fire_department,
                          color: AppColors.streakActive,
                          size: 18,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              Text(
                "Today's Mission",
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                reached
                    ? 'Goal reached — +100 XP earned'
                    : '${_fmt(remaining)} steps to go',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 22),

              // Progress card — matches DailyTargetCard's number row +
              // bar exactly so users switching between surfaces see the
              // same shape/proportions.
              Container(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: scheme.onSurface.withValues(alpha: 0.05),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          _fmt(steps),
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: accent,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '/ ${_fmt(goal)}',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: AppColors.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '$km / $goalKm km',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: AppColors.onSurfaceVariant,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 10,
                        backgroundColor: AppColors.surfaceContainerHigh,
                        valueColor: AlwaysStoppedAnimation(accent),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // Reward + streak info — two subtle chips so users see
              // what completing this mission unlocks without needing
              // to open the streak sheet again.
              Row(
                children: [
                  Expanded(
                    child: _InfoChip(
                      icon: Icons.military_tech,
                      label: '+100 XP on complete',
                      color: AppColors.tertiary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _InfoChip(
                      icon: Icons.local_fire_department,
                      label: 'Extends your streak',
                      color: AppColors.streakActive,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Primary CTA — Change goal. Opens the same SetGoalSheet
              // the Home card's InkWell tap opens. TourTarget wraps
              // it so tour step 4 can spotlight this button.
              SizedBox(
                width: double.infinity,
                child: TourTarget(
                  id: TourTargetId.missionSheetChangeGoal,
                  child: FilledButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      useRootNavigator: true,
                      backgroundColor: Colors.transparent,
                      builder: (_) => SetGoalSheet(currentGoal: goal),
                    );
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    minimumSize: const Size.fromHeight(52),
                  ),
                  child: Text(
                    'Change goal',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  'Close',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmt(int n) {
    if (n == 0) return '0';
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _InfoChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
