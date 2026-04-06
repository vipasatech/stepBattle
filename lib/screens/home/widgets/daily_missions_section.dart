import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../config/colors.dart';
import '../../../models/mission_model.dart';
import '../../../providers/mission_provider.dart';
import '../../../sheets/mission_detail_sheet.dart';
import '../../../widgets/progress_bar.dart';

/// Daily missions preview on Home — 3 mission rows with progress bars.
/// Wired to real mission providers.
class DailyMissionsSection extends ConsumerWidget {
  const DailyMissionsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final missions = ref.watch(dailyMissionsProvider);
    final progressList = ref.watch(dailyProgressProvider).valueOrNull ?? [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header
        GestureDetector(
          onTap: () => context.go('/missions'),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Daily Missions',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700)),
              Icon(Icons.chevron_right, color: AppColors.primary, size: 24),
            ],
          ),
        ),
        const SizedBox(height: 12),

        missions.when(
          loading: () => const SizedBox(
            height: 60,
            child: Center(
                child:
                    CircularProgressIndicator(color: AppColors.primary)),
          ),
          error: (_, __) => const Text('Could not load missions'),
          data: (missionList) {
            // Check if all completed
            final allComplete = missionList.isNotEmpty &&
                missionList.every((m) {
                  final prog = findProgress(progressList, m.missionId);
                  return prog?.isCompleted ?? false;
                });

            if (allComplete) {
              return Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.success.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: AppColors.success.withValues(alpha: 0.2)),
                ),
                child: Row(
                  children: [
                    const Text('\u2705', style: TextStyle(fontSize: 20)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'All missions complete! +150 XP earned today',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: AppColors.success,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }

            return Column(
              children: missionList.map((m) {
                final prog = findProgress(progressList, m.missionId);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _HomeMissionRow(
                    mission: m,
                    progress: prog?.progressFraction ?? 0.0,
                    isComplete: prog?.isCompleted ?? false,
                    isLocked: prog == null &&
                        m.category == MissionCategory.battle,
                    onTap: () {
                      showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        backgroundColor: Colors.transparent,
                        builder: (_) => MissionDetailSheet(
                          mission: m,
                          progress: prog,
                        ),
                      );
                    },
                  ),
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }
}

class _HomeMissionRow extends StatelessWidget {
  final MissionModel mission;
  final double progress;
  final bool isComplete;
  final bool isLocked;
  final VoidCallback? onTap;

  const _HomeMissionRow({
    required this.mission,
    required this.progress,
    required this.isComplete,
    required this.isLocked,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: isLocked ? 0.5 : 1.0,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isLocked
                ? AppColors.surfaceContainerLow
                : AppColors.glassBackground,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isLocked
                  ? AppColors.outlineVariant.withValues(alpha: 0.1)
                  : Colors.white.withValues(alpha: 0.05),
            ),
            boxShadow: isLocked
                ? null
                : [BoxShadow(color: AppColors.glassGlow, blurRadius: 4)],
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppColors.primary
                          .withValues(alpha: isLocked ? 0.05 : 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      _icon(mission.category),
                      color: isLocked
                          ? AppColors.onSurfaceVariant
                          : AppColors.primary,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(mission.title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: isLocked
                              ? AppColors.onSurfaceVariant
                              : AppColors.onSurface,
                        )),
                  ),
                  Text(
                    '+${mission.xpReward} XP',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: isComplete
                          ? AppColors.success
                          : AppColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              StepProgressBar(
                progress: progress,
                height: 6,
                showSpark: !isLocked && !isComplete,
                startColor: isComplete ? AppColors.success : null,
                endColor: isComplete ? AppColors.success : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _icon(MissionCategory cat) => switch (cat) {
        MissionCategory.steps => Icons.directions_walk,
        MissionCategory.battle => Icons.bolt,
        MissionCategory.streak => Icons.local_fire_department,
        MissionCategory.calories => Icons.whatshot,
      };
}
