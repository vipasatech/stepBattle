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
    final uid = ref.watch(authStateProvider).valueOrNull?.id ?? '';

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
          LiveBattleCard(
            battleId: activeBattle.battleId,
            opponentName:
                activeBattle.opponentFor(uid)?.friendlyName ?? 'Opponent',
            yourSteps:
                activeBattle.participantFor(uid)?.currentSteps ?? 0,
            opponentSteps:
                activeBattle.opponentFor(uid)?.currentSteps ?? 0,
            timeLeft: activeBattle.timeRemainingLabel,
          )
        else if (lastCompleted != null)
          // State B: Last completed
          CompletedBattleCard(
            opponentName:
                lastCompleted.opponentFor(uid)?.friendlyName ?? 'Opponent',
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

/// Live battle card — shows "You vs {opponent}", the current step
/// delta, remaining time, and optionally an "Enter the Arena" button.
///
/// Home renders it with the button visible so the user can jump into
/// the arena for a battle running RIGHT NOW. Day Summary reuses the
/// same widget to render historical battles that were live on that
/// past date — but passes `showEnterButton: false` because navigating
/// into a mid-battle arena from a past-day summary doesn't make sense.
class LiveBattleCard extends StatelessWidget {
  final String battleId;
  final String opponentName;
  final int yourSteps;
  final int opponentSteps;
  final String timeLeft;

  /// Show the "Enter the Arena" button. Defaults to true (Home usage);
  /// callers surfacing this card in a read-only context (Day Summary)
  /// pass false.
  final bool showEnterButton;

  const LiveBattleCard({
    super.key,
    required this.battleId,
    required this.opponentName,
    required this.yourSteps,
    required this.opponentSteps,
    required this.timeLeft,
    this.showEnterButton = true,
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Title takes whatever space is left; ellipsis on overflow
              // so long opponent names don't push the time-left chip
              // off-screen at large text scales.
              Expanded(
                child: Text(
                  'You vs $opponentName',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 8),
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
          if (showEnterButton) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => context.push('/battle-ground/$battleId'),
                icon: const Icon(Icons.stadium, size: 18),
                label: const Text('Enter the Arena'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Completed battle card — "Last Battle · vs {opponent}" + won/lost
/// caption. Same visual for Home's "State B" and Day Summary's past
/// completed battles.
class CompletedBattleCard extends StatelessWidget {
  final String opponentName;
  final bool won;
  final int xpEarned;

  const CompletedBattleCard({
    super.key,
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
