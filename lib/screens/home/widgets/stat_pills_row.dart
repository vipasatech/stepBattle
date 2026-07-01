import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../config/colors.dart';
import '../../../providers/leaderboard_provider.dart';
import '../../../providers/step_provider.dart';
import '../../../sheets/location_permission_sheet.dart';

/// Three equal-width stat pill cards below the overview card:
/// Calories Burnt | Global Rank | Distance.
///
/// The third pill used to show the Day Streak — that signal now lives
/// in the streak strip above the Overview card, so this slot was
/// reclaimed for today's walking/running distance instead.
class StatPillsRow extends ConsumerWidget {
  const StatPillsRow({super.key});

  /// Default stride length when we don't have a calibrated value yet.
  /// Matches `RunTrackingService._strideMeters` so the home distance
  /// estimate doesn't drift from the in-session estimate.
  static const _defaultStrideMeters = 0.762;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final calories = ref.watch(todayCaloriesProvider);
    // `profile.rank` was always 0 — there's no rank column on the
    // profiles table; rank is a computed leaderboard position. Pull it
    // from myRankProvider which queries the LeaderboardService.
    final rank = ref.watch(myRankProvider).valueOrNull?.rank ?? 0;
    // Distance derived from today's step count × default stride. No
    // separate "today's verified GPS distance" aggregate exists yet —
    // when we add one, swap this for that.
    final stepsAsync = ref.watch(todayStepsAsyncProvider);

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
            // Bolt (energy expended) reads visually distinct from the
            // flame icon used for the Day Streak pill, so the two pills
            // don't read as duplicates at a glance.
            icon: Icons.bolt,
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
            // Tap re-prompts for location if it's missing — geo-scoped
            // leaderboards only populate once we have a home set.
            onTap: () async {
              await ensureLocationPermission(
                context,
                reason:
                    'StepBattle uses your location to place you on local leaderboards (district, state, country) and show how you rank near you.',
              );
              if (context.mounted) context.go('/leaderboard');
            },
          ),
        ),
        const SizedBox(width: 8),
        // Third pill: today's distance. The Day Streak signal moved up
        // to the streak strip above the Overview card, freeing this
        // slot for something more "today-at-a-glance" relevant.
        Expanded(
          child: _StatPill(
            value: stepsAsync.when(
              data: (steps) => _fmtDistance(steps * _defaultStrideMeters),
              loading: () => '...',
              error: (_, __) => '-- km',
            ),
            label: 'Distance',
            icon: Icons.straighten,
            iconColor: AppColors.primary,
            onTap: null,
          ),
        ),
      ],
    );
  }

  /// Render metres as a compact km string. Under 100 m drops the
  /// unit to "m" so a fresh-out-of-bed value isn't "0.05 km".
  static String _fmtDistance(double meters) {
    if (meters < 100) return '${meters.round()} m';
    final km = meters / 1000.0;
    return '${km.toStringAsFixed(km < 10 ? 2 : 1)} km';
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
            color: AppColors.onSurface.withValues(alpha: 0.05),
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
