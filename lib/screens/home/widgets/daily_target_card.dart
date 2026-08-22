import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../config/colors.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/mission_provider.dart';
import '../../../providers/step_provider.dart';
import '../../../services/goal_formula.dart';
import '../../../services/streak_celebration_bus.dart';
import '../../../sheets/set_goal_sheet.dart';
import '../../../widgets/premium_card.dart';

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
///
/// Also owns the client-side trigger that credits the daily-mission +100
/// XP the moment today's step count crosses the goal. Fires exactly
/// once per widget lifetime (`_creditFired`); server-side
/// `credit_daily_mission_if_due` (migration 0044) is idempotent per
/// UTC day, so even if this widget re-mounts multiple times the ledger
/// only gets one row per user per day.
class DailyTargetCard extends ConsumerStatefulWidget {
  const DailyTargetCard({super.key});

  @override
  ConsumerState<DailyTargetCard> createState() => _DailyTargetCardState();
}

class _DailyTargetCardState extends ConsumerState<DailyTargetCard> {
  bool _creditFired = false;
  bool _creditInFlight = false;

  Future<void> _maybeCreditNow(int steps, int goal) async {
    if (_creditFired || _creditInFlight) return;
    if (goal <= 0 || steps < goal) return;
    final uid = ref.read(currentUserProvider).valueOrNull?.userId;
    if (uid == null) return;
    // _creditInFlight (not _creditFired) blocks concurrent tries in the
    // same session. On failure we leave _creditFired = false so the
    // next step-tick / rebuild retries; on success we set it true so
    // we don't re-fire for the rest of the session.
    _creditInFlight = true;
    final localDate = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final result = await ref.read(missionServiceProvider).advanceDailyProgress(
          userId: uid,
          localDate: localDate,
          currentSteps: steps,
        );
    _creditInFlight = false;
    if (result == null) return;   // RPC failed — leave the flag off so next tick retries
    _creditFired = true;
    if (!result.credited) return;
    // Emit through the celebration bus so any StreakStrip / profile
    // card listening can play the tick-up animation. profiles.total_xp
    // + current_streak stream via currentUserProvider, so the numeric
    // labels tick up on their own once the RPC returns.
    StreakCelebrationBus.instance.emit(
      streakBefore: result.streakBefore,
      streakAfter: result.streak,
      xpCredited: result.xpCredited,
      recovered: result.recovered,
      milestone: result.milestone,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // `select` — this card only reads the goal, so we skip rebuilds
    // when other profile fields (streak, XP, level) tick.
    final goal = ref.watch(currentUserProvider.select((async) =>
            async.valueOrNull?.dailyStepGoal)) ??
        GoalFormula.fallback.target;
    final steps = ref.watch(localTodayStepsProvider).valueOrNull ?? 0;
    final progress = (steps / goal).clamp(0.0, 1.0);
    final reached = steps >= goal;
    final remaining = (goal - steps).clamp(0, goal);
    final km = GoalFormula.stepsToKm(steps).toStringAsFixed(1);
    final goalKm = GoalFormula.stepsToKm(goal).toStringAsFixed(1);

    // Fire the immediate-credit RPC exactly once per session, either
    // on the first build where the goal is already met (cold-open
    // after crossing it earlier) or on the build where the step
    // count first crosses (mid-session crossing).
    if (reached) _maybeCreditNow(steps, goal);

    // Whole card is the tap target — removed the small Edit chip
    // (tester feedback: easy to miss). Chevron in the top-right hints
    // that the card is actionable.
    return PremiumCard(
      padding: EdgeInsets.zero,
      borderRadius: 20,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _openEditGoalSheet(context, goal),
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
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
                        color: reached
                            ? AppColors.success
                            : AppColors.primary,
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
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      color: AppColors.onSurfaceVariant,
                      size: 22,
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
                        color:
                            reached ? AppColors.success : AppColors.primary,
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
          ),
        ),
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
