import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../config/colors.dart';
import '../../config/motion.dart';
import '../../providers/auth_provider.dart';
import '../../providers/battle_provider.dart';
import '../../providers/mission_provider.dart';
import '../../providers/notification_provider.dart';
import '../../providers/user_provider.dart';
import '../../services/media_warmup.dart';
import '../../sheets/notifications_sheet.dart';
import '../../widgets/avatar_circle.dart';
import '../../widgets/buy_xp_cta.dart';
import '../../widgets/friends_app_bar_button.dart';
import '../../widgets/mount_stagger.dart';
import '../../widgets/no_source_gate.dart';
import '../../widgets/no_steps_banner.dart';
import '../../widgets/pro_badge.dart';
import 'widgets/overview_card.dart';
import 'widgets/stat_pills_row.dart';
import 'widgets/active_battle_card.dart';
import 'widgets/daily_target_card.dart';
import 'widgets/health_sync_nudge_card.dart';
import 'widgets/highlighted_missions_section.dart';
import 'widgets/resume_tracking_icon_button.dart';
import 'widgets/map_preview_card.dart';
import 'widgets/streak_strip.dart';
import 'widgets/todays_session_card.dart';
import 'widgets/upgrade_banner_card.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// Guards the one-shot media warmup. Firing on every rebuild would
  /// hammer `rootBundle.load` — cheap once the asset is cached, but
  /// pointless.
  bool _mediaWarmupScheduled = false;

  @override
  void initState() {
    super.initState();
    // Defer arena PNG warmup until AFTER Home's first paint. The
    // splash used to run this synchronously in its own initState,
    // which competed with Flutter hydrating the initial Home frame
    // for disk / CPU cycles — visible as a small hitch on the
    // splash → Home transition. `addPostFrameCallback` runs on
    // idle after the first frame commits, so the warmup uses time
    // that would otherwise sit unused.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _mediaWarmupScheduled) return;
      _mediaWarmupScheduled = true;
      unawaited(MediaWarmup.preloadArenaForNow());
    });
  }

  @override
  Widget build(BuildContext context) {
    // Narrow the profile watch to just the two fields the AppBar
    // reads. Watching raw `userProfileProvider.valueOrNull` used to
    // rebuild the AppBar (and thus the BellButton, BuyXpCta,
    // FriendsAppBarButton, AvatarCircle, ProBadge stack) on every
    // XP / streak / step-count tick that touched the profile row —
    // visible as small hitches during scroll. `.select` on a
    // record of the two actual dependencies means the AppBar only
    // rebuilds when the avatar URL or friendly name changes, which
    // is essentially never during normal use.
    final avatarAndName = ref.watch(
      userProfileProvider.select(
        (p) => (p.valueOrNull?.avatarURL, p.valueOrNull?.friendlyName),
      ),
    );
    final avatarUrl = avatarAndName.$1;
    final friendlyName = avatarAndName.$2;
    final unreadCount = ref.watch(unreadNotificationCountProvider);

    // The `CompleteProfileSheet` catch-up modal used to pop here to
    // ask users who onboarded before migration 0016 for DOB / gender
    // / fitness. It's been retired: the current onboarding flow
    // collects those same fields (plus preferred_name), and
    // `hasCompletedOnboardingProvider` bounces any signed-in user
    // with a missing field back to `/onboarding` before they ever
    // reach Home. No fallback surface is needed here.

    // New top-bar topology (replaces the old wordmark + 5-action row):
    //
    //   ┌─ leading ──────────────┐ ┌── title ──┐ ┌── actions ─┐
    //   │ (Profile)(Friends)     │ │  +XP CTA  │ │   🔔²      │
    //   └────────────────────────┘ └───────────┘ └────────────┘
    //
    //   • Profile + Friends sit in the hardest-to-reach corner (low-
    //     frequency identity actions).
    //   • +XP CTA gets the center slot for maximum visual pull, paired
    //     with a 1.2 s sweep animation around its border that fires once
    //     on every Home mount (the user explicitly asked for this).
    //   • Notification bell with its badge stays right — that's where
    //     the eye expects it and the thumb finds it easily.
    return Scaffold(
      appBar: AppBar(
        // Make room for the Profile avatar + Friends button in the
        // leading slot — defaults to 56 which only fits one.
        leadingWidth: 100,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: () => context.push('/profile'),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    AvatarCircle(
                      radius: 18,
                      imageUrl: avatarUrl,
                      initials: _initials(friendlyName),
                      borderColor: AppColors.outlineVariant,
                      borderWidth: 1,
                    ),
                    // Bottom-right verified badge. Sits just inside
                    // the avatar edge with a small dark ring so it
                    // reads clearly on any avatar background. Auto-
                    // hides on Free tier via ProBadge itself.
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppColors.background,
                          shape: BoxShape.circle,
                        ),
                        padding: const EdgeInsets.all(1),
                        child: const ProBadge(size: 14),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const FriendsAppBarButton(),
            ],
          ),
        ),
        centerTitle: true,
        title: const BuyXpCta(),
        actions: [
          // Resume-tracking icon — only visible when the always-on FGS
          // heartbeat has gone stale (>10 min). Amber pulse to draw
          // attention. Tap → force-restart the FGS. Replaces the
          // full-width "Live tracking paused" card that used to live
          // at the top of the MountStagger (2026-08-13 UX refactor).
          const ResumeTrackingIconButton(),
          const SizedBox(width: 8),
          _BellButton(unreadCount: unreadCount),
          const SizedBox(width: 12),
        ],
      ),
      // NoSourceGate hard-blocks Home with a "Set up" dialog when the
      // device has no working step source at all (native pedometer
      // unavailable AND HC empty AND Google Fit off/empty). Users can
      // still use other tabs — this only gates Home.
      body: const NoSourceGate(child: _HomeBody()),
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

// _BuyXpCta + _SweepBorderPainter moved to lib/widgets/buy_xp_cta.dart
// so Profile can render the same animated CTA in its AppBar title.

class _BellButton extends StatelessWidget {
  final int unreadCount;
  const _BellButton({required this.unreadCount});

  @override
  Widget build(BuildContext context) {
    // Pull surface + on-surface colours from Theme so this widget is
    // subscribed to the InheritedWidget — without that dependency, the
    // bell's background was reading a stale value from the static
    // AppColors getter on theme toggle and only updated after the next
    // touch event jolted a rebuild.
    final scheme = Theme.of(context).colorScheme;
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
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(Icons.notifications_outlined,
                color: scheme.onSurface, size: 20),
            // AnimatedSwitcher pops the badge from scale 0 → 1 with a
            // spring curve when it first appears (0 → 1 unread) or
            // disappears (last one read). Ticks between counts (1 → 2)
            // reuse the same widget so no re-animation on every tick.
            Positioned(
              top: -4,
              right: -4,
              child: AnimatedSwitcher(
                duration: Motion.adaptDuration(context, Motion.d.slow),
                switchInCurve: Motion.curves.spring,
                switchOutCurve: Motion.curves.decel,
                transitionBuilder: (child, animation) => ScaleTransition(
                  scale: animation,
                  child: FadeTransition(opacity: animation, child: child),
                ),
                child: unreadCount > 0
                    ? Container(
                        // Same instance-key across count values keeps
                        // AnimatedSwitcher from restarting the pop
                        // when the number ticks 1 → 2.
                        key: const ValueKey('unread-badge'),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        constraints: const BoxConstraints(
                            minWidth: 16, minHeight: 16),
                        decoration: BoxDecoration(
                          color: scheme.error,
                          borderRadius: BorderRadius.circular(10),
                          border:
                              Border.all(color: scheme.surface, width: 1.5),
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
                      )
                    : const SizedBox.shrink(
                        key: ValueKey('unread-badge-empty')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HomeBody extends ConsumerWidget {
  const _HomeBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Each top-level card is wrapped in a `RepaintBoundary` so a
    // provider tick that dirties one card (streak-strip week change,
    // active-battle step delta, XP celebration overlay above) can't
    // force a repaint of every other card in the viewport. Before
    // this, any invalidation of an ambient provider re-drew the
    // whole Home list on the compositor. `SizedBox` gaps stay
    // outside the boundaries — they're const and have nothing to
    // repaint anyway.
    return RefreshIndicator(
      // Pull-to-refresh: nudges the primary providers so realtime-cached
      // rows (profile, steps, active battles, missions) re-hydrate on
      // demand. Providers backed by Supabase streams are already live,
      // but users still want the reassurance of a manual pull when
      // their phone was offline for a while.
      onRefresh: () => _handleRefresh(ref),
      child: ListView(
      // Bottom padding: clears the shell nav (~90 dp) + ~40 dp of
      // breathing room so the last card (Map preview) stays visibly
      // above the nav bar. Matches Profile + Settings spacing.
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 130),
      // Pre-inflate ~800 dp past the viewport (Flutter's default is
      // 250). On Home the whole body is ~1400 dp, so this typically
      // means the entire card stack is warm before the user starts
      // scrolling — no mid-scroll widget-inflate hitches.
      cacheExtent: 800,
      children: const [
        // MountStagger reveals each top-level card with a fade + tiny
        // slide-up on FIRST MOUNT ONLY (flutter_animate's `Animate`
        // widget preserves completion state; Riverpod ticks and
        // pull-to-refresh do not replay). animateCount:7 covers the
        // hero surfaces above the fold (banner → streak → overview →
        // pills → active battle → missions → today's session); anything
        // below appears without animation so scrolling down never
        // re-triggers a stagger. Spacers are baked into each card's
        // Padding so they travel together with the card during slide.
        MountStagger(
          // Bumped 7 → 9 for the two accuracy banners, then trimmed
          // 9 → 8 in 1.1.6+26 when KeepTrackingBanner was replaced by
          // the header ResumeTrackingIconButton (which lives above the
          // MountStagger and doesn't get staggered).
          animateCount: 8,
          children: [
            Padding(padding: EdgeInsets.only(bottom: 0), child: NoStepsBanner()),
            // Accuracy nudges — order matters: FGS restart banner is
            // higher priority (blocks live sync) so it shows first when
            // both would fire simultaneously.
            // KeepTrackingBanner removed 1.1.6+26 — its Resume affordance
            // migrated to the ResumeTrackingIconButton in the app-bar
            // actions (see above). Keeps Home clean when FGS is healthy.
            Padding(padding: EdgeInsets.only(bottom: 0), child: HealthSyncNudgeCard()),
            Padding(padding: EdgeInsets.only(bottom: 28), child: RepaintBoundary(child: StreakStrip())),
            Padding(padding: EdgeInsets.only(bottom: 0),  child: RepaintBoundary(child: UpgradeBannerCard())),
            Padding(padding: EdgeInsets.only(bottom: 12), child: RepaintBoundary(child: OverviewCard())),
            Padding(padding: EdgeInsets.only(bottom: 0),  child: RepaintBoundary(child: StatPillsRow())),
            Padding(padding: EdgeInsets.only(bottom: 24), child: RepaintBoundary(child: ActiveBattleCard())),
            Padding(padding: EdgeInsets.only(bottom: 0),  child: RepaintBoundary(child: HighlightedMissionsSection())),
            Padding(padding: EdgeInsets.only(bottom: 0),  child: RepaintBoundary(child: TodaysSessionCard())),
            Padding(padding: EdgeInsets.only(bottom: 32), child: RepaintBoundary(child: DailyTargetCard())),
            Padding(padding: EdgeInsets.only(bottom: 0),  child: RepaintBoundary(child: MapPreviewCard())),
          ],
        ),
      ],
      ),
    );
  }

  /// Fires on pull-to-refresh. Invalidates the providers that back the
  /// visible Home cards so they re-fetch immediately. Yields a tick to
  /// let the RefreshIndicator paint its spin animation before we
  /// return — otherwise iOS's cupertino-refresh cancels itself when
  /// the future resolves instantly.
  Future<void> _handleRefresh(WidgetRef ref) async {
    ref.invalidate(currentUserProvider);
    ref.invalidate(allBattlesProvider);
    ref.invalidate(dailyMissionsProvider);
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
}
