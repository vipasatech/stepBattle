import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../config/colors.dart';
import '../../providers/user_provider.dart';
import '../../sheets/streak_history_sheet.dart';
import '../../widgets/avatar_circle.dart';
import 'widgets/overview_card.dart';
import 'widgets/stat_pills_row.dart';
import 'widgets/active_battle_card.dart';
import 'widgets/daily_missions_section.dart';
import 'widgets/map_preview_card.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final streak = profile?.currentStreak ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Icon(Icons.bolt, color: AppColors.primaryBrand, size: 28),
            const SizedBox(width: 8),
            Text(
              'StepBattle',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: AppColors.primaryBrand,
                    fontWeight: FontWeight.w900,
                  ),
            ),
          ],
        ),
        actions: [
          // Streak badge
          GestureDetector(
            onTap: () => showModalBottomSheet(
              context: context,
              backgroundColor: Colors.transparent,
              builder: (_) => const StreakHistorySheet(),
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.local_fire_department,
                      color: AppColors.errorDim, size: 18),
                  const SizedBox(width: 4),
                  Text(
                    '$streak',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Profile avatar
          GestureDetector(
            onTap: () => context.push('/profile'),
            child: AvatarCircle(
              radius: 18,
              imageUrl: profile?.avatarURL,
              initials: _initials(profile?.displayName),
              borderColor: AppColors.outlineVariant,
              borderWidth: 1,
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: const _HomeBody(),
    );
  }

  static String _initials(String? name) {
    if (name == null || name.isEmpty) return '?';
    final parts = name.split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name[0].toUpperCase();
  }
}

class _HomeBody extends StatelessWidget {
  const _HomeBody();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
      children: const [
        // Section 1: Overview card + stat pills
        OverviewCard(),
        SizedBox(height: 12),
        StatPillsRow(),

        SizedBox(height: 32),

        // Section 2: Active Battle
        ActiveBattleCard(),

        SizedBox(height: 32),

        // Section 3: Daily Missions
        DailyMissionsSection(),

        SizedBox(height: 32),

        // Section 4: Map preview
        MapPreviewCard(),
      ],
    );
  }
}
