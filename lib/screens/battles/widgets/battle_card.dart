import 'package:flutter/material.dart';
import '../../../config/colors.dart';
import '../../../models/battle_model.dart';
import '../../../widgets/dual_fill_bar.dart';
import '../../../widgets/glass_card.dart';
import '../../../widgets/status_pill.dart';

/// Shared battle card used across active, scheduled, and completed sections.
class BattleCard extends StatelessWidget {
  final BattleModel battle;
  final String currentUserId;
  final VoidCallback? onTap;

  const BattleCard({
    super.key,
    required this.battle,
    required this.currentUserId,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return switch (battle.status) {
      BattleStatus.active => _ActiveCard(
          battle: battle, currentUserId: currentUserId, onTap: onTap),
      BattleStatus.pending => _ScheduledCard(battle: battle, onTap: onTap),
      BattleStatus.completed => _CompletedCard(
          battle: battle, currentUserId: currentUserId, onTap: onTap),
      BattleStatus.cancelled => const SizedBox.shrink(),
    };
  }
}

// =============================================================================
// Active battle card
// =============================================================================
class _ActiveCard extends StatelessWidget {
  final BattleModel battle;
  final String currentUserId;
  final VoidCallback? onTap;

  const _ActiveCard({
    required this.battle,
    required this.currentUserId,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final me = battle.participantFor(currentUserId);
    final opponent = battle.opponentFor(currentUserId);

    return GestureDetector(
      onTap: onTap,
      child: GlassCard(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: ID + Live pill
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'BATTLE ID ${battle.shortId}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.onSurfaceVariant,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '⚔️ You vs ${opponent?.displayName ?? "Opponent"}',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                const StatusPill(type: StatusType.live),
              ],
            ),
            const SizedBox(height: 20),

            // Step counts side by side
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('You',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: AppColors.onSurfaceVariant)),
                      Text(
                        _fmt(me?.currentSteps ?? 0),
                        style: theme.textTheme.headlineMedium?.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(opponent?.displayName ?? 'Opponent',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: AppColors.onSurfaceVariant)),
                      Text(
                        _fmt(opponent?.currentSteps ?? 0),
                        style: theme.textTheme.headlineMedium?.copyWith(
                          color: AppColors.amber,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Dual fill bar
            DualFillBar(
              yourSteps: me?.currentSteps ?? 0,
              opponentSteps: opponent?.currentSteps ?? 0,
            ),
            const SizedBox(height: 16),

            // Footer: time + XP
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.schedule,
                        size: 14, color: AppColors.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(battle.timeRemainingLabel,
                        style: theme.textTheme.bodySmall),
                  ],
                ),
                Text(
                  '+${battle.xpReward} XP on win',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: AppColors.tertiary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Scheduled (pending) battle card
// =============================================================================
class _ScheduledCard extends StatelessWidget {
  final BattleModel battle;
  final VoidCallback? onTap;

  const _ScheduledCard({required this.battle, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final opponent = battle.participants.length > 1
        ? battle.participants[1]
        : null;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: const Border(
            left: BorderSide(
                color: Color(0x80F59E0B), width: 4), // amber left accent
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '⚔️ You vs ${opponent?.displayName ?? "Waiting..."}',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.calendar_today,
                          size: 14, color: AppColors.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Text(
                        'Starts when accepted',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '+${battle.xpReward} XP on win',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.tertiary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const StatusPill(type: StatusType.pending),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Completed battle card
// =============================================================================
class _CompletedCard extends StatelessWidget {
  final BattleModel battle;
  final String currentUserId;
  final VoidCallback? onTap;

  const _CompletedCard({
    required this.battle,
    required this.currentUserId,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final me = battle.participantFor(currentUserId);
    final opponent = battle.opponentFor(currentUserId);
    final won = battle.winnerId == currentUserId;

    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: 0.8,
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLow.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '⚔️ You vs ${opponent?.displayName ?? "Opponent"}',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'You: ${_fmt(me?.currentSteps ?? 0)} · ${opponent?.displayName ?? "Opp"}: ${_fmt(opponent?.currentSteps ?? 0)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.primary,
                        ),
                      ),
                    ],
                  ),
                  StatusPill(
                      type: won ? StatusType.won : StatusType.lost),
                ],
              ),
              const SizedBox(height: 12),

              // Frozen progress bar
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: 1.0,
                  backgroundColor: AppColors.surfaceContainerHighest,
                  color: AppColors.primary.withValues(alpha: 0.4),
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 12),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Completed',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.onSurfaceVariant,
                      letterSpacing: 2,
                    ),
                  ),
                  Text(
                    won ? '+${battle.xpReward} XP EARNED' : '+0 XP',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: won ? AppColors.success : AppColors.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
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
