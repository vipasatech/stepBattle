import 'package:flutter/material.dart';

import '../../../config/colors.dart';
import '../../../models/leaderboard_entry_model.dart';
import '../../../widgets/avatar_circle.dart';

/// One leaderboard row — Strava-style: rank cell, avatar, name (single
/// line), XP total on the right, chevron.
///
/// Rank 1 renders a crown icon instead of the number. When
/// [highlightYou] is true the row paints a tinted background — used
/// for the sticky "You" row pinned at the bottom of the board.
class RankRow extends StatelessWidget {
  final LeaderboardEntry entry;
  final VoidCallback? onTap;

  /// Show "You" instead of the display name and tint the row with the
  /// brand surface — used only by the sticky-bottom variant.
  final bool highlightYou;

  const RankRow({
    super.key,
    required this.entry,
    this.onTap,
    this.highlightYou = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isTop = entry.rank == 1;

    return InkWell(
      onTap: onTap,
      child: Container(
        // Background: transparent for regular rows, a violet tint for
        // the sticky "You" highlight. Bottom border segregates each
        // row like the Strava reference — 1 px muted outline, drawn
        // per-row so it stays glued to the row on scroll.
        decoration: BoxDecoration(
          color: highlightYou
              ? AppColors.primary.withValues(alpha: 0.08)
              : null,
          border: Border(
            bottom: BorderSide(
              color: AppColors.outlineVariant.withValues(alpha: 0.4),
              width: 1,
            ),
          ),
        ),
        padding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            // ---- Rank cell (fixed width so all rows align) ----
            SizedBox(
              width: 36,
              child: Center(
                child: isTop
                    ? Icon(
                        Icons.emoji_events,
                        color: AppColors.amber,
                        size: 22,
                      )
                    : Text(
                        '${entry.rank}',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 10),

            // ---- Avatar ----
            AvatarCircle(
              radius: 20,
              imageUrl: entry.avatarURL,
              initials: _initials(entry.friendlyName),
              borderColor: scheme.outlineVariant,
              borderWidth: 1,
            ),
            const SizedBox(width: 12),

            // ---- Name ----
            Expanded(
              child: Text(
                highlightYou ? 'You' : entry.friendlyName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight:
                      highlightYou ? FontWeight.w900 : FontWeight.w700,
                  color: highlightYou ? AppColors.primary : null,
                ),
              ),
            ),

            // ---- XP right-aligned ----
            Text(
              _fmt(entry.totalXP),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
                fontFamily: 'Manrope',
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.chevron_right,
              size: 18,
              color: AppColors.onSurfaceVariant.withValues(alpha: 0.5),
            ),
          ],
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

/// Small-caps column header row — "RANK  ATHLETE  XP".
/// Widths mirror [RankRow] so the columns visually align.
class RankColumnHeaders extends StatelessWidget {
  const RankColumnHeaders({super.key});

  @override
  Widget build(BuildContext context) {
    final labelStyle = TextStyle(
      color: AppColors.onSurfaceVariant,
      fontFamily: 'Manrope',
      fontSize: 11,
      fontWeight: FontWeight.w800,
      letterSpacing: 1.4,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            child: Center(child: Text('RANK', style: labelStyle)),
          ),
          const SizedBox(width: 10),
          // Avatar column has no header — the ATHLETE label spans it +
          // the name column to match Strava's alignment.
          const SizedBox(width: 40 + 12),
          Expanded(child: Text('ATHLETE', style: labelStyle)),
          Text('XP', style: labelStyle),
          const SizedBox(width: 8 + 18), // chevron + spacer
        ],
      ),
    );
  }
}
