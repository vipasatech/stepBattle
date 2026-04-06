import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../config/colors.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/battle_provider.dart';
import '../../../widgets/glass_card.dart';
import '../../../widgets/status_pill.dart';

/// Active battle section on Home — wired to real battle providers.
/// State A: active battle running → shows opponent + step delta
/// State B: no active, show last completed
/// State C: no battles → CTA "Start a Battle"
class ActiveBattleCard extends ConsumerWidget {
  const ActiveBattleCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeBattle = ref.watch(firstActiveBattleProvider);
    final lastCompleted = ref.watch(lastCompletedBattleProvider);
    final uid = ref.watch(authStateProvider).valueOrNull?.uid ?? '';

    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Active Battle',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700)),
            if (activeBattle != null)
              const StatusPill(type: StatusType.live),
          ],
        ),
        const SizedBox(height: 12),

        if (activeBattle != null)
          // State A: Active battle
          _ActiveState(
            opponentName:
                activeBattle.opponentFor(uid)?.displayName ?? 'Opponent',
            yourSteps:
                activeBattle.participantFor(uid)?.currentSteps ?? 0,
            opponentSteps:
                activeBattle.opponentFor(uid)?.currentSteps ?? 0,
            timeLeft: activeBattle.timeRemainingLabel,
          )
        else if (lastCompleted != null)
          // State B: Last completed
          _CompletedState(
            opponentName:
                lastCompleted.opponentFor(uid)?.displayName ?? 'Opponent',
            won: lastCompleted.winnerId == uid,
            xpEarned:
                lastCompleted.winnerId == uid ? lastCompleted.xpReward : 0,
          )
        else
          // State C: No battles
          _NoBattlesState(),
      ],
    );
  }
}

class _ActiveState extends StatelessWidget {
  final String opponentName;
  final int yourSteps;
  final int opponentSteps;
  final String timeLeft;

  const _ActiveState({
    required this.opponentName,
    required this.yourSteps,
    required this.opponentSteps,
    required this.timeLeft,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLeading = yourSteps >= opponentSteps;
    final delta = (yourSteps - opponentSteps).abs();

    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('You vs $opponentName',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
              Text(timeLeft, style: theme.textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            isLeading
                ? "You're leading by ${_fmt(delta)} steps"
                : "You're behind by ${_fmt(delta)} steps",
            style: theme.textTheme.bodySmall?.copyWith(
              color: isLeading ? AppColors.primary : AppColors.amber,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => context.go('/battles'),
              style: OutlinedButton.styleFrom(
                side: BorderSide(
                    color: AppColors.primary.withValues(alpha: 0.4)),
              ),
              child: const Text('View Arena'),
            ),
          ),
        ],
      ),
    );
  }
}

class _CompletedState extends StatelessWidget {
  final String opponentName;
  final bool won;
  final int xpEarned;

  const _CompletedState({
    required this.opponentName,
    required this.won,
    required this.xpEarned,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Last Battle · vs $opponentName',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            won ? 'You won · +$xpEarned XP' : 'You lost',
            style: theme.textTheme.bodySmall?.copyWith(
              color: won ? AppColors.success : AppColors.error,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _NoBattlesState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
      child: Center(
        child: Column(
          children: [
            Text('⚔️', style: theme.textTheme.displaySmall),
            const SizedBox(height: 12),
            Text('Start a Battle',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('Challenge a friend to a step battle',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.onSurfaceVariant)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => context.go('/battles'),
              child: const Text('⚔️  Start a Battle'),
            ),
          ],
        ),
      ),
    );
  }
}

String _fmt(int n) {
  if (n == 0) return '0';
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}
