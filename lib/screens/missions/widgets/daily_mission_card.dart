import 'package:flutter/material.dart';
import '../../../config/colors.dart';
import '../../../models/mission_model.dart';
import '../../../models/user_mission_progress_model.dart';
import '../../../widgets/progress_bar.dart';

/// A single daily mission card showing icon, title, XP, progress bar, status.
class DailyMissionCard extends StatelessWidget {
  final MissionModel mission;
  final UserMissionProgress? progress;
  final VoidCallback? onTap;

  const DailyMissionCard({
    super.key,
    required this.mission,
    this.progress,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isComplete = progress?.isCompleted ?? false;
    final fraction = progress?.progressFraction ?? 0.0;
    final hasProgress = progress != null && progress!.currentValue > 0;
    final isLocked = !isComplete && !hasProgress && mission.category == MissionCategory.battle;

    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: isLocked ? 0.5 : 1.0,
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: isLocked
                ? AppColors.surfaceContainerLow
                : AppColors.glassBackground,
            borderRadius: BorderRadius.circular(16),
            border: isComplete
                ? Border.all(color: AppColors.success.withValues(alpha: 0.3))
                : isLocked
                    ? Border.all(
                        color: AppColors.outlineVariant.withValues(alpha: 0.1))
                    : const Border(
                        left: BorderSide(color: AppColors.primary, width: 4)),
            boxShadow: isLocked
                ? null
                : [
                    BoxShadow(
                        color: AppColors.primary.withValues(alpha: 0.05),
                        blurRadius: 20),
                  ],
          ),
          child: Column(
            children: [
              Row(
                children: [
                  // Category icon
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: _iconBgColor(isLocked, isComplete),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      _categoryIcon(mission.category),
                      color: _iconColor(isLocked, isComplete),
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 14),

                  // Title + description
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(mission.title,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: isLocked
                                  ? AppColors.onSurfaceVariant
                                  : AppColors.onSurface,
                            )),
                        const SizedBox(height: 2),
                        Text(mission.description,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: AppColors.onSurfaceVariant,
                            )),
                      ],
                    ),
                  ),

                  // XP + status
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '+${mission.xpReward} XP',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: isComplete
                              ? AppColors.success
                              : AppColors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _StatusLabel(
                          isComplete: isComplete, isLocked: isLocked),
                    ],
                  ),
                ],
              ),

              const SizedBox(height: 14),

              // Progress bar
              Row(
                children: [
                  Expanded(
                    child: StepProgressBar(
                      progress: fraction,
                      height: 7,
                      showSpark: !isLocked && !isComplete,
                      startColor: isComplete ? AppColors.success : null,
                      endColor: isComplete ? AppColors.success : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    progress?.percentLabel ?? '0%',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),

              // Progress label
              if (progress != null && !isLocked) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    progress!.progressLabel,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  IconData _categoryIcon(MissionCategory cat) => switch (cat) {
        MissionCategory.steps => Icons.directions_walk,
        MissionCategory.battle => Icons.bolt,
        MissionCategory.streak => Icons.local_fire_department,
        MissionCategory.calories => Icons.whatshot,
      };

  Color _iconBgColor(bool locked, bool complete) {
    if (complete) return AppColors.success.withValues(alpha: 0.15);
    if (locked) return AppColors.onSurfaceVariant.withValues(alpha: 0.05);
    return AppColors.primary.withValues(alpha: 0.15);
  }

  Color _iconColor(bool locked, bool complete) {
    if (complete) return AppColors.success;
    if (locked) return AppColors.onSurfaceVariant;
    return AppColors.primary;
  }
}

class _StatusLabel extends StatelessWidget {
  final bool isComplete;
  final bool isLocked;

  const _StatusLabel({required this.isComplete, required this.isLocked});

  @override
  Widget build(BuildContext context) {
    final (label, color) = isComplete
        ? ('Completed \u2713', AppColors.success)
        : isLocked
            ? ('Locked', AppColors.onSurfaceVariant)
            : ('In Progress', AppColors.secondary);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!isComplete && !isLocked)
          Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.only(right: 4),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        if (isLocked)
          Padding(
            padding: const EdgeInsets.only(right: 3),
            child: Icon(Icons.lock, size: 10, color: color),
          ),
        Text(label,
            style: TextStyle(
              fontFamily: 'Manrope',
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: color,
              letterSpacing: 0.5,
            )),
      ],
    );
  }
}
