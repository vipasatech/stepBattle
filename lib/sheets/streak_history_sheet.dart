import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/colors.dart';
import '../providers/user_provider.dart';
import '../widgets/bottom_sheet_handle.dart';

/// Streak history sheet — current streak, best streak, streak bonus info.
class StreakHistorySheet extends ConsumerWidget {
  const StreakHistorySheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final current = profile?.currentStreak ?? 0;
    final best = profile?.bestStreak ?? 0;

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

          // Fire icon
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: AppColors.errorDim.withValues(alpha: 0.15),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppColors.errorDim.withValues(alpha: 0.3),
                  blurRadius: 30,
                ),
              ],
            ),
            child: Icon(Icons.local_fire_department,
                color: AppColors.errorDim, size: 36),
          ),
          const SizedBox(height: 16),

          Text('Streak',
              style: theme.textTheme.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 24),

          // Current streak
          _StreakRow(
            label: 'Current Streak',
            value: '$current days',
            icon: Icons.local_fire_department,
            iconColor: current > 0 ? AppColors.errorDim : AppColors.onSurfaceVariant,
          ),
          const SizedBox(height: 14),

          // Best streak
          _StreakRow(
            label: 'Best Streak',
            value: '$best days',
            icon: Icons.emoji_events,
            iconColor: AppColors.amber,
          ),
          const SizedBox(height: 24),

          // Info card
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('How Streaks Work',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(
                  '\u2022 Log at least 1 step each day to maintain your streak\n'
                  '\u2022 Streak breaks if a full day passes with 0 steps\n'
                  '\u2022 +100 XP bonus awarded every 7th consecutive day\n'
                  '\u2022 You don\'t need to hit your daily goal to keep it',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.onSurfaceVariant,
                    height: 1.8,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // Next bonus
          if (current > 0) ...[
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 18, vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  Icon(Icons.military_tech,
                      color: AppColors.primary, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Next +100 XP bonus in ${7 - (current % 7)} days',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StreakRow extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color iconColor;

  const _StreakRow({
    required this.label,
    required this.value,
    required this.icon,
    required this.iconColor,
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
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 24),
          const SizedBox(width: 14),
          Expanded(
            child: Text(label,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: AppColors.onSurfaceVariant)),
          ),
          Text(value,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              )),
        ],
      ),
    );
  }
}
