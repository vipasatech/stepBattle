import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../config/colors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/user_provider.dart';
import '../../sheets/set_goal_sheet.dart';
import '../../sheets/streak_history_sheet.dart';
import 'widgets/user_identity_section.dart';
import 'widgets/this_week_stats.dart';
import 'widgets/all_time_stats.dart';
import 'widgets/account_details.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final profile = ref.watch(userProfileProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Profile',
            style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700)),
        actions: [
          // Streak badge
          GestureDetector(
            onTap: () => _showStreakHistory(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.2)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.local_fire_department,
                      color: AppColors.tertiary, size: 16),
                  const SizedBox(width: 4),
                  Text('${profile?.currentStreak ?? 0}',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: profile == null
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary))
          : ListView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 120),
              children: [
                // Section 1: User identity
                UserIdentitySection(user: profile),

                const SizedBox(height: 28),

                // Section 2: Set Goal button
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: OutlinedButton(
                    onPressed: () => _showSetGoal(context, profile.dailyStepGoal),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(
                          color: AppColors.primary.withValues(alpha: 0.5)),
                      foregroundColor: AppColors.primary,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('Set Goal',
                            style: theme.textTheme.labelLarge
                                ?.copyWith(color: AppColors.primary)),
                        const SizedBox(width: 8),
                        const Icon(Icons.arrow_forward, size: 18),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 28),

                // Section 3: This Week
                const ThisWeekStats(),

                const SizedBox(height: 28),

                // Section 4: All Time
                AllTimeStats(user: profile),

                const SizedBox(height: 28),

                // Section 5: Account
                AccountDetails(user: profile),

                const SizedBox(height: 28),

                // Section 6: Sign out
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: OutlinedButton.icon(
                    onPressed: () => _showSignOutDialog(context, ref),
                    icon: const Icon(Icons.logout, size: 18),
                    label: const Text('Sign Out'),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(
                          color: AppColors.error.withValues(alpha: 0.3)),
                      foregroundColor: AppColors.error,
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  void _showSetGoal(BuildContext context, int currentGoal) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SetGoalSheet(currentGoal: currentGoal),
    );
  }

  void _showStreakHistory(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const StreakHistorySheet(),
    );
  }

  void _showSignOutDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainerHigh,
        title: const Text('Sign Out'),
        content: const Text('Are you sure you want to sign out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await ref.read(authServiceProvider).signOut();
            },
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
  }
}
