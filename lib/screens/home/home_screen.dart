import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../config/colors.dart';
import '../../config/motion.dart';
import '../../features/onboarding_tour/tour_controller.dart';
import '../../features/onboarding_tour/tour_replay_icon.dart';
import '../../features/onboarding_tour/tour_step.dart';
import '../../features/onboarding_tour/tour_target.dart';
import '../../providers/auth_provider.dart';
import '../../providers/battle_provider.dart';
import '../../providers/mission_provider.dart';
import '../../providers/notification_provider.dart';
import '../../providers/user_provider.dart';
import '../../services/capability_service.dart';
import '../../services/media_warmup.dart';
import '../../services/tour_service.dart';
import '../../services/xp_celebration_bus.dart';
import '../../sheets/device_connect_prompt_sheet.dart';
import '../../sheets/notifications_sheet.dart';
import '../../sheets/set_goal_sheet.dart';
import '../../utils/app_logger.dart';
import '../../utils/cross_isolate_kv.dart';
import '../../widgets/avatar_circle.dart';
import '../../widgets/buy_xp_cta.dart';
import '../../widgets/friends_app_bar_button.dart';
import '../../widgets/mount_stagger.dart';
import '../../widgets/metric_lock.dart';
import '../../widgets/no_source_gate.dart';
import '../../widgets/no_steps_banner.dart';
import '../../widgets/permission_gate.dart';
import '../../widgets/pro_badge.dart';
import '../onboarding/health_setup_screen.dart';
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

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  /// Guards the one-shot media warmup. Firing on every rebuild would
  /// hammer `rootBundle.load` — cheap once the asset is cached, but
  /// pointless.
  bool _mediaWarmupScheduled = false;

  /// Guards the one-shot device-connect prompt so we don't try to
  /// re-fire in the same Home mount if a lifecycle-resume tick lands
  /// while the sheet is already up.
  bool _deviceConnectPromptScheduled = false;

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
    WidgetsBinding.instance.addObserver(this);
    // Fire the device-connect prompt check on first mount + whenever
    // the primer / no-source blocker closes (via their ValueNotifier
    // listeners) + on foreground return. All paths funnel to the same
    // idempotent [_maybeShowDeviceConnectPrompt] which short-circuits
    // if the predicate isn't fully met or if we've already prompted.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _maybeShowDeviceConnectPrompt();
    });
    PermissionGate.primerOpen.addListener(_onGateVisibilityChanged);
    NoSourceGate.blockerOpen.addListener(_onGateVisibilityChanged);
    // The XP celebration is the first half of the signup flow this
    // sheet now waits behind; `current` clears when the overlay's exit
    // animation finishes, which is our cue to re-check.
    XPCelebrationBus.instance.current.addListener(_onGateVisibilityChanged);
  }

  @override
  void dispose() {
    PermissionGate.primerOpen.removeListener(_onGateVisibilityChanged);
    NoSourceGate.blockerOpen.removeListener(_onGateVisibilityChanged);
    XPCelebrationBus.instance.current
        .removeListener(_onGateVisibilityChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Foreground return — retry the prompt in case the user resolved a
    // gate in another app (e.g. accepted a system permission dialog
    // that made the primer dismiss). Cheap check; short-circuits
    // immediately if the flag is set or a gate is still up.
    if (state == AppLifecycleState.resumed) {
      _maybeShowDeviceConnectPrompt();
      // Missions catalog re-hydrate — Supabase Realtime does NOT replay
      // events that fired while our subscription was down (a network
      // flap between the last resume and now, an OS backgrounding stretch
      // during which the WebSocket got killed). Invalidating here forces
      // a fresh snapshot from server so admin-side edits made while we
      // were away land immediately, without waiting for the user to
      // pull-to-refresh. Cheap — the providers are cached, so the read
      // returns instantly for the common case (nothing changed).
      // See PostgreSQL logical-replication docs on missed-event
      // semantics + the analysis on 2026-08-31 diagnostics logs.
      ref.invalidate(dailyMissionsProvider);
      ref.invalidate(weeklyMissionsProvider);
    }
  }

  /// Fires when either the [PermissionGate] primer or the
  /// [NoSourceGate] blocker transitions open → closed. Re-checks the
  /// full predicate; the sheet mounts only if we've fully cleared out
  /// of the mandatory gates.
  void _onGateVisibilityChanged() {
    if (PermissionGate.primerOpen.value) return;
    if (NoSourceGate.blockerOpen.value) return;
    if (XPCelebrationBus.instance.current.value != null) return;
    _maybeShowDeviceConnectPrompt();
  }

  /// Idempotent — safe to call from any of the trigger paths. Fires
  /// the sheet at most once per Home mount (guarded by
  /// [_deviceConnectPromptScheduled]) AND at most once ever per install
  /// (guarded by [DeviceConnectPromptSheet.shouldShow]).
  ///
  /// The full predicate:
  ///   • Onboarding complete
  ///   • No permission primer up
  ///   • No no-source blocker up
  ///   • No health-setup first-run wizard pending
  ///   • No XP celebration on screen
  ///   • New-user tour neither running nor still owed
  ///   • Prompt not previously shown
  ///
  /// [tourJustEnded] is passed only by the tour-end listener in
  /// [build], which knows the tour is over first-hand and therefore
  /// skips the "still owed" check — see the note on that gate below.
  void _maybeShowDeviceConnectPrompt({bool tourJustEnded = false}) {
    if (!mounted || _deviceConnectPromptScheduled) return;
    if (PermissionGate.primerOpen.value) return;
    if (NoSourceGate.blockerOpen.value) return;
    if (HealthSetupScreen.shouldShowFirstRunWizard()) return;
    if (!DeviceConnectPromptSheet.shouldShow()) return;
    // Onboarding gate — the router only lands on /home for onboarded
    // users, but read the provider anyway so a still-loading state
    // (AsyncLoading during a cold-start profile fetch) defers rather
    // than firing prematurely.
    final onboarded = ref.read(hasCompletedOnboardingProvider).valueOrNull;
    if (onboarded != true) return;

    // ── Signup-flow deferral (2026-11-02) ─────────────────────────
    //
    // This sheet opens with `useRootNavigator: true`, so it paints
    // ABOVE MainShell's Stack — which is exactly where the XP
    // celebration overlay (main_shell.dart, XPCelebrationHost) and the
    // tour overlay both live. Firing while either is up doesn't stack
    // politely, it BURIES them.
    //
    // logs/2026-11-02_12-02-56 caught all three at once on a fresh
    // signup: bonus credited :22.472, this sheet opened :23.217, the
    // tour started :23.817 underneath it and then spent 20 s
    // highlighting a step counter the sheet was covering.
    //
    // Of the three this is the lowest priority — it's discoverability,
    // not a requirement (see the class doc) — so it goes LAST, once
    // the whole new-user flow has been finished or skipped.
    if (XPCelebrationBus.instance.current.value != null) return;
    if (ref.read(tourControllerProvider).active) return;
    // `active` alone is not enough. The tour starts ~1.3 s AFTER the
    // bonus lands, so a check that runs in that gap sees an inactive
    // tour and fires straight into its face. Ask the same question
    // MainShell asks when deciding to START the tour — "is a tour
    // still owed?" — so a pending one defers us just as a running one
    // does.
    //
    // The tour-end listener passes `tourJustEnded: true` to bypass
    // this rather than re-deriving it, because `markCompleted` writes
    // the server flag and the local mirror BEFORE flipping the
    // controller to inactive; re-reading those here would couple the
    // sheet to that write order for no benefit.
    if (!tourJustEnded) {
      final tourOwed = TourService.shouldFire(
        serverHasCompleted:
            ref.read(currentUserProvider).valueOrNull?.hasCompletedTour,
        localHasCompleted: CrossIsolateKV.getTourCompletedLocalSync(),
      );
      if (tourOwed) return;
    }

    _deviceConnectPromptScheduled = true;
    // Small delay so the sheet doesn't fight the closing animation of
    // whatever gate the user just resolved (200 ms matches the pause
    // permission_gate.dart already uses before pushing the first-run
    // health wizard).
    Future.delayed(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      DeviceConnectPromptSheet.show(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    // ── Tour sheet driver ─────────────────────────────────────────
    // Home currently drives ONE sheet: SetGoalSheet, for the
    // change-goal + save-goal steps (indices 3 + 4). Both share the
    // same sheet, so the sheet stays open across those two steps —
    // we only open when entering the pair and only close when
    // leaving it.
    //
    // (The old TodaysMissionSheet path was retired 2026-09-04 when
    // the change-goal flow was rewritten to go straight to
    // SetGoalSheet with interactive +/- + Save.)
    ref.listen(tourControllerProvider, (prev, next) {
      final prevSheet = prev?.currentStep?.sheet;
      final nextSheet = next.currentStep?.sheet;
      AppLogger.tour.i('homeListener:fire', fields: {
        'prevActive': (prev?.active ?? false).toString(),
        'nextActive': next.active.toString(),
        'prevStep': prev?.stepIndex.toString() ?? 'null',
        'nextStep': next.stepIndex.toString(),
        'prevSheet': prevSheet?.name ?? 'null',
        'nextSheet': nextSheet?.name ?? 'null',
        'nextTargetId': next.currentStep?.targetId.name ?? 'null',
      });
      // Tour finished or skipped — the last thing the new-user flow was
      // waiting on. Release the device-connect sheet (deliberately NOT
      // a `return`: the setGoal outbound branch below still has to run
      // if the tour ended while that sheet was the current step).
      if ((prev?.active ?? false) && !next.active) {
        _maybeShowDeviceConnectPrompt(tourJustEnded: true);
      }
      if (nextSheet == TourSheet.setGoal && prevSheet != TourSheet.setGoal) {
        AppLogger.tour.i('homeListener:branch:setGoalInbound');
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted) return;
          final userAsync = ref.read(currentUserProvider);
          final currentGoal =
              userAsync.valueOrNull?.dailyStepGoal ?? 8000;
          AppLogger.tour.i('homeListener:openSetGoalSheet',
              fields: {'currentGoal': currentGoal.toString()});
          await SetGoalSheet.show(
            context,
            currentGoal: currentGoal,
            useRootNavigator: false,
            barrierColor: Colors.transparent,
            useSafeArea: true,
            initialChildSize: 0.95,
            extraBottomPadding: 100,
          );
          if (!mounted) return;
          AppLogger.tour.i('homeListener:setGoalClosed');
          final notifier = ref.read(tourControllerProvider.notifier);
          var state = ref.read(tourControllerProvider);
          while (state.active &&
              state.currentStep?.sheet == TourSheet.setGoal) {
            AppLogger.tour.i('homeListener:advance:pastSetGoal',
                fields: {'at': state.stepIndex.toString()});
            await notifier.next();
            state = ref.read(tourControllerProvider);
          }
        });
      }
      if (prevSheet == TourSheet.setGoal && nextSheet != TourSheet.setGoal) {
        AppLogger.tour.i('homeListener:branch:setGoalOutbound');
        final nav = Navigator.of(context, rootNavigator: false);
        if (nav.canPop()) {
          AppLogger.tour.i('homeListener:popSetGoal');
          nav.pop();
        }
      }
    });

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
          // Info icon — replays the tour SCOPED to Home steps (0-5
          // after 2026-09-13's change-goal INTRO shift).
          // Compact 36×36 target so the actions row fits within the
          // AppBar width (see tour_replay_icon.dart comment).
          const TourReplayIconButton(
            fromIndex: TourStepRanges.homeFrom,
            untilExclusive: TourStepRanges.homeUntilExclusive,
            tooltip: 'Home tour',
          ),
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
      // Not const: the streak strip is wrapped in a MetricLock whose
            // locked state takes a callback, which cannot be const. The
            // individual children below keep their own const where valid.
            children: [
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
            // TourTarget wraps the WHOLE streak strip (2026-09-04):
            // spotlight includes flame + "N Days" caption + weekly
            // dots so the highlight covers the entire concept unit,
            // and the card lands right below the strip. The step's
            // `notchFractionOverride` (in kTourSteps) forces the
            // notch to point at the LEFT of the strip where the
            // flame lives.
            Padding(
              padding: const EdgeInsets.only(bottom: 28),
              child: TourTarget(
                id: TourTargetId.homeStreakFlame,
                // Streak needs steps to exist at all, and notifications to
                // be worth anything — a streak you are never warned about
                // losing is just a number that disappears overnight. So
                // the lock covers both, and tapping it asks for whichever
                // is still missing.
                child: MetricLock(
                  requires: const [
                    AppCapability.steps,
                    AppCapability.notifications,
                  ],
                  lockedBuilder: (context, resolve) => LockedCardBody(
                    title: 'Streaks are locked',
                    body: 'StepBattle needs your step count to track a '
                        'streak, and notifications to warn you before you '
                        'lose one.',
                    onTap: resolve,
                  ),
                  child: const RepaintBoundary(child: StreakStrip()),
                ),
              ),
            ),
            Padding(padding: EdgeInsets.only(bottom: 0),  child: RepaintBoundary(child: UpgradeBannerCard())),
            // OverviewCard hosts the level progress block internally
            // (see overview_card.dart — TourTarget wraps just that
            // block so step 2 spotlights ONLY the LVL bar + labels,
            // not the whole card with step count + XP total).
            Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: RepaintBoundary(child: OverviewCard()),
            ),
            Padding(padding: EdgeInsets.only(bottom: 0),  child: RepaintBoundary(child: StatPillsRow())),
            Padding(padding: EdgeInsets.only(bottom: 24), child: RepaintBoundary(child: ActiveBattleCard())),
            // Bonus-quests tour step removed 2026-09-04 (user
            // request). Widget stays; the TourTarget wrapper is gone.
            Padding(
              padding: EdgeInsets.only(bottom: 0),
              child: RepaintBoundary(child: HighlightedMissionsSection()),
            ),
            Padding(padding: EdgeInsets.only(bottom: 0),  child: RepaintBoundary(child: TodaysSessionCard())),
            // Wrapped in TourTarget (migration 0062) so step 1 of the
            // new-user tour spotlights today's goal card. Layout-neutral.
            Padding(
              padding: EdgeInsets.only(bottom: 32),
              child: TourTarget(
                id: TourTargetId.homeStepCounter,
                child: RepaintBoundary(child: DailyTargetCard()),
              ),
            ),
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
    // Weekly catalog re-hydrates too — the Home feed can surface
    // weekly missions in the highlighted section, and admin edits to
    // either catalog should land on a pull. Also catches the same
    // realtime missed-event class as daily (see AppLifecycleState
    // .resumed handler in _HomeScreenState).
    ref.invalidate(weeklyMissionsProvider);
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
}
