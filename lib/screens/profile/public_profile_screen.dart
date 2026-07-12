import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config/colors.dart';
import '../../models/avatar.dart';
import '../../models/user_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/battle_provider.dart';
import '../../services/leaderboard_service.dart';
import '../../widgets/avatar_circle.dart';
import '../../widgets/glass_card.dart';

/// Read-only view of another user's profile. Reached from the arena
/// (tap an opponent's avatar) or from leaderboards / friends list.
///
/// Shows the same identity + stats block as the user's own Profile tab
/// but strips all edit affordances:
///   • No "edit display name" button
///   • No goal / home / battle-avatar tiles
///   • No "Sign out" button
///
/// Data shown is intentionally a subset — only what RLS lets any
/// signed-in user read (display_name, avatar_url, level, total_xp,
/// streak, battle_avatar_id). DOB / gender / fitness_level / email
/// are kept private even on a friend's profile.
///
/// Avatars on the arena route here on tap via /users/:userId.
class PublicProfileScreen extends ConsumerWidget {
  final String userId;
  const PublicProfileScreen({super.key, required this.userId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncUser = ref.watch(otherUserProvider(userId));
    final asyncRank = ref.watch(otherUserRankProvider(userId));
    final asyncStats = ref.watch(battleWinStatsProvider(userId));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text('Profile'),
      ),
      body: asyncUser.when(
        loading: () => Center(
          child: CircularProgressIndicator(color: AppColors.primary),
        ),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Could not load profile: $e',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.onSurfaceVariant),
            ),
          ),
        ),
        data: (user) {
          if (user == null) {
            return const Center(child: Text('User not found.'));
          }
          final rank = asyncRank.valueOrNull?.rank ?? 0;
          final stats = asyncStats.valueOrNull;
          final ratio = stats == null ? null : battleWinRatioOf(stats);
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            children: [
              _PublicIdentity(user: user, rank: rank, ratio: ratio),
              const SizedBox(height: 24),
              _PublicStats(user: user, stats: stats),
            ],
          );
        },
      ),
    );
  }
}

// =============================================================================
// Top identity block — avatar + name + stat chips
// =============================================================================

class _PublicIdentity extends StatelessWidget {
  final UserModel user;
  final int rank;
  final double? ratio;
  const _PublicIdentity({
    required this.user,
    required this.rank,
    required this.ratio,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [AppColors.primary, AppColors.tertiary],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: AvatarCircle(
                imageUrl: user.avatarURL,
                initials: _initials(user.friendlyName),
                radius: 44,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          user.friendlyName.isEmpty ? '—' : user.friendlyName,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        if (user.userCode.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            '@${user.userCode}',
            style: theme.textTheme.labelMedium?.copyWith(
              color: AppColors.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            _StatChip(label: 'Level ${user.level}', color: AppColors.primary),
            _StatChip(label: '${user.totalXP} XP', color: AppColors.tertiary),
            _StatChip(
              label: '${user.currentStreak} Day Streak',
              color: AppColors.primary,
            ),
            _StatChip(
              label: rank > 0 ? 'Rank #$rank' : 'Rank --',
              color: AppColors.secondary,
            ),
            _StatChip(
              label: ratio == null
                  ? 'B/W Ratio --'
                  : 'B/W ${(ratio! * 100).toStringAsFixed(0)}%',
              color: AppColors.amber,
            ),
          ],
        ),
      ],
    );
  }
}

// =============================================================================
// Stats card (all-time + battle)
// =============================================================================

class _PublicStats extends StatelessWidget {
  final UserModel user;
  final BattleWinStats? stats;
  const _PublicStats({required this.user, required this.stats});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      borderRadius: 18,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('ALL-TIME',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w800,
              )),
          const SizedBox(height: 14),
          _statRow(
            theme,
            icon: Icons.directions_walk,
            label: 'Total steps',
            value: _fmt(user.totalStepsAllTime),
          ),
          const SizedBox(height: 12),
          _statRow(
            theme,
            icon: Icons.local_fire_department,
            label: 'Longest streak',
            value: '${user.bestStreak} days',
          ),
          const SizedBox(height: 12),
          _statRow(
            theme,
            icon: Icons.shield_outlined,
            label: 'Battle avatar',
            value: Avatar.byId(user.battleAvatarId).label,
          ),
          if (stats != null) ...[
            const SizedBox(height: 12),
            _statRow(
              theme,
              icon: Icons.emoji_events,
              label: 'Battles won / played',
              value: '${stats!.wins} / ${stats!.total}',
            ),
          ],
        ],
      ),
    );
  }

  Widget _statRow(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppColors.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: AppColors.onSurfaceVariant),
          ),
        ),
        Text(
          value,
          style: theme.textTheme.bodyMedium
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
      ],
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

class _StatChip extends StatelessWidget {
  final String label;
  final Color color;
  const _StatChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

// =============================================================================
// Providers — fetch another user's profile + rank
// =============================================================================

/// Fetches another user's full profile row. Public-readable fields only —
/// RLS strips the rest server-side.
final otherUserProvider = FutureProvider.family<UserModel?, String>(
  (ref, userId) async {
    final svc = ref.read(authServiceProvider);
    return svc.getProfile(userId);
  },
);

/// Fetches another user's global leaderboard position. Returns null when
/// the user has no rank (e.g., just signed up, no XP yet).
final otherUserRankProvider =
    FutureProvider.family<({int rank, int totalXp})?, String>(
  (ref, userId) async {
    try {
      // Use LeaderboardService.getMyRank — it works for any user_id,
      // just named "my" because that's the most common caller.
      final entry = await LeaderboardService().getMyRank(userId);
      if (entry == null) return null;
      return (rank: entry.rank, totalXp: entry.totalXP);
    } catch (_) {
      return null;
    }
  },
);

/// Lightweight quick-stats bottom sheet shown when the user taps an
/// avatar in the battleground. Tap the card to navigate to the full
/// [PublicProfileScreen].
class ArenaProfilePeekSheet extends ConsumerWidget {
  final String userId;
  final VoidCallback onViewFullProfile;
  const ArenaProfilePeekSheet({
    super.key,
    required this.userId,
    required this.onViewFullProfile,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final asyncUser = ref.watch(otherUserProvider(userId));
    final asyncRank = ref.watch(otherUserRankProvider(userId));
    final asyncStats = ref.watch(battleWinStatsProvider(userId));

    return GestureDetector(
      // Whole sheet acts as a tap target to expand to the full profile.
      onTap: onViewFullProfile,
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppColors.onSurface.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              asyncUser.when(
                loading: () => Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: CircularProgressIndicator(
                      color: AppColors.primary),
                ),
                error: (e, _) => Text(
                  'Could not load: $e',
                  style: TextStyle(color: AppColors.onSurfaceVariant),
                ),
                data: (user) {
                  if (user == null) {
                    return const Text('User not found.');
                  }
                  final rank = asyncRank.valueOrNull?.rank ?? 0;
                  final stats = asyncStats.valueOrNull;
                  final ratio =
                      stats == null ? null : battleWinRatioOf(stats);

                  return Column(
                    children: [
                      AvatarCircle(
                        imageUrl: user.avatarURL,
                        initials: _initials(user.friendlyName),
                        radius: 32,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        user.friendlyName.isEmpty ? '—' : user.friendlyName,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (user.userCode.isNotEmpty)
                        Text(
                          '@${user.userCode}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: AppColors.onSurfaceVariant,
                          ),
                        ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        alignment: WrapAlignment.center,
                        children: [
                          _StatChip(
                            label: 'Lv ${user.level}',
                            color: AppColors.primary,
                          ),
                          _StatChip(
                            label: '${user.totalXP} XP',
                            color: AppColors.tertiary,
                          ),
                          _StatChip(
                            label: '${user.currentStreak}d Streak',
                            color: AppColors.primary,
                          ),
                          _StatChip(
                            label: rank > 0 ? '#$rank' : 'Rank --',
                            color: AppColors.secondary,
                          ),
                          _StatChip(
                            label: ratio == null
                                ? 'B/W --'
                                : 'B/W ${(ratio * 100).toStringAsFixed(0)}%',
                            color: AppColors.amber,
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'Tap to view full profile',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Convenience opener — shows the peek sheet; tap routes to the full
/// public profile screen at /users/:userId.
Future<void> showArenaProfilePeek(BuildContext context, String userId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useRootNavigator: true,
    builder: (ctx) => ArenaProfilePeekSheet(
      userId: userId,
      onViewFullProfile: () {
        Navigator.of(ctx).pop();
        // Push the full profile screen over the root navigator so it
        // sits above the battleground.
        Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute(
            builder: (_) => PublicProfileScreen(userId: userId),
          ),
        );
      },
    ),
  );
}

/// Best-effort 1-2 char initials for the avatar fallback when no
/// profile photo is set.
String _initials(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '?';
  final parts = trimmed.split(RegExp(r'\s+'));
  if (parts.length == 1) {
    return parts.first.substring(0, 1).toUpperCase();
  }
  return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
      .toUpperCase();
}

/// Throwaway — keeps `Supabase` import used in case downstream
/// providers reference it. Safe to delete if unused.
// ignore: unused_element
SupabaseClient _kUnused() => Supabase.instance.client;
