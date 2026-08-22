import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/motion.dart';

import '../../config/colors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/theme_mode_provider.dart';
import '../../providers/user_provider.dart';
import '../../sheets/change_email_sheet.dart';
import '../../sheets/delete_account_sheet.dart';
import '../../sheets/edit_phone_sheet.dart';
import '../../sheets/edit_survey_sheet.dart';
import '../../sheets/redeem_referral_sheet.dart';
import '../profile/widgets/subscription_section.dart';

/// Full settings surface — grouped, iOS/Strava-style. Every row does
/// real work now: system permissions open the OS panel, notification
/// switches persist to `profiles.notif_*`, email / phone / delete
/// each open a dedicated sheet.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // Narrow the profile watch to only the fields SettingsScreen
    // actually reads. Before this, the full-row `ref.watch(userProfileProvider)`
    // rebuilt the entire ListView (~20 rows + 4 NotifToggleRows) on
    // every profile emit — and profile emits every time a step sync
    // updates `total_steps_all_time`. That mid-scroll rebuild storm
    // was the sole cause of Settings-tab scroll stutter; every other
    // tab is smooth.
    //
    // Riverpod's `.select` compares its output with `==`; Dart records
    // have structural equality, so watchers only rebuild when one of
    // the listed fields actually changes value. All of these fields
    // are essentially immutable during a session (userId, email,
    // userCode) or change only through explicit user action (phone,
    // age, gender, fitnessLevel) — none of them are touched by step
    // syncs, XP awards, or other high-frequency traffic.
    final settingsFields = ref.watch(
      userProfileProvider.select((async) {
        final p = async.valueOrNull;
        if (p == null) return null;
        return (
          userId: p.userId,
          email: p.email,
          phone: p.phone,
          userCode: p.userCode,
          age: p.age,
          gender: p.gender,
          fitnessLevel: p.fitnessLevel,
          preferredName: p.preferredName,
        );
      }),
    );
    final phoneLabel = (settingsFields?.phone?.isNotEmpty ?? false)
        ? settingsFields!.phone
        : 'Not set';

    return Scaffold(
      appBar: AppBar(
        // Title moved into the AppBar to match the shell-tab surfaces
        // (Leaderboards, Battles, Track) instead of the big in-body
        // headline it used to be. Consistent titling across every
        // top-level screen; also frees the vertical space the old
        // headline used up.
        centerTitle: true,
        title: Text(
          'Settings',
          style: theme.textTheme.headlineSmall?.copyWith(
            color: AppColors.onSurface,
            fontWeight: FontWeight.w700,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        // Bottom padding: clears the shell nav (~90 dp) + ~40 dp of
        // breathing room so the last card / row stays visibly above
        // the nav bar. Matches the Profile screen's spacing. Small
        // top padding so the first `_SettingsGroup` isn't jammed
        // against the AppBar now that the in-body headline is gone.
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 130),
        // Pre-inflate ~800 dp past the viewport so section groups
        // further down the settings list are ready before they
        // scroll into view. Matches Home / Battles / Ranks. Sections
        // are small (rows are ~60 dp) so 800 dp gets us ~13 rows
        // ahead — comfortable for a fast flick.
        cacheExtent: 800,
        children: [
          _SettingsGroup(
            title: 'Account',
            children: [
              _SettingsRow(
                icon: Icons.person_outline,
                title: 'Personal info',
                subtitle: settingsFields == null
                    ? null
                    : _summariseSurveyFields(
                        age: settingsFields.age,
                        gender: settingsFields.gender,
                        fitnessLevel: settingsFields.fitnessLevel,
                      ),
                onTap: () => showEditSurveySheet(context),
              ),
              // Dedicated Preferred Name row so users who skipped the
              // nickname step during onboarding can add / change it
              // later without hunting inside Personal info. Opens the
              // same edit-survey sheet (which already has the field);
              // subtitle shows the current value or a hint if unset.
              _SettingsRow(
                icon: Icons.badge_outlined,
                title: 'Preferred name',
                subtitle: (settingsFields?.preferredName?.trim().isNotEmpty ??
                        false)
                    ? settingsFields!.preferredName!.trim()
                    : 'Add a nickname others see',
                onTap: () => showEditSurveySheet(context),
              ),
              if (settingsFields?.userCode.isNotEmpty ?? false)
                _SettingsRow(
                  icon: Icons.tag,
                  title: 'User code',
                  subtitle: settingsFields!.userCode,
                  onTap: () => _copy(context, settingsFields.userCode),
                ),
              _SettingsRow(
                icon: Icons.alternate_email,
                title: 'Email',
                subtitle: settingsFields?.email,
                onTap: () => showChangeEmailSheet(context),
              ),
              _SettingsRow(
                icon: Icons.phone_outlined,
                title: 'Phone number',
                subtitle: phoneLabel,
                onTap: () => showEditPhoneSheet(context),
              ),
            ],
          ),

          const _SectionSpacer(),

          _SettingsGroup(
            title: 'Subscription',
            children: const [
              Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: SubscriptionSection(),
              ),
            ],
          ),

          const _SectionSpacer(),

          _SettingsGroup(
            title: 'Step tracking',
            children: [
              _SettingsRow(
                icon: Icons.directions_walk,
                title: 'How my steps are tracked',
                subtitle: 'See per-source live values + diagnose issues',
                onTap: () => context.push('/profile/step-sources'),
              ),
              _SettingsRow(
                icon: Icons.tune,
                title: 'Step tracking setup guide',
                subtitle: 'Tailored instructions for your phone',
                onTap: () => context.push('/profile/health-setup'),
              ),
            ],
          ),

          const _SectionSpacer(),

          _SettingsGroup(
            title: 'Notifications',
            children: [
              _SettingsRow(
                icon: Icons.notifications_active_outlined,
                title: 'System permission',
                subtitle: 'Manage in phone settings',
                onTap: () async {
                  await openAppSettings();
                },
              ),
              _NotifToggleRow(
                icon: Icons.notifications_outlined,
                title: 'Push notifications',
                subtitle: 'Battle updates, missions, friends',
                column: 'notif_push',
                selector: (p) => p.notifPush,
                userId: settingsFields?.userId,
              ),
              _NotifToggleRow(
                icon: Icons.mail_outline,
                title: 'Email notifications',
                subtitle: 'Weekly recap, receipts, security',
                column: 'notif_email',
                selector: (p) => p.notifEmail,
                userId: settingsFields?.userId,
              ),
              _NotifToggleRow(
                icon: Icons.sports_kabaddi,
                title: 'Battle result alerts',
                subtitle: 'Ping when a battle you\'re in ends',
                column: 'notif_battles',
                selector: (p) => p.notifBattles,
                userId: settingsFields?.userId,
              ),
              _NotifToggleRow(
                icon: Icons.person_add_alt_1,
                title: 'Friend request alerts',
                column: 'notif_friends',
                selector: (p) => p.notifFriends,
                userId: settingsFields?.userId,
              ),
            ],
          ),

          const _SectionSpacer(),

          _SettingsGroup(
            title: 'Permissions',
            children: [
              _SettingsRow(
                icon: Icons.directions_run,
                title: 'Activity recognition',
                subtitle: 'Required for step counting',
                onTap: () async => openAppSettings(),
              ),
              _SettingsRow(
                icon: Icons.contacts_outlined,
                title: 'Contacts access',
                subtitle: 'Find friends who already use StepBattle',
                onTap: () async {
                  final status = await Permission.contacts.status;
                  if (status.isPermanentlyDenied) {
                    await openAppSettings();
                    return;
                  }
                  await Permission.contacts.request();
                },
              ),
              _SettingsRow(
                icon: Icons.location_on_outlined,
                title: 'Location',
                subtitle: 'Track outdoor sessions with GPS',
                onTap: () async => openAppSettings(),
              ),
              _SettingsRow(
                icon: Icons.favorite_border,
                title: 'Health Connect',
                subtitle: Platform.isIOS
                    ? 'Not applicable on iOS'
                    : 'Read steps + calories',
                onTap: () async {
                  if (Platform.isIOS) return;
                  // Try Health Connect deep link; if the app isn't
                  // installed, Play Store listing is the fallback.
                  final hcUri = Uri.parse(
                    'market://details?id=com.google.android.apps.healthdata',
                  );
                  if (await canLaunchUrl(hcUri)) {
                    await launchUrl(hcUri);
                  } else {
                    await openAppSettings();
                  }
                },
              ),
            ],
          ),

          const _SectionSpacer(),

          _SettingsGroup(
            title: 'Rewards',
            children: [
              _SettingsRow(
                icon: Icons.card_giftcard_outlined,
                title: 'Redeem referral code',
                subtitle: 'Enter a friend\'s code — earn 50 XP each',
                onTap: () => showRedeemReferralSheet(context),
              ),
            ],
          ),

          const _SectionSpacer(),

          _SettingsGroup(
            title: 'Appearance',
            children: const [_ThemePickerRow()],
          ),

          const _SectionSpacer(),

          _SettingsGroup(
            title: 'Support & About',
            children: [
              _SettingsRow(
                icon: Icons.star_border,
                title: 'Rate the app',
                onTap: () async {
                  final reviewer = InAppReview.instance;
                  if (await reviewer.isAvailable()) {
                    await reviewer.requestReview();
                  } else {
                    await reviewer.openStoreListing();
                  }
                },
              ),
              _SettingsRow(
                icon: Icons.support_agent,
                title: 'Contact support',
                subtitle: 'contact@stepbattle.fit',
                onTap: () async {
                  final uri = Uri(
                    scheme: 'mailto',
                    path: 'contact@stepbattle.fit',
                    query: 'subject=StepBattle support',
                  );
                  await launchUrl(uri);
                },
              ),
              _SettingsRow(
                icon: Icons.description_outlined,
                title: 'Terms of service',
                onTap: () async => launchUrl(
                  Uri.parse('https://www.stepbattle.fit/terms'),
                  mode: LaunchMode.externalApplication,
                ),
              ),
              _SettingsRow(
                icon: Icons.privacy_tip_outlined,
                title: 'Privacy policy',
                onTap: () async => launchUrl(
                  Uri.parse('https://www.stepbattle.fit/privacy'),
                  mode: LaunchMode.externalApplication,
                ),
              ),
              const _AppVersionRow(),
            ],
          ),

          const _SectionSpacer(),

          _SettingsGroup(
            title: null, // no header — destructive block sits bare
            children: [
              _SettingsRow(
                icon: Icons.logout,
                title: 'Sign out',
                titleColor: AppColors.error,
                iconColor: AppColors.error,
                onTap: () => _confirmSignOut(context, ref),
              ),
              _SettingsRow(
                icon: Icons.delete_outline,
                title: 'Delete account',
                titleColor: AppColors.error,
                iconColor: AppColors.error,
                onTap: () => showDeleteAccountSheet(context),
              ),
            ],
          ),
        ],
      )
          // Single one-shot fade+slide on the whole Settings ListView.
          // Cheaper than per-group stagger (there are ~10 sections);
          // gives the screen the "settling into place" feel without
          // adding animate() to every section. First-mount only via
          // flutter_animate's default; scroll never replays.
          .animate()
          .fadeIn(
            duration: Motion.d.slow,
            curve: Motion.curves.standard,
          )
          .slideY(
            begin: 0.02,
            end: 0,
            duration: Motion.d.slow,
            curve: Motion.curves.standard,
          ),
    );
  }

  static Future<void> _copy(BuildContext context, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied $value'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  static void _confirmSignOut(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainerHigh,
        title: const Text('Sign out'),
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
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
  }

  /// Field-based survey summariser — used by the top-level build so
  /// we can feed just the three raw fields extracted via `.select`,
  /// keeping the profile watch narrow.
  static String? _summariseSurveyFields({
    required int? age,
    required dynamic gender,
    required dynamic fitnessLevel,
  }) {
    final parts = <String>[];
    if (age != null) parts.add('$age');
    final g = _genderLabel(gender);
    if (g != null) parts.add(g);
    final f = _fitnessLabel(fitnessLevel);
    if (f != null) parts.add(f);
    return parts.isEmpty ? 'Tap to add' : parts.join('  ·  ');
  }

  static String? _genderLabel(dynamic g) {
    switch (g?.toString()) {
      case 'Gender.man':
        return 'Man';
      case 'Gender.woman':
        return 'Woman';
      case 'Gender.nonBinary':
        return 'Non-binary';
      case 'Gender.preferNotToSay':
        return 'Private';
    }
    return null;
  }

  static String? _fitnessLabel(dynamic f) {
    switch (f?.toString()) {
      case 'FitnessLevel.beginner':
        return 'Beginner';
      case 'FitnessLevel.intermediate':
        return 'Intermediate';
      case 'FitnessLevel.advanced':
        return 'Advanced';
      case 'FitnessLevel.pro':
        return 'Pro';
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Building blocks
// ---------------------------------------------------------------------------

class _SettingsGroup extends StatelessWidget {
  final String? title;
  final List<Widget> children;
  const _SettingsGroup({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              title!.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.4,
              ),
            ),
          ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: AppColors.onSurface.withValues(alpha: 0.05),
            ),
          ),
          child: Column(children: children),
        ),
      ],
    );
  }
}

class _SectionSpacer extends StatelessWidget {
  const _SectionSpacer();

  @override
  Widget build(BuildContext context) => const SizedBox(height: 22);
}

class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Color? titleColor;
  final Color? iconColor;

  const _SettingsRow({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
    this.titleColor,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final resolvedIconColor = iconColor ?? AppColors.primary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: resolvedIconColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, size: 18, color: resolvedIconColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: titleColor,
                      ),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(
                        subtitle!,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              trailing ??
                  Icon(
                    Icons.chevron_right,
                    color: AppColors.onSurfaceVariant,
                    size: 20,
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Notification-preference row — same visual as [_SettingsRow] but
/// with a trailing Switch that reads the current value from the
/// user's profile and writes changes to Supabase. Uses the row's
/// own `column` string as the update target so callers just pick
/// which pref this row toggles.
class _NotifToggleRow extends ConsumerStatefulWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final String column;
  final bool Function(dynamic profile) selector;
  final String? userId;

  const _NotifToggleRow({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.column,
    required this.selector,
    required this.userId,
  });

  @override
  ConsumerState<_NotifToggleRow> createState() => _NotifToggleRowState();
}

class _NotifToggleRowState extends ConsumerState<_NotifToggleRow> {
  bool _optimistic = false;
  bool _pending = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Watch only THIS row's bool — the row-provided `selector`
    // extracts the specific `notif_*` field from the profile. `.select`
    // means an unrelated profile emit (e.g. total_steps update from a
    // step sync) doesn't rebuild the toggle. Before this, four toggle
    // rows + the SettingsScreen top-level all rebuilt on every step
    // sync's profile emit; now each rebuilds only when its own bool
    // actually changes value, which is essentially never after mount.
    final serverValue = ref.watch(
      userProfileProvider.select((async) {
        final p = async.valueOrNull;
        return p == null ? true : widget.selector(p);
      }),
    );
    // Show the optimistic value while a write is in flight, so the
    // toggle animation is instant and doesn't wait on the round-trip.
    final displayed = _pending ? _optimistic : serverValue;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.userId == null ? null : () => _toggle(!displayed),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(9),
                ),
                child:
                    Icon(widget.icon, size: 18, color: AppColors.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    if (widget.subtitle != null &&
                        widget.subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(
                        widget.subtitle!,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              Switch.adaptive(
                value: displayed,
                onChanged: widget.userId == null ? null : _toggle,
                activeColor: AppColors.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _toggle(bool newValue) async {
    if (widget.userId == null) return;
    setState(() {
      _optimistic = newValue;
      _pending = true;
    });
    try {
      await Supabase.instance.client
          .from('profiles')
          .update({widget.column: newValue}).eq('id', widget.userId!);
      // userProfileProvider is a live stream; it will re-emit with
      // the new value shortly. Turn off `_pending` so we start
      // trusting server state again.
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not update: $e'),
          backgroundColor: AppColors.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }
}

class _AppVersionRow extends StatefulWidget {
  const _AppVersionRow();
  @override
  State<_AppVersionRow> createState() => _AppVersionRowState();
}

class _AppVersionRowState extends State<_AppVersionRow> {
  String? _version;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (!mounted) return;
      setState(() => _version = '${info.version} (build ${info.buildNumber})');
    });
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsRow(
      icon: Icons.info_outline,
      title: 'App version',
      subtitle: _version ?? '—',
      trailing: const SizedBox.shrink(),
    );
  }
}

/// Inline segmented-button row for the Appearance group.
class _ThemePickerRow extends ConsumerWidget {
  const _ThemePickerRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final mode = ref.watch(themeModePrefProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(Icons.dark_mode_outlined,
                size: 18, color: AppColors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Theme',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(
                value: ThemeMode.system,
                label: Text('Auto', style: TextStyle(fontSize: 11)),
              ),
              ButtonSegment(
                value: ThemeMode.light,
                label: Text('Light', style: TextStyle(fontSize: 11)),
              ),
              ButtonSegment(
                value: ThemeMode.dark,
                label: Text('Dark', style: TextStyle(fontSize: 11)),
              ),
            ],
            selected: {mode},
            showSelectedIcon: false,
            style: ButtonStyle(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: WidgetStateProperty.all(
                const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              ),
            ),
            onSelectionChanged: (set) =>
                ref.read(themeModePrefProvider.notifier).set(set.first),
          ),
        ],
      ),
    );
  }
}
