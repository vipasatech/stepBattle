import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

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
///
/// Two shapes:
///   • Normal — pass [entry] with the user's rank + XP.
///   • Offline — pass `offline: true` (no entry needed). Shows a
///     cloud-off icon in the rank slot and a "You're offline" line
///     so the card stays visible even when the rank API is
///     unreachable, rather than vanishing entirely.
class FloatingRankCard extends StatelessWidget {
  final LeaderboardEntry? entry;
  final bool offline;

  const FloatingRankCard({super.key, required LeaderboardEntry this.entry})
      : offline = false;

  const FloatingRankCard.offline({super.key})
      : entry = null,
        offline = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Was `ClipRRect + BackdropFilter(blur 20)` — that blur ran on
    // every composite frame as ~100 leaderboard rows scrolled past
    // underneath. Now: opaque tinted surface over an opaque tinted
    // scaffold background reads visually the same (primary tint at
    // 0.14 alpha composited against the surfaceContainerHigh below)
    // without paying the per-frame framebuffer read + Gaussian blur.
    // Shadow is kept but with a `ClipRect`-style bounded surface so
    // it isn't painted over a stretching offscreen buffer.
    final card = Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        // Layer the tint over the theme surface so the card reads as
        // "you" without needing blur to hide the list underneath.
        color: Color.alphaBlend(
          AppColors.primary.withValues(alpha: 0.18),
          AppColors.surfaceContainerHigh,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.3),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: offline ? _buildOffline(theme) : _buildEntry(theme, scheme),
    );
    // Offline variant has no profile to open — leave it non-interactive.
    // Entry variant: tap → the user's own Profile tab. Previously the
    // card was purely visual; testers expected it to open their profile
    // the same way tapping their in-list row does.
    if (offline) return card;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => context.push('/profile'),
      child: card,
    );
  }

  Widget _buildOffline(ThemeData theme) {
    return Row(
      children: [
        SizedBox(
          width: 36,
          child: Center(
            child: Icon(
              Icons.cloud_off,
              size: 20,
              color: AppColors.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.onSurfaceVariant.withValues(alpha: 0.15),
            border: Border.all(
              color: AppColors.onSurfaceVariant.withValues(alpha: 0.35),
              width: 2,
            ),
          ),
          child: Icon(
            Icons.wifi_off,
            size: 18,
            color: AppColors.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'You',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: AppColors.primary,
                ),
              ),
              Text(
                'Offline · rank unavailable',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEntry(ThemeData theme, ColorScheme scheme) {
    final e = entry!;
    return Row(
      children: [
        // Rank cell — same 36 dp width as RankRow so the sticky
        // card visually threads into the list above.
        SizedBox(
          width: 36,
          child: Center(
            child: Text(
              '${e.rank}',
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
          imageUrl: e.avatarURL,
          initials: _initials(e.friendlyName),
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
          _fmt(e.totalXP),
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
