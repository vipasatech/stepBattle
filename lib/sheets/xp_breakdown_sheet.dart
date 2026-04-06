import 'package:flutter/material.dart';
import '../config/colors.dart';
import '../widgets/bottom_sheet_handle.dart';

/// "How to Earn More XP" breakdown sheet — triggered from Leaderboard "?" icon
/// and from the XP pill in Missions tab.
class XPBreakdownSheet extends StatelessWidget {
  const XPBreakdownSheet({super.key});

  static const _rewards = [
    ('Complete a daily mission', '+50 XP'),
    ('Win a 1 vs 1 battle', '+200 XP'),
    ('Maintain a 7-day streak', '+100 XP'),
    ('Reach daily step goal', '+75 XP'),
    ('Win a group battle', '+300 XP'),
    ('Complete all daily missions (bonus)', '+150 XP'),
    ('Win a clan battle (per member)', '+300 XP'),
    ('Every 1,000 steps', '+10 XP'),
    ('Complete weekly challenge', '+300–500 XP'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const BottomSheetHandle(),

          // Title
          Row(
            children: [
              Icon(Icons.military_tech, color: AppColors.primary, size: 24),
              const SizedBox(width: 10),
              Text('How to Earn XP',
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 20),

          // Table
          Container(
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(16),
              border:
                  Border.all(color: Colors.white.withValues(alpha: 0.05)),
            ),
            child: Column(
              children: _rewards.asMap().entries.map((entry) {
                final i = entry.key;
                final (action, xp) = entry.value;
                return Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    border: i < _rewards.length - 1
                        ? Border(
                            bottom: BorderSide(
                                color: Colors.white.withValues(alpha: 0.03)))
                        : null,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(action,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: AppColors.onSurfaceVariant)),
                      ),
                      Text(xp,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: AppColors.success,
                            fontWeight: FontWeight.w700,
                          )),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}
