import 'package:flutter/material.dart';
import '../../../config/colors.dart';
import '../../../models/leaderboard_entry_model.dart';
import '../../../widgets/avatar_circle.dart';

/// Top 3 leaderboard display — rank 1 full-width gold, ranks 2-3 side by side.
class PodiumSection extends StatelessWidget {
  final List<LeaderboardEntry> topThree;
  final void Function(LeaderboardEntry) onTap;

  const PodiumSection({super.key, required this.topThree, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (topThree.isEmpty) return const SizedBox();

    return Column(
      children: [
        // Rank 1 — gold, full width
        if (topThree.isNotEmpty)
          GestureDetector(
            onTap: () => onTap(topThree[0]),
            child: _RankOneCard(entry: topThree[0]),
          ),
        const SizedBox(height: 12),

        // Ranks 2-3 side by side
        if (topThree.length >= 2)
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => onTap(topThree[1]),
                  child: _SmallPodiumCard(
                    entry: topThree[1],
                    medalEmoji: '\ud83e\udd48',
                    accentColor: AppColors.silver,
                    rank: 2,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              if (topThree.length >= 3)
                Expanded(
                  child: GestureDetector(
                    onTap: () => onTap(topThree[2]),
                    child: _SmallPodiumCard(
                      entry: topThree[2],
                      medalEmoji: '\ud83e\udd49',
                      accentColor: AppColors.bronze,
                      rank: 3,
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _RankOneCard extends StatelessWidget {
  final LeaderboardEntry entry;
  const _RankOneCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
        boxShadow: [
          BoxShadow(
            color: AppColors.gold.withValues(alpha: 0.08),
            blurRadius: 20,
          ),
        ],
      ),
      child: Row(
        children: [
          // Gold accent bar
          Container(
            width: 5,
            height: 60,
            margin: const EdgeInsets.only(right: 16),
            decoration: BoxDecoration(
              color: AppColors.gold,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          // Avatar
          Stack(
            clipBehavior: Clip.none,
            children: [
              AvatarCircle(
                radius: 30,
                imageUrl: entry.avatarURL,
                initials: entry.displayName.isNotEmpty
                    ? entry.displayName[0]
                    : '?',
                borderColor: AppColors.gold,
                borderWidth: 2,
              ),
              Positioned(
                bottom: -4,
                right: -4,
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: AppColors.gold,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                          color: AppColors.gold.withValues(alpha: 0.5),
                          blurRadius: 6),
                    ],
                  ),
                  child: const Center(
                    child: Text('1',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w900,
                            color: Colors.black)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('\ud83e\udd47 ', style: TextStyle(fontSize: 18)),
                    Text(entry.displayName,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                  ],
                ),
                Text(
                  '${_fmt(entry.totalXP)} XP',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: AppColors.gold,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.workspace_premium,
              color: AppColors.gold.withValues(alpha: 0.3), size: 36),
        ],
      ),
    );
  }
}

class _SmallPodiumCard extends StatelessWidget {
  final LeaderboardEntry entry;
  final String medalEmoji;
  final Color accentColor;
  final int rank;

  const _SmallPodiumCard({
    required this.entry,
    required this.medalEmoji,
    required this.accentColor,
    required this.rank,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              AvatarCircle(
                radius: 26,
                imageUrl: entry.avatarURL,
                initials: entry.displayName.isNotEmpty
                    ? entry.displayName[0]
                    : '?',
                borderColor: accentColor,
                borderWidth: 2,
              ),
              Positioned(
                bottom: -3,
                right: -3,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: accentColor,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text('$rank',
                        style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            color: Colors.black)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(medalEmoji, style: const TextStyle(fontSize: 13)),
              const SizedBox(width: 3),
              Flexible(
                child: Text(
                  entry.displayName.length > 10
                      ? '${entry.displayName.substring(0, 10)}.'
                      : entry.displayName,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          Text(
            '${_fmt(entry.totalXP)} XP',
            style: theme.textTheme.titleSmall?.copyWith(
              color: accentColor,
              fontWeight: FontWeight.w700,
            ),
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
