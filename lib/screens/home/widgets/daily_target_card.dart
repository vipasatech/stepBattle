import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config/colors.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/step_provider.dart';
import '../../../services/goal_formula.dart';
import '../../../sheets/set_goal_sheet.dart';
import '../../../widgets/glass_card.dart';

/// Home-tab daily target card — replaces the multi-mission list.
///
/// Renders the single personalized step target (one source of truth for
/// "did the user meet their mission today"), today's step progress against
/// it, a derived km figure, and a tap target that opens the edit-goal sheet.
///
/// Built on top of:
///   • `currentUserProvider.dailyStepGoal` for the target.
///   • `localTodayStepsProvider` for today's progress.
///   • `GoalFormula.stepsToKm` for the km derivation (cheap, no GPS).
///   • [SetGoalSheet] for the edit flow (clamped to the formula's
///     `[min, max]` range — see set_goal_sheet.dart).
class DailyTargetCard extends ConsumerWidget {
  const DailyTargetCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final user = ref.watch(currentUserProvider).valueOrNull;
    final steps = ref.watch(localTodayStepsProvider).valueOrNull ?? 0;

    final goal = user?.dailyStepGoal ?? GoalFormula.fallback.target;
    final progress = (steps / goal).clamp(0.0, 1.0);
    final reached = steps >= goal;
    final remaining = (goal - steps).clamp(0, goal);
    final km = GoalFormula.stepsToKm(steps).toStringAsFixed(1);
    final goalKm = GoalFormula.stepsToKm(goal).toStringAsFixed(1);

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      borderRadius: 20,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: reached
                      ? AppColors.success.withValues(alpha: 0.15)
                      : AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  reached
                      ? Icons.check_circle_outline
                      : Icons.directions_walk,
                  color: reached ? AppColors.success : AppColors.primary,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('TODAY\'S MISSION',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                          letterSpacing: 1.5,
                        )),
                    const SizedBox(height: 2),
                    Text(
                      reached
                          ? 'Goal reached — +100 XP earned'
                          : '${_fmt(remaining)} steps to go',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: () => _openEditGoalSheet(context, goal),
                icon: const Icon(Icons.tune, size: 16),
                label: const Text('Edit'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Step count + target row.
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                _fmt(steps),
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: reached ? AppColors.success : AppColors.primary,
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
              valueColor: AlwaysStoppedAnimation(
                reached ? AppColors.success : AppColors.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openEditGoalSheet(BuildContext context, int currentGoal) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SetGoalSheet(currentGoal: currentGoal),
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
