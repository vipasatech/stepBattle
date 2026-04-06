import 'package:flutter/material.dart';
import '../config/colors.dart';
import '../models/mission_model.dart';
import '../models/user_mission_progress_model.dart';
import '../widgets/bottom_sheet_handle.dart';
import '../widgets/glass_card.dart';
import '../widgets/progress_bar.dart';

/// Full mission detail sheet — triggered by tapping any mission card.
class MissionDetailSheet extends StatelessWidget {
  final MissionModel mission;
  final UserMissionProgress? progress;

  const MissionDetailSheet({
    super.key,
    required this.mission,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = progress?.progressFraction ?? 0.0;
    final isComplete = progress?.isCompleted ?? false;

    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: const BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
          children: [
            const BottomSheetHandle(),

            // Hero: icon + title + status
            Center(
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: AppColors.primary.withValues(alpha: 0.3)),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.4),
                      blurRadius: 25,
                    ),
                  ],
                ),
                child: Icon(
                  _categoryIcon(mission.category),
                  color: AppColors.primary,
                  size: 30,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                mission.title,
                style: theme.textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: isComplete
                      ? AppColors.success.withValues(alpha: 0.1)
                      : AppColors.amber.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isComplete
                        ? AppColors.success.withValues(alpha: 0.2)
                        : AppColors.amber.withValues(alpha: 0.2),
                  ),
                ),
                child: Text(
                  isComplete ? 'COMPLETED \u2713' : 'IN PROGRESS',
                  style: TextStyle(
                    fontFamily: 'Manrope',
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: isComplete ? AppColors.success : AppColors.amber,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 28),

            // Progress card
            GlassCard(
              padding: const EdgeInsets.all(18),
              borderRadius: 20,
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('CURRENT PROGRESS',
                              style: theme.textTheme.labelSmall?.copyWith(
                                  color: AppColors.onSurfaceVariant,
                                  letterSpacing: 1.5)),
                          const SizedBox(height: 4),
                          Text(
                            progress?.progressLabel ??
                                '0 / ${mission.targetValue}',
                            style: theme.textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                      Text(
                        progress?.percentLabel ?? '0%',
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  StepProgressBar(
                    progress: fraction,
                    height: 10,
                    showSpark: !isComplete,
                    startColor: isComplete ? AppColors.success : null,
                    endColor: isComplete ? AppColors.success : null,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Detail grid (2x2)
            Row(
              children: [
                Expanded(
                  child: _DetailItem(
                    label: 'XP Reward',
                    icon: Icons.military_tech,
                    iconColor: AppColors.success,
                    value: '+${mission.xpReward} XP',
                    valueColor: AppColors.success,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _DetailItem(
                    label: 'Resets In',
                    icon: Icons.schedule,
                    iconColor: AppColors.amber,
                    value: mission.type == MissionType.daily
                        ? '4h 22m'
                        : 'Sunday',
                    valueColor: AppColors.amber,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _DetailItem(
                    label: 'Category',
                    icon: Icons.calendar_today,
                    iconColor: AppColors.primary,
                    value: mission.type == MissionType.daily
                        ? 'Daily Mission'
                        : 'Weekly Challenge',
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _DetailItem(
                    label: 'Difficulty',
                    icon: Icons.grade,
                    iconColor: AppColors.primary,
                    value: _difficultyLabel(mission.difficulty),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 28),

            // How it works
            Text('How it works',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerHigh.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                'StepBattle automatically tracks your movement using your device\'s '
                'pedometer. You can also sync data from Apple Health or Google Fit '
                'to ensure every step in your daily routine contributes to your '
                'competitive standing.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.onSurfaceVariant,
                  height: 1.6,
                ),
              ),
            ),

            const SizedBox(height: 28),

            // CTA button
            SizedBox(
              width: double.infinity,
              height: 56,
              child: isComplete
                  ? FilledButton.icon(
                      onPressed: null,
                      icon: const Icon(Icons.check, size: 20),
                      label:
                          Text('Completed \u2713 · +${mission.xpReward} XP Earned'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.success,
                        disabledBackgroundColor:
                            AppColors.success.withValues(alpha: 0.6),
                        disabledForegroundColor: Colors.white,
                      ),
                    )
                  : FilledButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.directions_walk, size: 20),
                      label: const Text('Go Walk Now'),
                    ),
            ),
          ],
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

  String _difficultyLabel(String d) => switch (d) {
        'hard' => '\u2B50 Hard',
        'medium' => '\u2B50 Medium',
        _ => '\u2B50 Easy',
      };
}

class _DetailItem extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color iconColor;
  final String value;
  final Color? valueColor;

  const _DetailItem({
    required this.label,
    required this.icon,
    required this.iconColor,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant, letterSpacing: 1.5)),
        const SizedBox(height: 6),
        Row(
          children: [
            Icon(icon, size: 18, color: iconColor),
            const SizedBox(width: 6),
            Text(value,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: valueColor ?? AppColors.onSurface,
                  fontWeight: FontWeight.w700,
                )),
          ],
        ),
      ],
    );
  }
}
