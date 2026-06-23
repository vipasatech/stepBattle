import 'package:flutter/material.dart';

import '../config/colors.dart';

/// Public/Private toggle row used in every battle creation sheet
/// (1v1, Multi-player, Team). Off by default → invite-only; on → battle
/// appears in Discover and anyone with the join code can drop in.
class BattleVisibilityToggle extends StatelessWidget {
  final bool isPublic;
  final ValueChanged<bool> onChanged;

  const BattleVisibilityToggle({
    super.key,
    required this.isPublic,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.glassBackground,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isPublic ? Icons.public : Icons.lock_outline,
            color: isPublic ? AppColors.primary : AppColors.onSurfaceVariant,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isPublic ? 'Public lobby' : 'Private battle',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  isPublic
                      ? 'Anyone can find & join from Discover'
                      : 'Invite-only — share code to add players',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: AppColors.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: isPublic,
            onChanged: onChanged,
            activeColor: AppColors.primary,
          ),
        ],
      ),
    );
  }
}
