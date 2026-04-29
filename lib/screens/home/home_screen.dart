import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../config/colors.dart';
import '../../providers/notification_provider.dart';
import '../../providers/user_provider.dart';
import '../../sheets/notifications_sheet.dart';
import '../../sheets/streak_history_sheet.dart';
import '../../widgets/avatar_circle.dart';
import '../../widgets/friends_app_bar_button.dart';
import '../../widgets/no_steps_banner.dart';
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
    final unreadCount = ref.watch(unreadNotificationCountProvider);

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
          // Friends hub with badge for pending incoming requests
          const FriendsAppBarButton(),
          const SizedBox(width: 8),
          // Notification bell with badge
          _BellButton(unreadCount: unreadCount),
          const SizedBox(width: 8),
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
          const SizedBox(width: 8),
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

class _BellButton extends StatelessWidget {
  final int unreadCount;
  const _BellButton({required this.unreadCount});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        useRootNavigator: true,
        backgroundColor: Colors.transparent,
        builder: (_) => const NotificationsSheet(),
      ),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            const Icon(Icons.notifications_outlined,
                color: AppColors.onSurface, size: 20),
            if (unreadCount > 0)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  constraints:
                      const BoxConstraints(minWidth: 16, minHeight: 16),
                  decoration: BoxDecoration(
                    color: AppColors.error,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: AppColors.background, width: 1.5),
                  ),
                  child: Text(
                    unreadCount > 9 ? '9+' : '$unreadCount',
                    style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HomeBody extends StatelessWidget {
  const _HomeBody();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
      children: const [
        // Auto-diagnostic banner — only renders when every step source
        // has been failing/empty for 10+ minutes. Self-suppressing if
        // dismissed or once steps start flowing.
        NoStepsBanner(),

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
