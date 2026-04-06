import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../config/colors.dart';
import '../../models/leaderboard_entry_model.dart';
import '../../providers/leaderboard_provider.dart';
import '../../sheets/public_profile_sheet.dart';
import '../../widgets/empty_state.dart';
import 'widgets/podium_section.dart';
import 'widgets/rank_row.dart';
import 'widgets/floating_rank_card.dart';

class LeaderboardScreen extends ConsumerStatefulWidget {
  const LeaderboardScreen({super.key});

  @override
  ConsumerState<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends ConsumerState<LeaderboardScreen> {
  bool _showFriends = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final myRank = ref.watch(myRankProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'LEADERBOARD',
          style: theme.textTheme.headlineSmall?.copyWith(
            color: AppColors.onSurface,
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
          ),
        ),
        actions: [
          // Toggle pill
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: AppColors.outlineVariant.withValues(alpha: 0.2)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _TogglePill(
                  label: 'OVERALL',
                  isActive: !_showFriends,
                  onTap: () => setState(() => _showFriends = false),
                ),
                _TogglePill(
                  label: 'FRIENDS',
                  isActive: _showFriends,
                  onTap: () => setState(() => _showFriends = true),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Stack(
        children: [
          _showFriends ? const _FriendsBoard() : const _GlobalBoard(),

          // Floating rank card
          if (myRank != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 90,
              child: FloatingRankCard(entry: myRank),
            ),
        ],
      ),
    );
  }
}

class _TogglePill extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _TogglePill({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: isActive ? AppColors.primaryBrand : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: isActive ? Colors.white : AppColors.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
        ),
      ),
    );
  }
}

// =============================================================================
// Global leaderboard
// =============================================================================
class _GlobalBoard extends ConsumerWidget {
  const _GlobalBoard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final board = ref.watch(globalLeaderboardProvider);

    return board.when(
      loading: () => const Center(
          child: CircularProgressIndicator(color: AppColors.primary)),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (entries) {
        if (entries.isEmpty) {
          return const EmptyState(
            icon: Icons.leaderboard,
            title: 'No leaderboard data yet',
            subtitle: 'Start walking to earn XP and climb the ranks!',
          );
        }
        return _LeaderboardList(
          entries: entries,
        );
      },
    );
  }
}

// =============================================================================
// Friends leaderboard
// =============================================================================
class _FriendsBoard extends ConsumerWidget {
  const _FriendsBoard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final board = ref.watch(friendsLeaderboardProvider);

    return board.when(
      loading: () => const Center(
          child: CircularProgressIndicator(color: AppColors.primary)),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (entries) {
        if (entries.isEmpty) {
          return const EmptyState(
            icon: Icons.group,
            title: 'Invite friends to compare',
            subtitle: 'Add at least 3 friends to see your ranking among them.',
            ctaLabel: 'Invite Friends',
          );
        }
        return _LeaderboardList(entries: entries);
      },
    );
  }
}

// =============================================================================
// Shared list view
// =============================================================================
class _LeaderboardList extends StatelessWidget {
  final List<LeaderboardEntry> entries;

  const _LeaderboardList({required this.entries});

  @override
  Widget build(BuildContext context) {
    final topThree = entries.length >= 3
        ? entries.sublist(0, 3)
        : entries;
    final rest = entries.length > 3 ? entries.sublist(3) : <LeaderboardEntry>[];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 200),
      children: [
        PodiumSection(
          topThree: topThree,
          onTap: (entry) => _showProfile(context, entry),
        ),
        const SizedBox(height: 20),
        ...rest.map((entry) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: RankRow(
                entry: entry,
                onTap: () => _showProfile(context, entry),
              ),
            )),

        // Help link
        const SizedBox(height: 16),
        Center(
          child: TextButton.icon(
            onPressed: () {},
            icon: const Icon(Icons.help, size: 16),
            label: const Text('How to earn more XP'),
            style: TextButton.styleFrom(foregroundColor: AppColors.primary),
          ),
        ),
      ],
    );
  }

  void _showProfile(BuildContext context, LeaderboardEntry entry) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => PublicProfileSheet(entry: entry),
    );
  }
}
