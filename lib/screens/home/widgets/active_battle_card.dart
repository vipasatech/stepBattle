import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../config/colors.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/battle_provider.dart';
import '../../../widgets/swipeable_card_stack.dart';
import '../../battles/widgets/battle_card.dart';

/// Home tab's active-battle section — reuses the SAME `BattleCard`
/// widget the Battles tab renders so the two surfaces stay identical.
/// When the user has multiple active battles, they're rendered as a
/// stacked deck with the top card fully visible and the ones behind
/// peeking at ~8dp increments (up to 3 shown; overflow shown as
/// "+N more in Battles"). Empty state collapses entirely.
class ActiveBattleCard extends ConsumerWidget {
  const ActiveBattleCard({super.key});

  /// Max cards rendered in the stack. Anything beyond becomes a
  /// "+N more" hint below.
  static const _maxStackDepth = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final all = ref.watch(activeBattlesProvider);
    if (all.isEmpty) return const SizedBox.shrink();

    final uid = ref.watch(authStateProvider).valueOrNull?.id ?? '';
    final theme = Theme.of(context);

    final visible = all.take(_maxStackDepth).toList();
    final overflow = all.length - visible.length;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Text(
                  all.length > 1 ? 'Active Battles' : 'Active Battle',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (all.length > 1) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${all.length}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          _StackedActiveCards(battles: visible, currentUserId: uid),
          if (overflow > 0) ...[
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => context.push('/battles'),
              child: Text(
                '+$overflow more in Battles →',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Swipeable stack of BattleCards. Front card is fully interactive
/// (tap → arena). A horizontal swipe on the front card slides it off
/// and promotes the next; the swiped card cycles to the back so
/// users can review the deck. Reuses the shared SwipeableCardStack
/// widget (also used by the highlighted missions section on Home).
class _StackedActiveCards extends StatelessWidget {
  final List<dynamic> battles;
  final String currentUserId;

  const _StackedActiveCards({
    required this.battles,
    required this.currentUserId,
  });

  @override
  Widget build(BuildContext context) {
    if (battles.length == 1) {
      // Single card — no swipe chrome, just render.
      final b = battles.first;
      return BattleCard(
        battle: b,
        currentUserId: currentUserId,
        onTap: () => context.push('/battle-ground/${b.battleId}'),
      );
    }

    return SwipeableCardStack(
      onTap: (topIndex) =>
          context.push('/battle-ground/${battles[topIndex].battleId}'),
      children: [
        for (final b in battles)
          BattleCard(
            battle: b,
            currentUserId: currentUserId,
            // Front-card tap is handled by SwipeableCardStack's onTap
            // above so drags don't consume the tap gesture. Back
            // cards ignore pointers via the stack widget itself.
          ),
      ],
    );
  }
}
