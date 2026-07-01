import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../config/colors.dart';
import '../../../providers/step_provider.dart';
import '../../../providers/user_provider.dart';
import '../../../widgets/glass_card.dart';
import '../../../widgets/progress_bar.dart';
import '../../../widgets/shimmer_loader.dart';

/// The hero overview card on Home — shows level, today's steps, XP delta,
/// and progress bar toward the next level.
class OverviewCard extends ConsumerWidget {
  const OverviewCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final todayStepsAsync = ref.watch(todayStepsAsyncProvider);
    final level = ref.watch(userLevelProvider);
    final progress = ref.watch(levelProgressProvider);
    final xpToNext = ref.watch(xpToNextLevelProvider);

    final totalXP = profile?.totalXP ?? 0;

    return GlassCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Level badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.primaryBrand.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppColors.primaryBrand.withValues(alpha: 0.3),
              ),
            ),
            child: Text(
              'Level $level',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),

          const SizedBox(height: 14),

          // Step count — large display, shrunk from 56 → 44 so the
          // card overall feels more compact and gives more breathing
          // room to surrounding sections.
          Center(
            child: todayStepsAsync.when(
              data: (steps) => Text(
                _formatNumber(steps),
                style: theme.textTheme.displayLarge?.copyWith(
                  fontSize: 44,
                  color: AppColors.onSurface,
                  height: 1.0,
                ),
              ),
              loading: () => const ShimmerLoader(
                width: 160,
                height: 44,
                borderRadius: 10,
              ),
              error: (_, __) => Text(
                '—',
                style: theme.textTheme.displayLarge?.copyWith(
                  fontSize: 44,
                  color: AppColors.onSurfaceVariant,
                  height: 1.0,
                ),
              ),
            ),
          ),
          const SizedBox(height: 2),
          Center(
            child: Text(
              'STEPS TODAY',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                letterSpacing: 2.5,
                fontSize: 10,
              ),
            ),
          ),

          const SizedBox(height: 10),

          // XP delta line
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.trending_up,
                  size: 14,
                  color: AppColors.success,
                ),
                const SizedBox(width: 4),
                Text(
                  '+${_formatNumber(totalXP)} XP total',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.success,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 18),

          // Level progress labels
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'LVL $level',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.onSurfaceVariant,
                  fontSize: 10,
                ),
              ),
              Text(
                'LVL ${level + 1}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.onSurfaceVariant,
                  fontSize: 10,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),

          // Progress bar with spark
          StepProgressBar(progress: progress, height: 8),

          const SizedBox(height: 6),

          // Steps to go
          Center(
            child: Text(
              '$xpToNext XP to go',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                fontSize: 11,
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
