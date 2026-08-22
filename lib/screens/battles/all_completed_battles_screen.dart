import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/colors.dart';
import '../../models/battle_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/battle_provider.dart';
import '../../widgets/empty_state.dart';
import 'widgets/battle_card.dart';
import 'widgets/battle_search_tab.dart';

/// Full history of the user's completed battles, split by format.
///
/// Tab layout (Batch A #8):
///   • 1v1
///   • Group battle
///   • Team
///
/// The Battles tab caps its "Completed" preview at 5 recent finishers
/// and shows a chevron on the section header — that chevron routes
/// here so the user can scroll the entire history without the tab
/// becoming a scroll marathon.
///
/// Data source is the same [completedBattlesProvider] the tab uses,
/// so the two views stay in sync automatically.
class AllCompletedBattlesScreen extends ConsumerWidget {
  const AllCompletedBattlesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final completed = ref.watch(completedBattlesProvider);
    // `.select` narrows the uid watch so auth-provider ticks (token
    // refresh, etc.) that don't change the user don't rebuild the
    // whole history list.
    final uid = ref.watch(
      authStateProvider.select((a) => a.valueOrNull?.id ?? ''),
    );

    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context),
          ),
          title: const Text('Completed battles'),
          bottom: TabBar(
            labelColor: AppColors.primary,
            unselectedLabelColor: AppColors.onSurfaceVariant,
            indicatorColor: AppColors.primary,
            // Format tabs first, search chip last — matches Discover's
            // ordering so users see the same "the search tab is the
            // magnifier on the right" convention everywhere.
            tabs: const [
              Tab(text: '1v1'),
              Tab(text: 'Multi'),
              Tab(text: 'Team'),
              Tab(icon: Icon(Icons.search, size: 18)),
            ],
          ),
        ),
        backgroundColor: AppColors.background,
        body: TabBarView(
          children: [
            _CompletedList(
              battles: completed
                  .where((b) => b.type == BattleType.oneVsOne)
                  .toList(),
              uid: uid,
              emptyTitle: 'No completed 1v1 battles yet',
            ),
            _CompletedList(
              battles: completed
                  .where((b) => b.type == BattleType.group)
                  .toList(),
              uid: uid,
              emptyTitle: 'No completed multi battles yet',
            ),
            _CompletedList(
              battles: completed
                  .where((b) => b.type == BattleType.team)
                  .toList(),
              uid: uid,
              emptyTitle: 'No completed team battles yet',
            ),
            // Search across ALL completed battles regardless of type.
            // Tap → battle-status route (same as tapping a card in a
            // format tab).
            BattleSearchTab(
              battles: completed,
              currentUserId: uid,
              scopeLabel: 'completed battles',
              onTap: (b) =>
                  context.push('/battle-status/${b.battleId}'),
            ),
          ],
        ),
      ),
    );
  }
}

/// One tab's completed-list body. Renders the shared [BattleCard]
/// layout with an empty-state fallback when the format has no history.
class _CompletedList extends StatelessWidget {
  final List<BattleModel> battles;
  final String uid;
  final String emptyTitle;

  const _CompletedList({
    required this.battles,
    required this.uid,
    required this.emptyTitle,
  });

  @override
  Widget build(BuildContext context) {
    if (battles.isEmpty) {
      return EmptyState(
        icon: Icons.emoji_events_outlined,
        title: emptyTitle,
        subtitle:
            'When you finish a battle of this format it lands here.',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      // Pre-inflate ~800 dp past the viewport so cards further down the
      // history stack are ready before they scroll into view. History
      // screens are the most likely place for the user to flick fast;
      // the default 250 dp meant the item that just came on-screen had
      // to build + paint in the same frame it appeared, occasionally
      // missing the frame budget.
      cacheExtent: 800,
      itemCount: battles.length,
      itemBuilder: (_, i) {
        final b = battles[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: BattleCard(
            battle: b,
            currentUserId: uid,
            onTap: () => context.push('/battle-status/${b.battleId}'),
          ),
        );
      },
    );
  }
}
