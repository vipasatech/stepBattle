import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../config/colors.dart';
import '../../models/avatar.dart';
import '../../providers/auth_provider.dart';
import '../../providers/user_provider.dart';
import '../../sheets/add_friends_sheet.dart';
import '../../sheets/avatar_picker_sheet.dart';
import '../../sheets/edit_survey_sheet.dart';
import '../../widgets/mount_stagger.dart';
import '../../widgets/qr_share_sheet.dart';
import 'widgets/all_time_stats.dart';
import 'widgets/profile_stats_strip.dart';
import 'widgets/this_week_trend_chart.dart';
import 'widgets/user_identity_section.dart';

/// Strava-style profile: identity header, 5-stat pill strip, action
/// buttons, this-week chart, then a compact row-list of navigation
/// entries.
///
/// Subscription / streak history / step-tracking config all moved to
/// the dedicated Settings screen at `/settings`. What lives here is
/// only the stuff you'd want to see AT A GLANCE about yourself.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final profile = ref.watch(userProfileProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            tooltip: 'Search friends',
            icon: const Icon(Icons.search),
            onPressed: () => _openFriendsSearch(context),
          ),
          IconButton(
            tooltip: 'Share profile',
            icon: const Icon(Icons.ios_share),
            onPressed: () => _shareProfile(profile?.userCode),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/settings'),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: profile == null
          ? _EmptyState(theme: theme, ref: ref)
          : ListView(
              // Bottom padding: clears the shell nav bar (~90 dp on
              // Samsung) with ~40 dp of breathing room so the last
              // card's bottom border stays visible above the nav bar
              // instead of tucking right against it.
              padding: const EdgeInsets.fromLTRB(0, 4, 0, 130),
              children: [
                // MountStagger reveals each Profile section with a
                // fade+slide on first mount. Sub-widget instances
                // stay identity-stable across Riverpod ticks, so
                // profile refreshes don't replay the stagger.
                // Bottom spacers are baked into each block's Padding.
                MountStagger(
                  animateCount: 5,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(bottom: 30),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: UserIdentitySection(user: profile),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 44),
                      child: ProfileStatsStrip(user: profile),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 44),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: _ActionsRow(userCode: profile.userCode),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(bottom: 32),
                      child: ThisWeekTrendChart(),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _ProfileRowList(user: profile),
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  static void _openFriendsSearch(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const AddFriendsSheet(
        mode: FriendsSheetMode.manage,
        initialTab: 1, // Search tab
      ),
    );
  }

  static Future<void> _shareProfile(String? userCode) async {
    if (userCode == null || userCode.isEmpty) return;
    await Share.share(
      'Add me on StepBattle: $userCode',
      subject: 'My StepBattle code',
    );
  }
}

class _EmptyState extends StatelessWidget {
  final ThemeData theme;
  final WidgetRef ref;
  const _EmptyState({required this.theme, required this.ref});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.person_off,
                size: 48,
                color: AppColors.onSurfaceVariant.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            Text(
              'Profile not set up yet',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
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
    );
  }
}

/// The two action pills below the identity header: Share QR + Edit.
///
/// - Share QR opens [showQrShareSheet] with the user's code
/// - Edit opens the existing [showEditSurveySheet] — the consolidated
///   "personal info" edit surface for DOB / gender / fitness / home
///   district. The standalone Personal Info card that used to live
///   further down the profile scroll has been removed since this
///   button replaces its entry point.
class _ActionsRow extends StatelessWidget {
  final String userCode;
  const _ActionsRow({required this.userCode});

  @override
  Widget build(BuildContext context) {
    // Compact pill styling matching Strava's Share/Edit buttons —
    // thin border, small icon, tight vertical padding, ~13 sp label.
    final style = OutlinedButton.styleFrom(
      foregroundColor: AppColors.primary,
      side: BorderSide(
        color: AppColors.primary.withValues(alpha: 0.5),
        width: 1,
      ),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
      minimumSize: const Size(0, 34),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(999),
      ),
      textStyle: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.1,
      ),
    );
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: userCode.isEmpty
                ? null
                : () => showQrShareSheet(context, userCode: userCode),
            icon: const Icon(Icons.qr_code_2, size: 15),
            label: const Text('Share my QR Code'),
            style: style,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => showEditSurveySheet(context),
            icon: const Icon(Icons.edit_outlined, size: 15),
            label: const Text('Edit'),
            style: style,
          ),
        ),
      ],
    );
  }
}

/// Row-list navigation replacing all the standalone tiles that used to
/// dominate the bottom of Profile. Ordering matches the plan:
///   Battles → jumps to the Battles tab
///   All-time stats → expands inline
///   Battle Avatar → opens the picker (existing)
class _ProfileRowList extends ConsumerWidget {
  final dynamic user;
  const _ProfileRowList({required this.user});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        _RowNav(
          // Same crossed-swords glyph the bottom-nav Battles tab
          // uses (MdiIcons.swordCross) — keeps the "Battles" signal
          // identical across the shell nav and this profile row.
          icon: MdiIcons.swordCross,
          title: 'Battles',
          subtitle: 'Your current and past battles',
          onTap: () {
            // Pop the pushed Profile route, then swap the shell into
            // its Battles branch. `.go` from inside the shell handles
            // the branch switch correctly.
            Navigator.of(context).pop();
            context.go('/battles');
          },
        ),
        const SizedBox(height: 14),
        _AllTimeExpansionTile(user: user),
        const SizedBox(height: 14),
        _BattleAvatarRow(user: user),
      ],
    );
  }
}

class _RowNav extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final Widget? leading;

  const _RowNav({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
    this.leading,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: AppColors.onSurface.withValues(alpha: 0.05),
            ),
          ),
          child: Row(
            children: [
              leading ??
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
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Text(subtitle!,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: AppColors.onSurfaceVariant,
                          )),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: AppColors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// Expansion tile whose collapsed state matches [_RowNav] visually
/// so the two blend seamlessly. Expanded → embeds [AllTimeStats].
class _AllTimeExpansionTile extends StatelessWidget {
  final dynamic user;
  const _AllTimeExpansionTile({required this.user});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.onSurface.withValues(alpha: 0.05),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        // Strip ExpansionTile's default divider so it doesn't fight
        // with our rounded outer border.
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.query_stats, color: AppColors.primary),
          ),
          title: Text('All-time stats',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          subtitle: Text('Steps, XP, wins — since day one',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant,
              )),
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          children: [AllTimeStats(user: user)],
        ),
      ),
    );
  }
}

class _BattleAvatarRow extends ConsumerWidget {
  final dynamic user;
  const _BattleAvatarRow({required this.user});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final avatar = Avatar.byId(user?.battleAvatarId);
    return _RowNav(
      icon: Icons.sports_kabaddi,
      title: 'Battle avatar',
      subtitle: 'Tap to change · ${avatar.label}',
      onTap: () => showAvatarPickerSheet(context),
      leading: Container(
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
    );
  }
}
