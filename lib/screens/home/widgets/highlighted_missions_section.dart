import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../config/colors.dart';
import '../../../providers/mission_provider.dart';
import '../../../widgets/swipeable_card_stack.dart';
import 'highlighted_mission_card.dart';

/// Home-tab featured missions. Reads
/// [homeHighlightedMissionsProvider], newest-first.
///
///   • 0 entries → collapsed
///   • 1 entry  → single card (tap opens the mission-detail sheet)
///   • ≥2 entries → stacked deck (up to 3 shown, back cards peek behind
///     the front). Front card tap → navigates to the full Missions
///     page. A "+N more →" link surfaces overflow beyond 3.
///
/// The stack pattern mirrors `ActiveBattleCard` so users learn one
/// visual grammar for "there's more here".
class HighlightedMissionsSection extends ConsumerWidget {
  const HighlightedMissionsSection({super.key});

  static const _maxStackDepth = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(homeHighlightedMissionsProvider);
    if (entries.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final visible = entries.take(_maxStackDepth).toList();
    final overflow = entries.length - visible.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              Text(
                entries.length > 1 ? 'Featured Missions' : 'Featured Mission',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (entries.length > 1) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${entries.length}',
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
        _StackedMissionCards(entries: visible),
        if (overflow > 0) ...[
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () => context.push('/missions'),
            child: Text(
              '+$overflow more →',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Swipeable deck of mission cards. When there's only one, no swipe
/// chrome — just the card. Otherwise, the shared SwipeableCardStack
/// (also powering Active Battles on Home) handles gestures + peek.
class _StackedMissionCards extends StatelessWidget {
  final List<HomeMissionEntry> entries;
  const _StackedMissionCards({required this.entries});

  @override
  Widget build(BuildContext context) {
    if (entries.length == 1) {
      // Single mission — no deck, keep the direct tap → sheet flow.
      return HighlightedMissionCard(entry: entries.first);
    }

    return SwipeableCardStack(
      onTap: (_) => context.push('/missions'),
      children: [
        for (final e in entries)
          HighlightedMissionCard(
            entry: e,
            // Front-card tap routes to /missions via the stack's
            // onTap above so drags never race the card's own gesture.
            ignoreTap: true,
          ),
      ],
    );
  }
}
