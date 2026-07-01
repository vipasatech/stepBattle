import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../config/colors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/friend_provider.dart';
import '../../providers/step_provider.dart';
import '../../providers/theme_mode_provider.dart';
import '../../providers/user_provider.dart';
import '../../services/step_source_aggregator.dart';
import '../../models/avatar.dart';
import '../../models/user_model.dart';
import '../../sheets/add_friends_sheet.dart';
import '../../sheets/avatar_picker_sheet.dart';
import '../../sheets/edit_survey_sheet.dart';
import '../../sheets/set_goal_sheet.dart';
import '../../sheets/set_home_sheet.dart';
import '../../sheets/streak_history_sheet.dart';
import 'widgets/user_identity_section.dart';
import 'widgets/this_week_trend_chart.dart';
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
          // Streak badge — flame + border both tinted the same deep
          // orange the Home tab's StreakStrip uses (`0xFFD97706`), so
          // the streak signal reads the same across pages regardless
          // of theme.
          GestureDetector(
            onTap: () => _showStreakHistory(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                    color: const Color(0xFFD97706).withValues(alpha: 0.25)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.local_fire_department,
                      color: Color(0xFFD97706), size: 16),
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
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.person_off,
                        size: 48,
                        color: AppColors.onSurfaceVariant
                            .withValues(alpha: 0.4)),
                    const SizedBox(height: 16),
                    Text(
                      'Profile not set up yet',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Complete onboarding to set up your profile',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: AppColors.onSurfaceVariant),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: () {
                        ref.invalidate(hasCompletedOnboardingProvider);
                        Navigator.of(context).pop();
                      },
                      icon: const Icon(Icons.arrow_forward, size: 18),
                      label: const Text('Go to Onboarding'),
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              // Horizontal padding lives PER-ITEM (see `_pad`) instead
              // of on the ListView so the trend chart can run
              // edge-to-edge while every other section stays inside
              // the 24 dp inset.
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 120),
              children: [
                // Section 1: User identity
                _pad(UserIdentitySection(user: profile)),

                const SizedBox(height: 28),

                // Section 2: Set Goal button
                _pad(SizedBox(
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
                )),

                const SizedBox(height: 28),

                // Your Code section (share with friends)
                _pad(_YourCodeSection(userCode: profile.userCode)),

                const SizedBox(height: 20),

                // Friends — live count + pending badge, opens Friends Hub
                _pad(_FriendsTile()),

                const SizedBox(height: 28),

                // Section 3: This Week — step trendline chart.
                // Rendered unpadded so the chart body runs to the
                // screen edges; the widget's own header re-adds the
                // 24 dp inset so its title aligns with the other
                // section headers.
                const ThisWeekTrendChart(),

                const SizedBox(height: 28),

                // Section 4: All Time
                _pad(AllTimeStats(user: profile)),

                const SizedBox(height: 28),

                // Section 5: Account
                _pad(AccountDetails(user: profile)),

                const SizedBox(height: 20),

                // Home district — view + change. Surfaces unset state too.
                _HomeDistrictTile(),

                const SizedBox(height: 8),

                // Survey edit — DOB / gender / fitness level. Recomputes
                // the daily-step-goal recommendation on save and offers
                // to adopt it.
                _EditSurveyTile(),

                const SizedBox(height: 8),

                // Battle-ground runner picker — opens [AvatarPickerSheet].
                _BattleAvatarTile(),

                const SizedBox(height: 8),

                // Step Sources diagnostic — for users on OEMs where Health
                // Connect isn't getting fed (Realme/Motorola) so they can
                // see exactly which source is producing their step count.
                _StepSourcesTile(),

                const SizedBox(height: 8),

                // Light/dark/system theme switcher.
                _ThemeModeTile(),

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

  /// Wrap a Profile-body child in the standard 24 dp horizontal inset.
  /// Kept as a helper so the ListView's own padding stays 0 and the
  /// trend chart can opt out to run edge-to-edge.
  Widget _pad(Widget child) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: child,
      );

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

// =============================================================================
// Theme-mode tile — 3-segment toggle (System / Light / Dark). The choice
// is persisted via [themeModePrefProvider]; MaterialApp picks up the new
// value automatically and rebuilds with the matching ThemeData.
// =============================================================================
class _ThemeModeTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final mode = ref.watch(themeModePrefProvider);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.onSurface.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.dark_mode_outlined,
                    color: AppColors.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Appearance',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    Text(_subtitleFor(mode),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                        )),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(
                value: ThemeMode.system,
                label: Text('System'),
                icon: Icon(Icons.brightness_auto, size: 16),
              ),
              ButtonSegment(
                value: ThemeMode.light,
                label: Text('Light'),
                icon: Icon(Icons.light_mode, size: 16),
              ),
              ButtonSegment(
                value: ThemeMode.dark,
                label: Text('Dark'),
                icon: Icon(Icons.dark_mode, size: 16),
              ),
            ],
            selected: {mode},
            showSelectedIcon: false,
            onSelectionChanged: (set) =>
                ref.read(themeModePrefProvider.notifier).set(set.first),
          ),
        ],
      ),
    );
  }

  static String _subtitleFor(ThemeMode m) => switch (m) {
        ThemeMode.system => 'Match phone setting',
        ThemeMode.light => 'Always light',
        ThemeMode.dark => 'Always dark',
      };
}

// =============================================================================
// Step Sources tiles — diagnostics + setup guide
// =============================================================================
class _StepSourcesTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reading =
        ref.watch(stepAggregatorProvider).lastReading;
    final winner = _winnerLabel(reading);

    return Column(
      children: [
        _ProfileLinkTile(
          icon: Icons.directions_walk,
          title: 'How my steps are tracked',
          subtitle: winner == null
              ? 'See per-source live values and diagnose 0-step issues'
              : 'Source: $winner — tap for live values',
          route: '/profile/step-sources',
        ),
        const SizedBox(height: 8),
        _ProfileLinkTile(
          icon: Icons.tune,
          title: 'Step tracking setup guide',
          subtitle:
              'Tailored instructions for your phone — Samsung, Realme, etc.',
          route: '/profile/health-setup',
        ),
      ],
    );
  }

  String? _winnerLabel(StepReading? r) {
    if (r == null || r.aggregate <= 0) return null;
    final fit = r.googleFitSteps ?? -1;
    if (fit >= r.aggregate && fit > 0) return 'Google Fit';
    if (r.healthConnectSteps == r.aggregate) return 'Health Connect';
    return 'Phone hardware sensor';
  }
}

class _ProfileLinkTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String route;

  const _ProfileLinkTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.route,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => context.push(route),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border:
                Border.all(color: AppColors.onSurface.withValues(alpha: 0.05)),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: AppColors.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    Text(subtitle,
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: AppColors.onSurfaceVariant)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right,
                  color: AppColors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Battle avatar tile — shows the user's chosen battle-ground runner.
// Tap opens [AvatarPickerSheet] for browsing/changing the catalog.
// =============================================================================
// =============================================================================
// Survey-edit tile — opens [EditSurveySheet] to update DOB / gender /
// fitness level. Shows the current values inline.
// =============================================================================
class _EditSurveyTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final me = ref.watch(currentUserProvider).valueOrNull;
    final age = me?.age;
    final genderLabel = _genderLabel(me?.gender);
    final fitnessLabel = _fitnessLabel(me?.fitnessLevel);

    // Summary line: "27 · Man · Advanced". Falls back gracefully when
    // any of the three is missing (pre-survey or partial data).
    final parts = <String>[
      if (age != null) '$age',
      if (genderLabel != null) genderLabel,
      if (fitnessLabel != null) fitnessLabel,
    ];
    final summary =
        parts.isEmpty ? 'Tap to add' : parts.join('  ·  ');

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => showEditSurveySheet(context),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border:
                Border.all(color: AppColors.onSurface.withValues(alpha: 0.05)),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.fact_check_outlined,
                    color: AppColors.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Personal info',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right,
                  color: AppColors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  static String? _genderLabel(Gender? g) => switch (g) {
        Gender.man => 'Man',
        Gender.woman => 'Woman',
        Gender.nonBinary => 'Non-binary',
        Gender.preferNotToSay => 'Private',
        null => null,
      };

  static String? _fitnessLabel(FitnessLevel? f) => switch (f) {
        FitnessLevel.beginner => 'Beginner',
        FitnessLevel.intermediate => 'Intermediate',
        FitnessLevel.advanced => 'Advanced',
        FitnessLevel.pro => 'Pro',
        null => null,
      };
}

class _BattleAvatarTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final me = ref.watch(currentUserProvider).valueOrNull;
    final avatar = Avatar.byId(me?.battleAvatarId);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => showAvatarPickerSheet(context),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border:
                Border.all(color: AppColors.onSurface.withValues(alpha: 0.05)),
          ),
          child: Row(
            children: [
              // Live preview of the currently-selected runner.
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.all(2),
                child: Image.asset(
                  avatar.assetPath,
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Battle avatar',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    Text('Tap to change · ${avatar.label}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                        )),
                  ],
                ),
              ),
              Icon(Icons.chevron_right,
                  color: AppColors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Home district tile — shows current home (or unset state with Set CTA).
// Tap opens [SetHomeSheet] for both first-time setup and changes.
// =============================================================================
class _HomeDistrictTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final user = ref.watch(userProfileProvider).valueOrNull;
    if (user == null) return const SizedBox();
    final hasHome = user.hasHome;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _open(context),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: hasHome
                  ? AppColors.onSurface.withValues(alpha: 0.05)
                  : AppColors.amber.withValues(alpha: 0.4),
              width: hasHome ? 1 : 1.5,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: (hasHome ? AppColors.primary : AppColors.amber)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  hasHome ? Icons.home : Icons.home_outlined,
                  color: hasHome ? AppColors.primary : AppColors.amber,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      hasHome ? 'Home district' : 'Set home district',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      hasHome
                          ? _summary(user)
                          : 'Unlock local leaderboards + the cinematic map',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: hasHome
                            ? AppColors.onSurfaceVariant
                            : AppColors.amber,
                        fontWeight:
                            hasHome ? FontWeight.w500 : FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right,
                  color: AppColors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  void _open(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const SetHomeSheet(),
    );
  }

  String _summary(user) {
    final district = user.districtName as String?;
    final state = user.stateName as String?;
    final country = user.countryName as String?;
    final parts = <String>[
      if (district != null && district.isNotEmpty) district,
      if (state != null && state.isNotEmpty) state,
      if (country != null && country.isNotEmpty) country,
    ];
    return parts.join(' · ');
  }
}

// =============================================================================
// Your Code section — share your userCode with friends
// =============================================================================
class _YourCodeSection extends StatelessWidget {
  final String userCode;

  const _YourCodeSection({required this.userCode});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (userCode.isEmpty) return const SizedBox();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Your Code',
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.2),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      userCode,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text('Share with friends to add you',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                        )),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Icons.copy, color: AppColors.primary),
                tooltip: 'Copy',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: userCode));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Code copied!')),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Friends tile — live friends count + pending badge.
// Tap opens the Friends Hub on the Friends tab (or Requests if pending).
// =============================================================================
class _FriendsTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final friendCount = ref.watch(friendsListProvider).valueOrNull?.length ?? 0;
    final pendingCount = ref.watch(incomingRequestCountProvider);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          useRootNavigator: true,
          backgroundColor: Colors.transparent,
          builder: (_) => AddFriendsSheet(
            mode: FriendsSheetMode.manage,
            // Land on Requests when there's something to act on; otherwise
            // start on the Friends list.
            initialTab: pendingCount > 0 ? 2 : 0,
          ),
        ),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: pendingCount > 0
                  ? AppColors.primary.withValues(alpha: 0.4)
                  : AppColors.onSurface.withValues(alpha: 0.05),
              width: pendingCount > 0 ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.group, color: AppColors.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Friends',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    Text(
                      _subtitle(friendCount, pendingCount),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: pendingCount > 0
                            ? AppColors.primary
                            : AppColors.onSurfaceVariant,
                        fontWeight: pendingCount > 0
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              if (pendingCount > 0) ...[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    pendingCount > 9 ? '9+' : '$pendingCount',
                    style: const TextStyle(
                      color: AppColors.onPrimary,
                      fontWeight: FontWeight.w900,
                      fontSize: 11,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Icon(Icons.chevron_right,
                  color: AppColors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  static String _subtitle(int friends, int pending) {
    if (pending > 0) {
      return '$friends friend${friends == 1 ? '' : 's'} • '
          '$pending pending request${pending == 1 ? '' : 's'}';
    }
    if (friends == 0) return 'No friends yet • tap to add';
    return '$friends friend${friends == 1 ? '' : 's'}';
  }
}
