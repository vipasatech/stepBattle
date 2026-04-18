import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../config/colors.dart';
import '../../models/mission_model.dart';
import '../../providers/mission_provider.dart';
import '../../providers/stats_provider.dart';
import '../../providers/user_provider.dart';
import '../../sheets/mission_detail_sheet.dart';
import '../../widgets/avatar_circle.dart';
import 'widgets/daily_mission_card.dart';
import 'widgets/weekly_challenge_card.dart';

class MissionsScreen extends ConsumerWidget {
  const MissionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final missionStats = ref.watch(missionStatsProvider);
    final streak = profile?.currentStreak ?? 0;
    final initials = _initials(profile?.displayName);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Missions',
          style: theme.textTheme.headlineSmall?.copyWith(
            color: AppColors.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          // XP today pill (real)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.primaryBrand.withValues(alpha: 0.2),
              border: Border.all(
                  color: AppColors.primaryBrand.withValues(alpha: 0.3)),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '${missionStats.xpEarnedToday} XP today',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Streak (real)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.local_fire_department,
                    color: AppColors.errorDim, size: 18),
                const SizedBox(width: 4),
                Text('$streak',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => context.push('/profile'),
            child: AvatarCircle(
              radius: 16,
              imageUrl: profile?.avatarURL,
              initials: initials,
              borderColor: AppColors.outlineVariant,
              borderWidth: 1,
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: const _MissionsBody(),
    );
  }

  static String _initials(String? name) {
    if (name == null || name.isEmpty) return '?';
    final parts = name.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name[0].toUpperCase();
  }
}

class _MissionsBody extends ConsumerWidget {
  const _MissionsBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dailyMissions = ref.watch(dailyMissionsProvider);
    final weeklyMissions = ref.watch(weeklyMissionsProvider);
    final dailyProgress = ref.watch(dailyProgressProvider).valueOrNull ?? [];
    final weeklyProgress = ref.watch(weeklyProgressProvider).valueOrNull ?? [];

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
      children: [
        // Reset timer
        Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Row(
            children: [
              Icon(Icons.schedule, size: 14, color: AppColors.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                'Daily missions reset in 4h 22m',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),

        // ===== DAILY SECTION =====
        Text('Daily',
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),

        dailyMissions.when(
          loading: () => const Center(
              child:
                  CircularProgressIndicator(color: AppColors.primary)),
          error: (e, _) => Text('Error: $e'),
          data: (missions) => Column(
            children: missions.map((m) {
              final prog = findProgress(dailyProgress, m.missionId);
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: DailyMissionCard(
                  mission: m,
                  progress: prog,
                  onTap: () => _showDetail(context, m, prog),
                ),
              );
            }).toList(),
          ),
        ),

        const SizedBox(height: 32),

        // ===== WEEKLY SECTION =====
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text('Weekly',
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            Text('Resets Sunday',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.onSurfaceVariant)),
          ],
        ),
        const SizedBox(height: 16),

        weeklyMissions.when(
          loading: () => const Center(
              child:
                  CircularProgressIndicator(color: AppColors.primary)),
          error: (e, _) => Text('Error: $e'),
          data: (missions) => Column(
            children: missions.map((m) {
              final prog = findProgress(weeklyProgress, m.missionId);
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: WeeklyChallengeCard(
                  mission: m,
                  progress: prog,
                  onTap: () => _showDetail(context, m, prog),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  void _showDetail(BuildContext context, MissionModel mission,
      dynamic progress) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MissionDetailSheet(
        mission: mission,
        progress: progress,
      ),
    );
  }
}
