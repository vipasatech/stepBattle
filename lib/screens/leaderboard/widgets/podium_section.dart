import 'package:flutter/material.dart';
import '../../../config/colors.dart';
import '../../../models/leaderboard_entry_model.dart';
import '../../../widgets/avatar_circle.dart';
import '../../../widgets/glass_card.dart';

/// Top 3 leaderboard display. All three ranks share the **clan member row**
/// layout (full-width GlassCard, avatar on the left with a rank badge, name +
/// medal pill in the middle, XP on the right) so the visual rhythm matches
/// the Clan tab. Rank 1 is differentiated only by a gold accent bar, brighter
/// avatar border, and slightly larger XP — same dimensions, same font sizes.
class PodiumSection extends StatelessWidget {
  final List<LeaderboardEntry> topThree;
  final void Function(LeaderboardEntry) onTap;

  const PodiumSection({super.key, required this.topThree, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (topThree.isEmpty) return const SizedBox();

    return Column(
      children: [
        for (var i = 0; i < topThree.length && i < 3; i++) ...[
          GestureDetector(
            onTap: () => onTap(topThree[i]),
            child: _RankRowCard(entry: topThree[i], rank: i + 1),
          ),
          if (i < topThree.length - 1 && i < 2) const SizedBox(height: 10),
        ],
      ],
    );
  }
}

/// One leaderboard row, styled to mirror the clan-tab member row exactly
/// (same `GlassCard`, same 14dp padding, same avatar size, same titleSmall
/// name with w600). Rank-specific accent (gold/silver/bronze) lives only on:
/// the avatar border, the rank-pill background, the side accent bar (rank 1
/// only), and the XP color. Everything else stays uniform.
class _RankRowCard extends StatelessWidget {
  final LeaderboardEntry entry;
  final int rank;

  const _RankRowCard({required this.entry, required this.rank});

  Color get _accent => switch (rank) {
        1 => AppColors.gold,
        2 => AppColors.silver,
        _ => AppColors.bronze,
      };

  String get _medalEmoji => switch (rank) {
        1 => '🥇',
        2 => '🥈',
        _ => '🥉',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isChampion = rank == 1;

    return GlassCard(
      padding: const EdgeInsets.all(14),
      borderRadius: 16,
      child: Row(
        children: [
          // Side accent bar for rank 1 only — same width/proportions as the
          // original gold bar so the championship row still feels heavier
          // without breaking the clan-row dimensions.
          if (isChampion) ...[
            Container(
              width: 4,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.gold,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 12),
          ],

          // Avatar with rank-number badge in the corner (parallels the
          // captain-star badge on the clan row).
          Stack(
            clipBehavior: Clip.none,
            children: [
              AvatarCircle(
                radius: 22,
                imageUrl: entry.avatarURL,
                initials: entry.displayName.isNotEmpty
                    ? entry.displayName[0].toUpperCase()
                    : '?',
                borderColor: _accent,
                borderWidth: 2,
              ),
              Positioned(
                bottom: -2,
                right: -2,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: _accent,
                    shape: BoxShape.circle,
                    boxShadow: isChampion
                        ? [
                            BoxShadow(
                              color: AppColors.gold.withValues(alpha: 0.5),
                              blurRadius: 6,
                            ),
                          ]
                        : null,
                  ),
                  child: Center(
                    child: Text(
                      '$rank',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        color: Colors.black,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 14),

          // Name + medal pill. Same dimensions/fonts as the clan card so
          // "Mogulagani Prashanth" renders in full instead of truncating.
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    entry.displayName,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                // Medal pill — parallels the "Captain"/"Soldier" pill on the
                // clan row. Emoji-only so the chip stays narrow at any rank.
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: _accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _medalEmoji,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),

          // XP — same column treatment as the clan row's "666 Steps" stack:
          // value on top in titleMedium + w700, label below.
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _fmt(entry.totalXP),
                style: theme.textTheme.titleMedium?.copyWith(
                  color: _accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                'XP',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.onSurfaceVariant,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ],
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
