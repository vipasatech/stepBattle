import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../config/colors.dart';
import '../../../providers/step_provider.dart';
import '../../../providers/user_provider.dart';

/// Three equal-width stat pill cards below the overview card:
/// Calories | Rank | Missions
class StatPillsRow extends ConsumerWidget {
  const StatPillsRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final calories = ref.watch(todayCaloriesProvider);
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final rank = profile?.rank ?? 0;

    return Row(
      children: [
        Expanded(
          child: _StatPill(
            value: calories.when(
              data: (cal) => '${cal.round()} kcal',
              loading: () => '...',
              error: (_, __) => '-- kcal',
            ),
            label: 'Burnt Today',
            icon: Icons.local_fire_department,
            iconColor: AppColors.amber,
            onTap: null,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _StatPill(
            value: rank > 0 ? '#$rank' : '--',
            label: 'Global Rank',
            icon: Icons.leaderboard,
            iconColor: AppColors.primary,
            onTap: () => context.go('/leaderboard'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _StatPill(
            value: '0/3',
            label: 'Completed',
            icon: Icons.military_tech,
            iconColor: AppColors.success,
            onTap: () => context.go('/missions'),
          ),
        ),
      ],
    );
  }
}

class _StatPill extends StatelessWidget {
  final String value;
  final String label;
  final IconData icon;
  final Color iconColor;
  final VoidCallback? onTap;

  const _StatPill({
    required this.value,
    required this.label,
    required this.icon,
    required this.iconColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.05),
          ),
        ),
        child: Column(
          children: [
            Icon(icon, color: iconColor, size: 20),
            const SizedBox(height: 8),
            Text(
              value,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                fontSize: 9,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
