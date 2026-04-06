import 'package:flutter/material.dart';
import '../../../config/colors.dart';
import '../../../models/leaderboard_entry_model.dart';
import '../../../widgets/avatar_circle.dart';

/// Standard leaderboard row for ranks 4+.
class RankRow extends StatelessWidget {
  final LeaderboardEntry entry;
  final VoidCallback? onTap;

  const RankRow({super.key, required this.entry, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Text(
                '${entry.rank}',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: AppColors.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 12),
            AvatarCircle(
              radius: 20,
              imageUrl: entry.avatarURL,
              initials: entry.displayName.isNotEmpty
                  ? entry.displayName[0]
                  : '?',
              borderColor: Colors.white.withValues(alpha: 0.05),
              borderWidth: 1,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.displayName,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  Text('${_fmt(entry.totalXP)} XP',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: AppColors.onSurfaceVariant)),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                color: AppColors.onSurfaceVariant.withValues(alpha: 0.5),
                size: 20),
          ],
        ),
      ),
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
