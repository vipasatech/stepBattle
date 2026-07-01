import 'dart:ui';
import 'package:flutter/material.dart';

import '../../../config/colors.dart';
import '../../../models/leaderboard_entry_model.dart';
import '../../../widgets/avatar_circle.dart';

/// Sticky "You" card pinned above the bottom nav.
///
/// The leaderboard screen only renders this when the signed-in user
/// ranks OUTSIDE the top 5 — if they're already visible in the main
/// list, this card would just duplicate the row. Visual matches the
/// in-list [RankRow] with a violet tint and a "You" label so it
/// reads as continuous with the board above.
class FloatingRankCard extends StatelessWidget {
  final LeaderboardEntry entry;

  const FloatingRankCard({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.3),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              // Rank cell — same 36 dp width as RankRow so the sticky
              // card visually threads into the list above.
              SizedBox(
                width: 36,
                child: Center(
                  child: Text(
                    '${entry.rank}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),

              AvatarCircle(
                radius: 20,
                imageUrl: entry.avatarURL,
                initials: _initials(entry.displayName),
                borderColor: AppColors.primary.withValues(alpha: 0.5),
                borderWidth: 2,
              ),
              const SizedBox(width: 12),

              Expanded(
                child: Text(
                  'You',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: AppColors.primary,
                  ),
                ),
              ),

              Text(
                _fmt(entry.totalXP),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  fontFamily: 'Manrope',
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: AppColors.primary.withValues(alpha: 0.7),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _initials(String name) {
    if (name.isEmpty) return '?';
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name[0].toUpperCase();
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
