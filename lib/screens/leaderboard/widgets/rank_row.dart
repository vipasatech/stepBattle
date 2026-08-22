import 'package:flutter/material.dart';

import '../../../config/colors.dart';
import '../../../models/leaderboard_entry_model.dart';
import '../../../widgets/avatar_circle.dart';

/// One leaderboard row — Strava-style: rank cell, avatar, name (single
/// line), XP total on the right, chevron.
///
/// Rank 1 renders a crown icon instead of the number. When
/// [highlightYou] is true the row paints a subtle purple gradient
/// background AND a small "YOU" pill sits next to the display name —
/// used both for the current user's row in the main list AND for the
/// floating rank card pinned above the bottom nav. Keeping the real
/// name (rather than replacing it with "You") means the two surfaces
/// stay visually identical, which is what makes the pinned card feel
/// like a mirror of the actual list row.
class RankRow extends StatelessWidget {
  final LeaderboardEntry entry;
  final VoidCallback? onTap;

  /// True when this row represents the currently-signed-in user.
  /// Paints the gradient bg + attaches the "YOU" pill.
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

    // RepaintBoundary — each rank row is one atomic paint unit. The
    // leaderboard scrolls through hundreds of rows on the global tab;
    // isolating each row keeps a single row-tint change from repainting
    // every row above it.
    return RepaintBoundary(
      child: InkWell(
        onTap: onTap,
        child: Container(
          // Regular rows: transparent bg + 1 px bottom divider so the
          // list reads as a table (matches Strava). "You" rows: a
          // subtle left-to-right purple gradient so the row visually
          // "steps forward" without shouting.
          decoration: BoxDecoration(
            gradient: highlightYou
                ? LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [
                      AppColors.primary.withValues(alpha: 0.18),
                      AppColors.primary.withValues(alpha: 0.04),
                    ],
                  )
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
                            color: highlightYou
                                ? AppColors.primary
                                : AppColors.onSurfaceVariant,
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
                borderColor: highlightYou
                    ? AppColors.primary
                    : scheme.outlineVariant,
                borderWidth: highlightYou ? 2 : 1,
              ),
              const SizedBox(width: 12),

              // ---- Name (+ optional YOU pill) ----
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        entry.friendlyName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: highlightYou
                              ? FontWeight.w900
                              : FontWeight.w700,
                          color: highlightYou ? AppColors.primary : null,
                        ),
                      ),
                    ),
                    if (highlightYou) ...[
                      const SizedBox(width: 8),
                      _YouPill(),
                    ],
                  ],
                ),
              ),

              // ---- XP right-aligned ----
              Text(
                _fmt(entry.totalXP),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  fontFamily: 'Manrope',
                  color: highlightYou ? AppColors.primary : null,
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

/// The small "YOU" chip that sits next to the display name on the
/// current user's row. Purple pill, white text — matches the primary
/// accent used elsewhere for "you belong here" signals (the profile
/// stats strip's XP tint, the streak flame, etc.).
class _YouPill extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Text(
        'YOU',
        style: TextStyle(
          color: Colors.white,
          fontFamily: 'Manrope',
          fontSize: 9,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.8,
        ),
      ),
    );
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
