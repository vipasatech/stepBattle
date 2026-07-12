import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/colors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/battle_provider.dart';
import '../../widgets/empty_state.dart';
import 'widgets/battle_card.dart';

/// Full history of the user's completed battles.
///
/// The Battles tab caps its "Completed" section at 5 recent finishers
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
    final uid = ref.watch(authStateProvider).valueOrNull?.id ?? '';

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Completed battles'),
      ),
      body: completed.isEmpty
          ? const EmptyState(
              icon: Icons.emoji_events_outlined,
              title: 'No completed battles yet',
              subtitle:
                  'When you finish a battle it lands here for your history.',
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              itemCount: completed.length,
              itemBuilder: (_, i) {
                final b = completed[i];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: BattleCard(
                    battle: b,
                    currentUserId: uid,
                    onTap: () =>
                        context.push('/battle-status/${b.battleId}'),
                  ),
                );
              },
            ),
      backgroundColor: AppColors.background,
    );
  }
}
