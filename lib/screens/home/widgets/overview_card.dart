import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../config/colors.dart';
import '../../../providers/step_provider.dart';
import '../../../providers/user_provider.dart';
import '../../../widgets/glass_card.dart';
import '../../../widgets/progress_bar.dart';

/// The hero overview card on Home — shows level, today's steps, XP delta,
/// and progress bar toward the next level.
class OverviewCard extends ConsumerWidget {
  const OverviewCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final todaySteps = ref.watch(todayStepsProvider);
    final level = ref.watch(userLevelProvider);
    final progress = ref.watch(levelProgressProvider);
    final xpToNext = ref.watch(xpToNextLevelProvider);

    final totalXP = profile?.totalXP ?? 0;

    return GlassCard(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Level badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.primaryBrand.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: AppColors.primaryBrand.withValues(alpha: 0.3),
              ),
            ),
            child: Text(
              'Level $level',
              style: theme.textTheme.labelMedium?.copyWith(
                color: AppColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),

          const SizedBox(height: 20),

          // Step count — massive display per design system
          Center(
            child: Text(
              _formatNumber(todaySteps),
              style: theme.textTheme.displayLarge?.copyWith(
                fontSize: 56,
                color: AppColors.onSurface,
                height: 1.0,
              ),
            ),
          ),
          Center(
            child: Text(
              'STEPS TODAY',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                letterSpacing: 3,
              ),
            ),
          ),

          const SizedBox(height: 16),

          // XP delta line
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.trending_up,
                  size: 16,
                  color: AppColors.success,
                ),
                const SizedBox(width: 4),
                Text(
                  '+${_formatNumber(totalXP)} XP total',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.success,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Level progress labels
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'LVL $level',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.onSurfaceVariant,
                ),
              ),
              Text(
                'LVL ${level + 1}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),

          // Progress bar with spark
          StepProgressBar(progress: progress, height: 10),

          const SizedBox(height: 8),

          // Steps to go
          Center(
            child: Text(
              '$xpToNext XP to go',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatNumber(int n) {
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
