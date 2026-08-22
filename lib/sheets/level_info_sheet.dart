import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/colors.dart';
import '../config/constants.dart';
import '../providers/user_provider.dart';
import '../widgets/bottom_sheet_handle.dart';
import '../widgets/progress_bar.dart';

/// Bottom sheet explaining how leveling works, opened when the user
/// taps the Level badge or progress bar on the Home overview card.
///
/// Structure:
///   • Header: current level + progress bar + "N XP to Level M"
///   • Short explainer: 4 bullet points on how you earn XP
///   • 3 archetype examples covering a range of activity levels
///   • Threshold reference: mini table of upcoming levels
///
/// Kept intentionally short — the user's ask was "not a lot of
/// information, keep the necessary such that user will understand
/// how levelling up works."
class LevelInfoSheet extends ConsumerWidget {
  const LevelInfoSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => const LevelInfoSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final totalXP = ref.watch(userProfileProvider
        .select((async) => async.valueOrNull?.totalXP ?? 0));
    final level = ref.watch(userLevelProvider);
    final progress = ref.watch(levelProgressProvider);
    final pointsToNext = ref.watch(pointsToNextLevelProvider);

    // Next few levels to preview — 5 rows after current so the user
    // sees a realistic horizon without the full 20-level table.
    final upcoming = <MapEntry<int, int>>[];
    for (var lvl = level; lvl <= level + 5; lvl++) {
      final threshold = AppConstants.levelThresholds[lvl];
      if (threshold == null) break;
      upcoming.add(MapEntry(lvl, threshold));
    }

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const BottomSheetHandle(),
          Expanded(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              children: [
                // Title
                Text(
                  'How leveling up works',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Your Level shows how far you\'ve come. Higher levels unlock nothing gate-y — it\'s a badge.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: AppColors.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 20),

                // Current progress card
                _CurrentProgressCard(
                  level: level,
                  totalXP: totalXP,
                  progress: progress,
                  pointsToNext: pointsToNext,
                ),
                const SizedBox(height: 24),

                // How you earn XP
                Text(
                  'How you earn XP',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                const _BulletRow(
                  icon: Icons.rocket_launch,
                  text: 'Signing up: +$_signUp',
                ),
                const _BulletRow(
                  icon: Icons.local_fire_department,
                  text: 'Every 7-day streak (once): +$_firstStreak',
                ),
                const _BulletRow(
                  icon: Icons.emoji_events,
                  text: 'Every 30-day streak milestone: +$_streakMilestone',
                ),
                const _BulletRow(
                  icon: Icons.check_circle,
                  text: 'Daily "Keep Streak Alive" mission: +$_dailyMission',
                ),
                const _BulletRow(
                  icon: Icons.sports_score,
                  text: 'Winning a stake battle: pot of everyone\'s stakes',
                ),
                const SizedBox(height: 24),

                // Examples
                Text(
                  '3 example journeys',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                const _ExampleCard(
                  name: 'Priya',
                  archetype: 'Casual walker',
                  detail:
                      'Walks 2,000 steps/day between meetings. Signs up (+500), '
                      'keeps a 7-day streak (+50), does daily missions '
                      'occasionally.',
                  after: '~30 days',
                  levelAfter: 'Level 3',
                ),
                const SizedBox(height: 10),
                const _ExampleCard(
                  name: 'Arjun',
                  archetype: 'Regular exerciser',
                  detail:
                      'Jogs 7,500 steps/day. Signs up, hits 30-day streak '
                      'milestone, wins 3 daily battles at 100 XP stake.',
                  after: '~30 days',
                  levelAfter: 'Level 6',
                ),
                const SizedBox(height: 10),
                const _ExampleCard(
                  name: 'Meera',
                  archetype: 'Serious athlete',
                  detail:
                      'Runs 15,000+ steps/day. Signs up, keeps 60-day streak '
                      '(+100 twice), wins 6 stake battles at 200 XP each.',
                  after: '~30 days',
                  levelAfter: 'Level 10',
                ),
                const SizedBox(height: 24),

                // Threshold table
                Text(
                  'Next levels',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                _ThresholdTable(upcoming: upcoming, currentLevel: level),
                const SizedBox(height: 8),
                Text(
                  'Levels go up to 20. Every level takes more XP than the last.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Interpolated into the "How you earn XP" bullets from AppConstants —
  // kept as compile-time string constants so the widget stays const-
  // constructible (no widget rebuilds on every open).
  static const _signUp = '${AppConstants.xpSignUpBonus} XP';
  static const _firstStreak = '${AppConstants.xpFirst7DayStreak} XP';
  static const _streakMilestone =
      '${AppConstants.xp30DayStreakMilestone} XP';
  static const _dailyMission =
      '${AppConstants.xpDailyStreakMission} XP';
}

/// The mini "you are here" card at the top of the sheet — mirrors the
/// Home overview card's progress row so the user sees the same numbers
/// they tapped from, just with more context.
class _CurrentProgressCard extends StatelessWidget {
  final int level;
  final int totalXP;
  final double progress;
  final int pointsToNext;

  const _CurrentProgressCard({
    required this.level,
    required this.totalXP,
    required this.progress,
    required this.pointsToNext,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.primaryBrand.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.primaryBrand.withValues(alpha: 0.25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'You\'re on Level $level',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: AppColors.primary,
                ),
              ),
              Text(
                '$totalXP XP',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
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
          const SizedBox(height: 4),
          StepProgressBar(progress: progress, height: 8),
          const SizedBox(height: 8),
          Text(
            pointsToNext > 0
                ? '$pointsToNext XP to Level ${level + 1}'
                : 'Max level reached',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppColors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _BulletRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _BulletRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _ExampleCard extends StatelessWidget {
  final String name;
  final String archetype;
  final String detail;
  final String after;
  final String levelAfter;

  const _ExampleCard({
    required this.name,
    required this.archetype,
    required this.detail,
    required this.after,
    required this.levelAfter,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                name,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  archetype,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            detail,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppColors.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.arrow_forward, size: 14, color: AppColors.success),
              const SizedBox(width: 6),
              Text(
                'After $after → $levelAfter',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.success,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ThresholdTable extends StatelessWidget {
  final List<MapEntry<int, int>> upcoming;
  final int currentLevel;

  const _ThresholdTable({required this.upcoming, required this.currentLevel});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          for (var i = 0; i < upcoming.length; i++) ...[
            _row(
              theme,
              upcoming[i].key,
              upcoming[i].value,
              isCurrent: upcoming[i].key == currentLevel,
            ),
            if (i < upcoming.length - 1)
              Divider(
                height: 1,
                color: AppColors.onSurface.withValues(alpha: 0.06),
              ),
          ],
        ],
      ),
    );
  }

  Widget _row(ThemeData theme, int level, int threshold,
      {required bool isCurrent}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 32,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: isCurrent
                  ? AppColors.primary.withValues(alpha: 0.16)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$level',
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: isCurrent
                    ? AppColors.primary
                    : AppColors.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            'Level $level',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: isCurrent ? FontWeight.w800 : FontWeight.w500,
            ),
          ),
          const Spacer(),
          Text(
            '$threshold XP',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppColors.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
