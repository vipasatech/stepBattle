import 'package:flutter/material.dart';
import '../../../config/colors.dart';
import '../../../models/mission_model.dart';
import '../../../models/user_mission_progress_model.dart';
import '../../../widgets/progress_bar.dart';

/// Tall weekly challenge card with decorative background icon.
class WeeklyChallengeCard extends StatelessWidget {
  final MissionModel mission;
  final UserMissionProgress? progress;
  final VoidCallback? onTap;

  const WeeklyChallengeCard({
    super.key,
    required this.mission,
    this.progress,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = progress?.progressFraction ?? 0.0;
    final isComplete = progress?.isCompleted ?? false;

    final accentColor = _accentFor(mission.category);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
        ),
        child: Stack(
          children: [
            // Decorative background icon
            Positioned(
              top: -8,
              right: -8,
              child: Icon(
                _categoryIcon(mission.category),
                size: 72,
                color: accentColor.withValues(alpha: 0.08),
              ),
            ),

            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Badge
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _badgeLabel(mission.difficulty),
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: accentColor,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
                const SizedBox(height: 10),

                // Title
                Text(
                  mission.title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 4),

                // XP reward
                Text(
                  '+${mission.xpReward} XP',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: accentColor,
                    fontWeight: FontWeight.w700,
                  ),
                ),

                const SizedBox(height: 24),

                // Progress labels
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      progress?.progressLabel ??
                          '0 / ${_fmtTarget(mission)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      progress?.percentLabel ?? '0%',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // Progress bar
                StepProgressBar(
                  progress: fraction,
                  height: 10,
                  showSpark: !isComplete,
                  startColor: accentColor,
                  endColor: accentColor.withValues(alpha: 0.6),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _accentFor(MissionCategory cat) => switch (cat) {
        MissionCategory.steps => AppColors.tertiary,
        MissionCategory.battle => AppColors.primary,
        MissionCategory.streak => AppColors.amber,
        MissionCategory.calories => AppColors.error,
      };

  IconData _categoryIcon(MissionCategory cat) => switch (cat) {
        MissionCategory.steps => Icons.directions_walk,
        MissionCategory.battle => Icons.bolt,
        MissionCategory.streak => Icons.local_fire_department,
        MissionCategory.calories => Icons.whatshot,
      };

  String _badgeLabel(String difficulty) => switch (difficulty) {
        'hard' => 'ELITE CHALLENGE',
        'medium' => 'BATTLE MASTER',
        _ => 'WEEKLY QUEST',
      };

  String _fmtTarget(MissionModel m) {
    if (m.targetValue >= 1000) {
      return '${m.targetValue ~/ 1000},000';
    }
    return '${m.targetValue}';
  }
}
