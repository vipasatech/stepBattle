import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../config/colors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/battle_provider.dart';
import '../../sheets/new_battle_selection_sheet.dart';
import '../../widgets/empty_state.dart';
import 'widgets/battle_card.dart';

class BattlesScreen extends ConsumerWidget {
  const BattlesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Battles',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: AppColors.primaryBrand,
                fontWeight: FontWeight.w900,
              ),
        ),
        actions: [
          FilledButton.icon(
            onPressed: () => _showNewBattleSheet(context),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New Battle'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              textStyle: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: const _BattlesBody(),
    );
  }

  void _showNewBattleSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const NewBattleSelectionSheet(),
    );
  }
}

class _BattlesBody extends ConsumerWidget {
  const _BattlesBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allBattles = ref.watch(allBattlesProvider);
    final uid = ref.watch(authStateProvider).valueOrNull?.uid ?? '';

    return allBattles.when(
      loading: () => const Center(
          child: CircularProgressIndicator(color: AppColors.primary)),
      error: (e, _) => Center(child: Text('Error loading battles: $e')),
      data: (_) {
        final active = ref.watch(activeBattlesProvider);
        final scheduled = ref.watch(scheduledBattlesProvider);
        final completed = ref.watch(completedBattlesProvider);

        if (active.isEmpty && scheduled.isEmpty && completed.isEmpty) {
          return EmptyState(
            icon: Icons.bolt,
            title: 'No battles yet',
            subtitle: 'Challenge a friend to a step battle!',
            ctaLabel: '⚔️  Start a Battle',
            onCtaTap: () => _showNewBattle(context),
          );
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
          children: [
            // Section 1: Active
            if (active.isNotEmpty) ...[
              _SectionHeader(title: 'Active Battles', count: active.length),
              const SizedBox(height: 12),
              ...active.map((b) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: BattleCard(
                        battle: b, currentUserId: uid),
                  )),
              const SizedBox(height: 24),
            ],

            // Section 2: Scheduled
            if (scheduled.isNotEmpty) ...[
              _SectionHeader(
                  title: 'Scheduled Battles', count: scheduled.length),
              const SizedBox(height: 12),
              ...scheduled.map((b) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: BattleCard(
                        battle: b, currentUserId: uid),
                  )),
              const SizedBox(height: 24),
            ],

            // Section 3: Completed
            if (completed.isNotEmpty) ...[
              _SectionHeader(
                  title: 'Completed', count: completed.length),
              const SizedBox(height: 12),
              ...completed.map((b) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: BattleCard(
                        battle: b, currentUserId: uid),
                  )),
            ],
          ],
        );
      },
    );
  }

  void _showNewBattle(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const NewBattleSelectionSheet(),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;

  const _SectionHeader({required this.title, required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        Icon(Icons.chevron_right, color: AppColors.primary, size: 24),
      ],
    );
  }
}
