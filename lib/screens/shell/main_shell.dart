import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import '../../config/colors.dart';
import '../../config/motion.dart';
import '../../features/onboarding_tour/tour_controller.dart';
import '../../features/onboarding_tour/tour_overlay.dart';
import '../../features/onboarding_tour/tour_step.dart';
import '../../providers/app_lifecycle_provider.dart';
import '../../providers/auth_provider.dart';
import '../../models/notification_model.dart';
import '../../providers/battle_provider.dart';
import '../../providers/friend_provider.dart';
import '../../providers/leaderboard_provider.dart';
import '../../providers/mission_provider.dart';
import '../../providers/notification_provider.dart';
import '../../providers/run_session_provider.dart';
import '../../providers/step_provider.dart';
import '../../providers/tab_focus_provider.dart';
import '../../providers/user_provider.dart';
import '../../services/background_sync.dart';
import '../../services/notification_service.dart';
import '../../services/tour_service.dart';
import '../../utils/cross_isolate_kv.dart';
import '../../services/persistent_notifications.dart';
import '../../services/alarm_wake_scheduler.dart';
import '../../services/step_source_aggregator.dart';
import '../../utils/app_logger.dart';
import '../../utils/hive_lifecycle.dart';
import '../../widgets/coming_soon_sheet.dart';
import '../../widgets/battle_invite_toast_host.dart';
import '../../widgets/friend_request_toast_host.dart';
import '../../widgets/team_lobby_invite_toast_host.dart';
import '../../widgets/mission_poster_host.dart';
import '../../widgets/permission_gate.dart';
import '../../widgets/subscription_welcome_gate.dart';
import '../../widgets/xp_celebration.dart';

/// Main shell with 5-tab bottom nav.
/// On first build after sign-in:
///   - Runs schema backfill (ensures userCode + XP fields exist)
/// Continuously:
///   - Listens to local step changes and auto-syncs to Firestore
class MainShell extends ConsumerStatefulWidget {
  final StatefulNavigationShell navigationShell;

  const MainShell({super.key, required this.navigationShell});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  bool _backfillTriggered = false;

  /// Push-tap subscription, kept so `dispose` can cancel it.
  ///
  /// Typed loosely on purpose: the FCM `RemoteMessage` type stays behind
  /// [NotificationService], as everywhere else in this file. Dart generics
  /// are covariant, so the concrete `StreamSubscription<RemoteMessage>`
  /// assigns here cleanly.
  StreamSubscription<Object?>? _pushTapSub;

  /// A route from a notification tap that could not be applied yet.
  ///
  /// Held rather than dropped because the tap can land while the app is
  /// still deciding where the user belongs — profile row in flight, the
  /// onboarding gate about to fire, or the new-user tour on screen. Going
  /// to /battles in any of those windows either loses to the router's own
  /// redirect or yanks the user out of the tour. We park the route and
  /// flush it once the gates clear (see [_flushPendingPushRoute]).
  String? _pendingPushRoute;

  /// Instagram-style scroll-responsive bottom nav driver.
  ///
  /// 1.0 = fully expanded (max width, max icon size). 0.0 = fully
  /// compressed (min width, min icon size). Driven by
  /// [_handleScrollNotification]:
  ///   • user scroll UP (finger swipes down / content descends
  ///     → `ScrollDirection.forward`)  → `.forward()` (expand)
  ///   • user scroll DOWN (finger swipes up / content ascends
  ///     → `ScrollDirection.reverse`)  → `.reverse()` (compress)
  ///   • idle → hold last state
  ///
  /// Cold-start value is 1.0 so the nav is fully visible until the
  /// first scroll gesture. Duration = 240 ms for that easeOutCubic
  /// butter feel; the outer container size, corner radius, icon
  /// size, horizontal padding, and inter-icon gap all interpolate
  /// off this single controller inside `_BottomNavBar`.
  late final AnimationController _navExpand;

  /// Previously-rendered shell branch index. Used to detect transitions
  /// to Home (tab 0) so animations on the Home screen can re-fire even
  /// though the indexedStack keeps the widget alive — see
  /// [homeTabFocusTickProvider].
  int? _prevShellIndex;

  /// Wall-clock timestamp of the most recent `paused`/`inactive`/
  /// `hidden` transition. Read on `resumed` so we only fire the
  /// heavy provider-invalidate sweep when the app was actually gone
  /// long enough to have stale data. A 3-second notification-drawer
  /// pull that flips paused→resumed inside the same second no longer
  /// tears down 13 realtime channels and re-subscribes them.
  DateTime? _pausedAt;

  /// Threshold for treating "we came back" as a real absence. Below
  /// this, realtime streams reconcile themselves through their retry
  /// wrappers; invalidation would just churn subscriptions with no
  /// data benefit.
  static const Duration _resumeInvalidateThreshold = Duration(minutes: 2);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _navExpand = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      value: 1.0, // Start fully expanded on cold entry.
    );
    // Listen for messages from the foreground-service isolate, including
    // notification action-button taps (forwarded as `btn:<id>`).
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    // Battle/Track persistent notifications: the plugin's top-level tap
    // callback writes the target route here; we consume it via context.go.
    pendingDeepLinkNotifier.addListener(_consumePendingDeepLink);
    // Handle cold-launch case: route the user immediately if the app was
    // opened from a tap on one of these notifications.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _consumePendingDeepLink();
    });
    // FCM taps. Wired here — NOT from build() behind an auth check, which
    // is where it lived until 2026-11-22. `onMessageOpenedApp` is a plain
    // broadcast stream and buffers nothing, so every event emitted before
    // the subscription existed was lost for good. On a cold launch that
    // window spans splash + Supabase session restore + the first build
    // with a non-null uid, which is precisely when a launch-by-tap fires.
    _setupPushNavigation();
  }

  @override
  void dispose() {
    _navExpand.dispose();
    WidgetsBinding.instance.removeObserver(this);
    FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    pendingDeepLinkNotifier.removeListener(_consumePendingDeepLink);
    _pushTapSub?.cancel();
    // We deliberately do NOT stop the foreground service here. The shell can
    // unmount for benign reasons (navigating to a root-level route like
    // /track or /profile re-creates the shell on the way back), and stopping
    // the service mid-session would tear down step sync, notification, and
    // the live battle/track state. The service is torn down explicitly in
    // SupabaseAuthService.signOut() instead.
    super.dispose();
  }

  /// Consume any pending deep-link from a battle/track persistent notification
  /// tap. Clears the notifier so re-listening doesn't refire the same route.
  void _consumePendingDeepLink() {
    final route = pendingDeepLinkNotifier.value;
    if (route == null || !mounted) return;
    pendingDeepLinkNotifier.value = null;
    context.go(route);
  }

  /// Handler for messages forwarded from the foreground-service isolate.
  /// Currently used for notification action-button taps (open battle / end
  /// run / open). The task isolate sends `'btn:<id>'`; we route accordingly.
  void _onTaskData(Object data) {
    if (data is! String) return;
    if (!data.startsWith('btn:')) return;
    final id = data.substring(4);
    if (!mounted) return;
    switch (id) {
      case 'open_battle':
        context.go('/battles');
        break;
      case 'end_track':
        // The Track live screen handles the End flow (confirmation +
        // service.end() + save toast); just route there.
        context.go('/track/live');
        break;
      case 'open_app':
      default:
        context.go('/home');
    }
  }

  /// When the app returns to the foreground we (1) re-sync steps so the
  /// server has fresh numbers and (2) — only when the pause was long
  /// enough to plausibly have stale data — invalidate the data
  /// providers so the UI drops back to its shimmer skeletons and then
  /// floods in fresh values.
  ///
  /// Every state transition is mirrored into [appLifecycleStateProvider]
  /// so downstream providers (e.g. the 60s pedometer tick in
  /// [localTodayStepsProvider]) can gate their own periodic work.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Fan the transition out to any provider that wants to pause
    // background work while the UI isn't on screen.
    ref.read(appLifecycleStateProvider.notifier).state = state;

    if (state != AppLifecycleState.resumed) {
      // Any non-resumed transition is a candidate "we're leaving";
      // stamp the timestamp so the next `resumed` can measure the
      // absence. Overwriting on each non-resumed state is fine — we
      // want the *most recent* transition out of foreground.
      _pausedAt = DateTime.now();
      // Snapshot the native pedometer's current sensor value +
      // timestamp before Android kills the process. This is the
      // freshest breadcrumb the missed-days backfill can use next
      // time the app opens — the smaller the pre-termination gap,
      // the tighter the time-proportional estimate becomes.
      // Fire-and-forget: never block the lifecycle callback.
      unawaited(ref.read(nativeStepServiceProvider).snapshotForShutdown());
      return;
    }

    // ── resumed branch ────────────────────────────────────────────
    // If the WorkManager background isolate opened the shared Hive
    // box while we were away, our in-isolate handle can be stale —
    // the very first write from any repository would throw
    // `FileSystemException: File closed`. Reopen defensively before
    // any resume-triggered writes fire. Idempotent no-op if the box
    // is still open. See utils/hive_lifecycle.dart for the full
    // context on this race.
    unawaited(reopenSharedBoxIfClosed());

    final uid = ref.read(authStateProvider).valueOrNull?.id;
    if (uid == null) return;

    // Measure how long we were away. First resume of the process has
    // no prior pause, so treat missing-pause as "long enough" — this
    // preserves the previous behaviour on cold-launch from a warm
    // process (an unlikely but possible path).
    final wasAwayFor = _pausedAt == null
        ? _resumeInvalidateThreshold
        : DateTime.now().difference(_pausedAt!);
    _pausedAt = null;

    if (wasAwayFor >= _resumeInvalidateThreshold) {
      _refreshOnResume();
    }

    // Fresh device read → server, unconditional. Even a 30-second
    // trip out to the notification drawer might have accumulated
    // steps that the FGS hasn't yet flushed; a manual sync on
    // resume keeps the visible number honest without invalidating
    // the UI.
    //
    // Two-shot sync pattern (fixes the "5-minute background walk"
    // bug where the first read after resume returned the stale
    // cached step count):
    //
    //   1. IMMEDIATE sync — reads whatever the aggregator has right
    //      now. On short pauses this is fresh. On longer pauses the
    //      Android sensor's buffered events may not have flushed
    //      yet, so this can still emit a stale value.
    //   2. DELAYED sync (~2.5 s) — by now the `TYPE_STEP_COUNTER`
    //      sensor has delivered its buffered events to the resumed
    //      isolate, so a second aggregator read picks up the real
    //      current count. Uploading it triggers Supabase realtime
    //      → the UI updates without needing app restart. Matches
    //      the delay used inside `headlessStepSync`.
    _syncStepsAllSources(uid);
    Future<void>.delayed(const Duration(milliseconds: 2500), () {
      if (!mounted) return;
      _syncStepsAllSources(uid);
      // Nudge `localTodayStepsProvider` so the UI polls the
      // aggregator immediately (its 60s cadence would otherwise
      // sit on the stale value until the next scheduled tick).
      ref.invalidate(localTodayStepsProvider);
    });
  }

  /// Reset the read-side providers so dependent widgets re-enter their
  /// loading (shimmer) state, then repopulate from the freshest source.
  /// Realtime providers (battles/invites) re-subscribe, giving an immediate
  /// authoritative fetch rather than waiting for the next realtime event.
  void _refreshOnResume() {
    ref.invalidate(localTodayStepsProvider);
    ref.invalidate(firestoreTodayStepsProvider);
    ref.invalidate(todayCaloriesProvider);
    ref.invalidate(weeklyStepsProvider);
    ref.invalidate(userProfileProvider);
    ref.invalidate(dailyProgressProvider);
    ref.invalidate(weeklyProgressProvider);
    ref.invalidate(allBattlesProvider);
    ref.invalidate(incomingBattleInvitesProvider);
    ref.invalidate(myRankProvider);
    ref.invalidate(districtLeaderboardProvider);
    ref.invalidate(stateLeaderboardProvider);
    ref.invalidate(countryLeaderboardProvider);
    ref.invalidate(friendsLeaderboardProvider);
    // Friend relationships — added after a tester reported friends
    // disappearing after reinstall. The rows are still on the server
    // (RLS-scoped to user_id), so re-invalidating force-closes the
    // realtime channel and re-runs the initial SELECT. If the friends
    // list is truly empty after this, the account has genuinely lost
    // its friendships (rare — usually means a re-signup with a new
    // uid via a different Google account).
    ref.invalidate(allFriendRelationshipsProvider);
    ref.invalidate(friendsListProvider);
  }

  /// Deep-link when the user taps a push notification. `notification`-type FCM
  /// messages are shown by the OS; tapping one opens the app and we route to
  /// the relevant tab (battle result → Battles, etc. via [NotificationService.
  /// extractRoute]). Covers both the background-tap and cold-start cases.
  void _setupPushNavigation() {
    final svc = ref.read(notificationServiceProvider);

    // Warm app (background or foreground) — the OS showed the alert and
    // the user tapped it.
    _pushTapSub = svc.setupBackgroundTapHandler(
      onMessageOpenedApp: (message) => _handlePushTap(message.data, 'opened'),
    );

    // App opened from a terminated state by tapping a push. Unlike the
    // stream above this one is latched by the plugin, so calling it late
    // is safe — but we still call it as early as possible.
    svc.getInitialMessage().then((message) {
      if (message == null) return;
      _handlePushTap(message.data, 'initial');
    });
  }

  /// Turn a tapped notification's payload into a pending route.
  ///
  /// Logging every outcome is deliberate. Until now both tap paths were
  /// silent, so a tap that opened Home instead of Battles was
  /// indistinguishable from a tap that never reached Dart at all — the
  /// payload, the route table and the native delegate chain all had to be
  /// ruled out by inspection. These three lines make the next report
  /// self-diagnosing.
  void _handlePushTap(Map<String, dynamic> data, String source) {
    final route = NotificationService.extractRoute(data);
    AppLogger.notification.i('pushTap:received', fields: {
      'source': source,
      'type': data['type'],
      'route': route,
    });
    if (route == null) return;
    _pendingPushRoute = route;
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _flushPendingPushRoute());
  }

  /// Apply a held push route once it is safe to navigate.
  ///
  /// Safe means: the shell is mounted, onboarding is finished, and the
  /// new-user tour is not on screen. Anything else and the route stays
  /// parked — the `ref.listen` pair in [build] calls back in when the
  /// blocking condition clears.
  void _flushPendingPushRoute() {
    final route = _pendingPushRoute;
    if (route == null || !mounted) return;

    final onboarded = ref.read(hasCompletedOnboardingProvider).valueOrNull;
    if (onboarded != true) {
      AppLogger.notification.i('pushTap:held', fields: {
        'route': route,
        'reason': 'onboarding',
      });
      return;
    }
    if (ref.read(tourControllerProvider).active) {
      AppLogger.notification.i('pushTap:held', fields: {
        'route': route,
        'reason': 'tour',
      });
      return;
    }

    _pendingPushRoute = null;
    AppLogger.notification.i('pushTap:navigated', fields: {'route': route});
    context.go(route);
  }

  Future<void> _runInitialSync(String uid) async {
    // Each ref-read is guarded by `mounted` because this is a fire-and-forget
    // chain that can outlive the widget (e.g., the user signs out mid-sync,
    // which disposes the shell and invalidates `ref`).
    //
    // Profile creation no longer needs a client-side backfill — the
    // `on_auth_user_created` trigger on the Supabase side inserts the
    // profile row when the auth user is created.
    if (!mounted) return;
    // 0. Start the always-on foreground service so the persistent notification
    //    shows live stats (daily progress when idle, battle stats while a
    //    battle is active, run stats during a Track session). Idempotent.
    //    Also registers the terminated-state WorkManager fallback.
    await BackgroundSync.startService();
    await BackgroundSync.registerPeriodicSync();
    // Exact-time wake schedule — 4 fixed alarms per day that fire
    // headlessStepSync regardless of Doze mode / OEM battery saver.
    // Complements WorkManager (which is best-effort) so we get at
    // most a 6-hour gap in cloud sync even in the worst case. Called
    // here (after login) rather than at cold start so anonymous
    // sessions don't schedule wakes. Idempotent — safe on every
    // shell mount; existing schedule is replaced in place.
    await AlarmWakeScheduler.scheduleDaily();

    if (!mounted) return;
    // 1. Force a step sync using the aggregator (max of native + HC + Fit).
    //    Pushes today's aggregate to every downstream (step_logs, missions,
    //    battles, clan) AND writes the per-source hourly breakdown row.
    //    Needed because ref.listen only fires on CHANGE, not on first load.
    await _syncStepsAllSources(uid);

    // 1a. Missed-days backfill. If the app was terminated across one
    //     or more calendar days, WorkManager may not have written
    //     step_logs rows for those days (Xiaomi/Realme aggressive
    //     battery savers). This reconciles those gaps using Google
    //     Fit history (when enabled) or a native-pedometer time-
    //     proportional estimate. Fire-and-forget: never block the
    //     shell on a network round-trip for historical data.
    if (mounted) {
      unawaited(ref.read(stepServiceProvider).backfillMissedDays(
            userId: uid,
            native: ref.read(nativeStepServiceProvider),
            googleFit: ref.read(googleFitServiceProvider),
          ));
    }

    // 1b. Health-store reconciliation. Covers what 1a structurally
    //     cannot: days that DID get a row, but a short one, because
    //     the app was closed for the rest of them. On iOS that is
    //     every day the user does not open the app, since there is no
    //     background sync there at all. Also fire-and-forget.
    if (mounted) {
      unawaited(ref.read(stepServiceProvider).reconcileRecentDaysFromHealth(
            userId: uid,
            health: ref.read(healthServiceProvider),
          ));
    }

    // Battle activation + completion now runs server-side every minute
    // (supabase/migrations/0008 → pg_cron process_battle_lifecycle). The
    // client deliberately no longer sweeps those transitions: two writers
    // (cron + each device) could otherwise double-award XP and post
    // duplicate result notifications. The server is the single writer.

    if (!mounted) return;
    // 2. Register for push + persist the FCM token so the server can wake the
    //    phone (battle results, invites) while the app is backgrounded/killed.
    //    Non-fatal: failures here must never block the shell.
    final notifications = ref.read(notificationServiceProvider);
    try {
      await notifications.requestPermission();
      await notifications.saveToken(uid);
    } catch (_) {}
  }

  /// Runs the canonical "we just got new step data" pipeline:
  ///   1. Read all sources (cached if caller already triggered a read).
  ///   2. Write the per-source hourly snapshot to `source_step_hourly`.
  ///   3. Push the winning aggregate to `step_logs` + fan-out to
  ///      missions/battles/clan via [StepService.syncSteps].
  Future<void> _syncStepsAllSources(String uid) async {
    try {
      final aggregator = ref.read(stepAggregatorProvider);
      // Force a fresh read; this also updates `aggregator.lastReading`
      // which downstream listeners pick up.
      final reading = await aggregator.readWithDebug();

      // Always log the source breakdown — even when aggregate is 0.
      // That's how we detect "every source is empty" devices.
      await ref
          .read(sourceStepHourlyLogServiceProvider)
          .maybeLog(userId: uid, reading: reading);

      if (reading.aggregate <= 0) return;

      final healthService = ref.read(healthServiceProvider);
      final source = _winningSourceLabel(reading, healthService.sourceName);
      await ref.read(stepServiceProvider).syncSteps(
            userId: uid,
            steps: reading.aggregate,
            source: source,
          );
    } catch (_) {
      // Sync failures should never crash the UI shell.
    }
  }

  String _winningSourceLabel(StepReading r, String hcLabel) {
    if (r.aggregate <= 0) return 'none';
    final fit = r.googleFitSteps ?? -1;
    if (fit >= r.aggregate && fit > 0) return 'google_fit';
    if (r.healthConnectSteps == r.aggregate) return hcLabel;
    return 'native_pedometer';
  }

  /// Drive [_navExpand] toward its expanded (1.0) endpoint. Guarded
  /// so a redundant call while we're already animating that way is a
  /// no-op — keeps controller velocity clean AND skips a full-frame
  /// invalidate on repeated triggers. Shared by scroll-up detection
  /// AND tab taps (2026-09-14 user request: tap-to-expand mirrors
  /// scroll-up so the nav grows whenever the user is engaging with
  /// it either way).
  void _expandNav() {
    if (_navExpand.status != AnimationStatus.completed &&
        _navExpand.status != AnimationStatus.forward) {
      _navExpand.forward();
    }
  }

  /// Drive [_navExpand] toward its compressed (0.0) endpoint. Same
  /// status-guard as [_expandNav]. Called only from
  /// [_handleShellScroll] on `ScrollDirection.reverse`.
  void _compressNav() {
    if (_navExpand.status != AnimationStatus.dismissed &&
        _navExpand.status != AnimationStatus.reverse) {
      _navExpand.reverse();
    }
  }

  /// UserScrollNotification handler wired around the shell body.
  /// Translates scroll direction on ANY Scrollable descendant (Home,
  /// Battles, Ranks, Track, Clan tabs — plus modal sheets / lists
  /// inside them) into forward/reverse on [_navExpand] so the bottom
  /// nav smoothly enlarges when the user scrolls up and compresses
  /// when they scroll down. Returns `false` so the notification keeps
  /// bubbling — other listeners (e.g. AppBar collapse) still see it.
  bool _handleShellScroll(UserScrollNotification n) {
    switch (n.direction) {
      case ScrollDirection.forward:
        // Finger swipes down / content descends → user is scrolling
        // UP. Expand the nav.
        _expandNav();
        break;
      case ScrollDirection.reverse:
        // Finger swipes up / content ascends → user is scrolling
        // DOWN. Compress the nav.
        _compressNav();
        break;
      case ScrollDirection.idle:
        // Hold whatever state we ended on. Instagram's mechanic —
        // don't auto-restore on scroll stop; only direction flips
        // the nav.
        break;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    // Run one-time schema backfill + force initial step sync when auth confirms.
    // Non-blocking: fires and forgets.
    final uid = ref.watch(authStateProvider).valueOrNull?.id;
    if (uid != null && !_backfillTriggered) {
      _backfillTriggered = true;
      _runInitialSync(uid);
    }

    // Re-attempt a held push route whenever one of the gates that can hold
    // it moves. Both callbacks are no-ops unless something is pending.
    ref.listen(tourControllerProvider, (_, __) => _flushPendingPushRoute());
    ref.listen(
        hasCompletedOnboardingProvider, (_, __) => _flushPendingPushRoute());

    // (Battle-gated service control removed — the foreground service is now
    // always-on per user session, with its notification adapting to the active
    // state, so it can also show daily progress when no battle is live.)

    // Auto-sync step count to Firestore whenever local device reading changes.
    // Fans out to: step_logs, users.totalStepsAllTime,
    // user_mission_progress, active battles, clan members AND writes the
    // per-source hourly breakdown (`source_step_hourly`) for analytics.
    // When a `friend_accepted` notification arrives, force-refresh the
    // friend relationships stream. Without this, users who received
    // the "X is now your friend" push saw the sheet still show "No
    // friends yet" — the `friend_relationships` UPDATE payload
    // (pending → accepted) sometimes fails to propagate over the
    // shared realtime channel (transient drop, mid-transition
    // reconnect). The notification is the authoritative signal from
    // the server that this specific state change has landed, so
    // treat it as a trigger to re-read the source-of-truth.
    ref.listen<AsyncValue<List<NotificationModel>>>(
      notificationsProvider,
      (prev, next) {
        final prevList = prev?.valueOrNull ?? const [];
        final nextList = next.valueOrNull ?? const [];
        // Cheap change detection: find IDs in `next` that weren't in
        // `prev`. New arrivals matching `friend_accepted` are the
        // trigger. We only look at first-seen rows, so a later read-
        // state update on the same notification doesn't re-fire.
        final prevIds = {for (final n in prevList) n.id};
        final newAccepts = nextList
            .where((n) =>
                !prevIds.contains(n.id) &&
                n.type == NotificationType.friendAccepted)
            .toList(growable: false);
        if (newAccepts.isEmpty) return;
        // Invalidate the underlying stream first — that force-closes
        // the existing subscription and re-opens it with a fresh
        // initial SELECT reflecting the pending → accepted flip that
        // realtime may have missed. `friendsListProvider` then re-
        // runs because its `acceptedFriendIdsProvider` dependency
        // sees the new list.
        ref.invalidate(allFriendRelationshipsProvider);
        ref.invalidate(friendsListProvider);
      },
    );

    ref.listen<AsyncValue<int>>(localTodayStepsProvider, (prev, next) {
      final newSteps = next.valueOrNull;
      if (newSteps == null || newSteps <= 0) return;
      if (prev?.valueOrNull == newSteps) return;

      final uid = ref.read(authStateProvider).valueOrNull?.id;
      if (uid == null) return;

      // Use the cached reading from the aggregator — this is the SAME
      // reading that produced `newSteps`, guaranteeing the per-source
      // breakdown logged matches the value the UI just rendered.
      final reading = ref.read(stepAggregatorProvider).lastReading;
      if (reading == null) return;

      // Fire-and-forget; failures swallowed inside.
      ref
          .read(sourceStepHourlyLogServiceProvider)
          .maybeLog(userId: uid, reading: reading);

      final healthService = ref.read(healthServiceProvider);
      final source = _winningSourceLabel(reading, healthService.sourceName);
      ref.read(stepServiceProvider).syncSteps(
            userId: uid,
            steps: newSteps,
            source: source,
          );
    });

    final shell = widget.navigationShell;
    // Detect "user just landed on Home" (idx 0) or "Ranks" (idx 4)
    // transitions and tick the matching focus provider so affordances
    // on those screens can replay animations. Skips the initial mount —
    // each screen's own initState handles the first run.
    final shellIdx = shell.currentIndex;
    if (_prevShellIndex != shellIdx) {
      final oldIdx = _prevShellIndex;
      _prevShellIndex = shellIdx;
      if (oldIdx != null && oldIdx != shellIdx) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (shellIdx == 0) {
            ref.read(homeTabFocusTickProvider.notifier).state++;
          } else if (shellIdx == 4) {
            ref.read(ranksTabFocusTickProvider.notifier).state++;
          }
        });
      }
    }

    // ── New-user app tour (migration 0062) ─────────────────────────
    // Two listeners work in tandem:
    //   • [currentUserProvider] listener: when a fresh profile arrives,
    //     sync local mirror from server + check the fire gate. Only
    //     fires the tour when BOTH sources say "not completed" AND we
    //     currently show the Home tab (so we never surprise the user
    //     mid-battle).
    //   • [tourControllerProvider] listener: as the tour advances,
    //     navigate the shell to the destination for the current step
    //     (goBranch for tab-switch, push('/profile') for the profile
    //     branch child) BEFORE the overlay tries to measure the target.
    ref.listen(currentUserProvider, (prev, next) {
      final user = next.valueOrNull;
      if (user == null) return;
      final tourState = ref.read(tourControllerProvider);
      if (tourState.active) return;
      // Server → local mirror sync (fire-and-forget).
      ref.read(tourServiceProvider).syncFromServer(user.hasCompletedTour);
      final local = CrossIsolateKV.getTourCompletedLocalSync();
      final shouldFire = TourService.shouldFire(
        serverHasCompleted: user.hasCompletedTour,
        localHasCompleted: local,
      );
      if (!shouldFire) return;
      // Only start on Home so tab-switch chain doesn't interrupt an
      // in-progress workflow (e.g. mid-battle). The user can also hit
      // Replay from Settings later.
      if (widget.navigationShell.currentIndex != 0) return;
      ref.read(tourControllerProvider.notifier).start();
    });
    ref.listen(tourControllerProvider, (prev, next) {
      AppLogger.tour.i('shellListener:fire', fields: {
        'prevActive': (prev?.active ?? false).toString(),
        'nextActive': next.active.toString(),
        'prevStep': prev?.stepIndex.toString() ?? 'null',
        'nextStep': next.stepIndex.toString(),
        'nextTab': next.currentStep?.tab.name ?? 'null',
        'currentBranchIndex':
            widget.navigationShell.currentIndex.toString(),
      });
      if (prev != null && prev.active && !next.active) {
        AppLogger.tour.i('shellListener:branch:tourJustEnded');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final location = GoRouterState.of(context).uri.toString();
          if (location.startsWith('/profile')) {
            AppLogger.tour.i('shellListener:popProfile');
            final goRouter = GoRouter.of(context);
            if (goRouter.canPop()) goRouter.pop();
          }
        });
        return;
      }
      if (!next.active) return;
      final step = next.currentStep;
      if (step == null) return;
      final wanted = switch (step.tab) {
        TourTab.home => 0,
        TourTab.battles => 1,
        TourTab.profile => 0, // profile is a child of the Home branch
      };
      if (widget.navigationShell.currentIndex != wanted) {
        AppLogger.tour.i('shellListener:goBranch', fields: {
          'from': widget.navigationShell.currentIndex.toString(),
          'to': wanted.toString(),
          'tab': step.tab.name,
        });
        widget.navigationShell.goBranch(wanted);
      }
      // Profile step needs an explicit push on top of the Home branch.
      // Other steps stay on the branch root (/home, /battles). If the
      // user is already on /profile from a previous step, this push is
      // a no-op — the router coalesces same-location navigations.
      if (step.tab == TourTab.profile) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final location = GoRouterState.of(context).uri.toString();
          if (!location.startsWith('/profile')) {
            context.push('/profile');
          }
        });
      } else {
        // Non-profile step: if a pushed /profile is still on top from
        // the previous step, pop it so the target on Home / Battles
        // becomes reachable + measurable.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final location = GoRouterState.of(context).uri.toString();
          if (location.startsWith('/profile')) {
            final goRouter = GoRouter.of(context);
            if (goRouter.canPop()) goRouter.pop();
          }
        });
      }
    });

    final trackActive = ref.watch(isTrackActiveProvider);
    return PermissionGate(
      child: FriendRequestToastHost(
        child: TeamLobbyInviteToastHost(
        child: BattleInviteToastHost(
        child: MissionPosterHost(
          child: XPCelebrationHost(
            child: SubscriptionWelcomeGate(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Scaffold below — the overlay above must cover the
                  // bottom nav too, otherwise the user can still tap
                  // Home / Battles / Ranks tabs mid-tour and escape.
                  Scaffold(
              body: NotificationListener<UserScrollNotification>(
                onNotification: _handleShellScroll,
                child: shell,
              ),
              extendBody: true,
              // FAB removed: Track now lives in the bottom nav as a
              // dedicated tab. The `trackActive` flag is still surfaced
              // inside the Track tab itself (pulsing icon when a
              // session is live).
              //
              // AnimatedBuilder subscribes to `_navExpand` so the nav
              // rebuilds each frame while the scroll-responsive
              // expand/compress animation is running — scoped to the
              // nav alone, so the rest of the shell tree isn't dirty.
              // RepaintBoundary isolates the nav-bar's expand/compress
              // animation to its own compositing layer so the 240 ms
              // of scroll-driven rebuilds don't invalidate the paint
              // region of the scrollable Home / Battles / Ranks
              // content underneath. Direct root cause of the pre-fix
              // stutter (2026-09-14): without this, every animation
              // frame marked the bottom slot dirty for paint, which
              // cascaded into the shell body's raster pipeline while
              // it was already busy scrolling.
              bottomNavigationBar: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _navExpand,
                  builder: (context, _) => _BottomNavBar(
                    expandT: _navExpand.value,
                    trackActive: trackActive,
                    currentIndex: shell.currentIndex,
                    onTap: (index) {
                      // 2026-09-14: tap-to-expand mirrors scroll-up
                      // so the user always sees the nav at full size
                      // as they're interacting with it. Fires FIRST
                      // so the expand animation runs concurrently
                      // with the branch switch — feels like the tapped
                      // tab pulls the whole bar back up.
                      _expandNav();
                      // v1 gate — Clan tab (index 3) is "Coming Soon".
                      // Show the fade-out toast and DON'T switch tabs so
                      // the user stays on whichever tab they were viewing.
                      if (index == 3) {
                        showComingSoonSheet(context, title: 'Clan');
                        return;
                      }
                      shell.goBranch(
                        index,
                        initialLocation: index == shell.currentIndex,
                      );
                    },
                  ),
                ),
              ),
            ),
                  // ── Second child of the outer Stack: the tour ────
                  // Sits above BOTH body and bottomNavigationBar so
                  // tab taps are blocked while a step is showing.
                  // No-op SizedBox when the tour isn't active.
                  const OnboardingTourOverlay(),
                ],
              ),
          ),
        ),
      ),
    ),
    ),
    ),
    );
  }
}

/// Platform-branched decoration for the 3-chip nav bar (both the two
/// circle buttons and the centre pill). Matches Instagram's per-
/// platform treatment (shape / corner radius / icon layout unchanged —
/// only fill / active-indicator / elevation / blur):
///
///   • **Android** — flat solid opaque fill (Instagram's Android bar is
///     a monolithic opaque surface); no drop shadow; hairline 1-px
///     top-border for edge definition.
///   • **iOS**     — real UIKit-material equivalent via a
///     BackdropFilter blur behind a translucent surface fill; no
///     shadow; no border. Blur sigma tuned to feel like
///     `systemUltraThinMaterial` — very subtle, content behind stays
///     readable but softens.
///
/// Active-indicator policy is IDENTICAL on both platforms + matches
/// Instagram: only the icon glyph shifts from outline to filled +
/// tinted; chip chrome does not change. This class only supplies the
/// chrome — the icon swap stays in [_CircleNavButton] / [_PillCell].
class _InstagramNavStyle {
  _InstagramNavStyle._();

  /// Whether to wrap the chip in a [BackdropFilter]. Only true on iOS.
  static bool get useBlur => Platform.isIOS;

  /// Fill colour for the chip surface. Two-tier translucence:
  ///   • iOS     — 0.55 alpha over a real `BackdropFilter` blur.
  ///     Reads as material (systemUltraThinMaterial equivalent).
  ///   • Android — 0.92 alpha, NO blur. Reads as a subtle
  ///     translucent pill without paying `BackdropFilter`'s 3-5 ms
  ///     per-frame composite cost (which would re-introduce the
  ///     scroll stutter we just fixed with the RepaintBoundary).
  ///     92 % is high enough that the underlying content never
  ///     leaks busy detail through the pill — just a hint of the
  ///     background tone bleeds in so it doesn't read as a slab.
  ///     2026-09-14 Option A: user chose translucent-without-blur
  ///     as the Android glass compromise.
  static Color fill(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (Platform.isIOS) {
      return scheme.surface.withValues(alpha: 0.55);
    }
    return scheme.surface.withValues(alpha: 0.92);
  }

  /// Hairline outline for chip edge. Android gets a subtle border for
  /// definition (mirrors Instagram's 1-px top rule on the bar); iOS
  /// suppresses the border — the material itself provides separation.
  static BoxBorder? border(BuildContext context) {
    if (Platform.isIOS) return null;
    final scheme = Theme.of(context).colorScheme;
    // Match Instagram Android's divider tint: `#DBDBDB` in light / `#262626`
    // in dark, roughly 8% onSurface. Stronger than the previous 6% so
    // the chip reads as a distinct surface against a busy Home
    // background — Instagram's real bar has a full-width 1-px top rule,
    // we approximate it with a chip outline.
    return Border.all(
      color: scheme.onSurface.withValues(alpha: 0.08),
      width: 1,
    );
  }

  /// Instagram uses zero elevation shadow on both platforms. Return an
  /// empty list so `boxShadow: _InstagramNavStyle.shadows()` reads
  /// clearly and can be re-tuned in one place later.
  static List<BoxShadow> shadows() => const [];

  /// Blur sigma tuned for the iOS material feel. 24 is high enough to
  /// soften typical Home content (chart lines, step numbers) without
  /// turning the backdrop into pure gray.
  static const double iosBlurSigma = 24.0;
}

/// Unified bottom nav — one pill, 5 items, scroll-responsive size.
///
/// 2026-09-14 rewrite: previously a split three-block layout
/// `[Ranks circle] [Battles·Home·Track pill] [Clan circle]`. Merged
/// into ONE pill per user request with visual order:
///
///   `Ranks · Track · Home · Battles · Clan`
///
/// Branch indices are UNCHANGED (routes.dart still hands out
/// `Home=0, Battles=1, Track=2, Clan=3, Ranks=4`) — only the visual
/// order shifts. Same Instagram-adaptive chrome as before (Android
/// solid opaque + hairline border, iOS translucent + BackdropFilter
/// blur), same active-icon pop animation, same Track live-dot, same
/// Clan Coming-Soon gate handled at MainShell's `onTap` callback.
///
/// [expandT] drives Instagram-style scroll-responsive sizing:
///   • 1.0 → fully expanded: pill height 62, radius 34, icon 28,
///     horizontal padding 18, inter-icon gap 10
///   • 0.0 → fully compressed: pill height 46, radius 26, icon 22,
///     horizontal padding 10, inter-icon gap 2
/// MainShell owns the AnimationController that feeds this value;
/// scroll up on any Scrollable in the shell body expands, scroll
/// down compresses.
class _BottomNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  /// When true, the Track tab's icon shows a green live-dot in its
  /// top-right corner so the user can see a session is in flight
  /// from any tab.
  final bool trackActive;

  /// 0 = fully compressed, 1 = fully expanded. Continuous during the
  /// scroll-responsive animation.
  final double expandT;

  const _BottomNavBar({
    required this.currentIndex,
    required this.onTap,
    required this.trackActive,
    required this.expandT,
  });

  // Branch indices — MUST match the StatefulShellRoute branch order
  // in routes.dart. Visual arrangement is separate (see build()).
  static const int _kHome     = 0;
  static const int _kBattles  = 1;
  static const int _kTrack    = 2;
  static const int _kClan     = 3;
  static const int _kRanks    = 4;

  // Fixed pill dimensions — the pill's LAYOUT stays constant across
  // every frame of the scroll-responsive animation. Only a single
  // Transform.scale (in build() below) changes per frame — that's
  // paint work, not layout. Instagram's compressed state is roughly
  // 78 % of expanded, matched by [_scaleCompressed].
  //
  // 2026-09-14 v2 rewrite: the previous version lerp'd height,
  // radius, padding, gap, cell width, and icon size independently
  // — each change invalidated LAYOUT (not just paint), cascading
  // re-measure through the whole subtree every one of ~15 animation
  // frames per direction change. RepaintBoundary isolates paint but
  // does NOT stop layout invalidation from bubbling. Swapping the
  // property lerps for a single Transform.scale drops layout work
  // to zero during the animation and keeps the visual identical
  // (everything scales proportionally, same as scaling the endpoint
  // sizes independently would have looked at each t).
  static const double _pillHeight = 62;
  static const double _iconSize = 28;
  static const double _pillRadius = 34;
  static const double _pillHorizPad = 18;
  static const double _pillGap = 10;

  /// Scale factor at fully-compressed state. Chosen so the visually
  /// scaled pill matches the pre-rewrite compressed endpoints
  /// (height ≈ 46 → 62 × 0.78 ≈ 48; icon 22 → 28 × 0.78 ≈ 22).
  static const double _scaleCompressed = 0.78;

  @override
  Widget build(BuildContext context) {
    // Single interpolated value — Transform.scale factor for the
    // outer pill. Everything else uses constants.
    final scale = _scaleCompressed + (1.0 - _scaleCompressed) * expandT;

    // Visual order: Ranks · Track · Home · Battles · Clan. Home in
    // the geometric middle so the primary tab is thumb-central.
    final items = <_PillItem>[
      const _PillItem(
        icon: Icons.leaderboard_outlined,
        activeIcon: Icons.leaderboard,
        label: 'Ranks',
        branchIndex: _kRanks,
      ),
      _PillItem(
        icon: Icons.directions_run_outlined,
        activeIcon: Icons.directions_run,
        label: 'Track',
        branchIndex: _kTrack,
        liveDot: trackActive,
      ),
      const _PillItem(
        icon: Icons.home_outlined,
        activeIcon: Icons.home,
        label: 'Home',
        branchIndex: _kHome,
      ),
      _PillItem(
        icon: MdiIcons.swordCross,
        activeIcon: MdiIcons.swordCross,
        label: 'Battles',
        branchIndex: _kBattles,
      ),
      const _PillItem(
        icon: Icons.shield_outlined,
        activeIcon: Icons.shield,
        label: 'Clan',
        branchIndex: _kClan,
      ),
    ];

    Widget pill = Container(
      height: _pillHeight,
      padding: const EdgeInsets.symmetric(horizontal: _pillHorizPad),
      decoration: BoxDecoration(
        color: _InstagramNavStyle.fill(context),
        borderRadius: BorderRadius.circular(_pillRadius),
        border: _InstagramNavStyle.border(context),
        boxShadow: _InstagramNavStyle.shadows(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (int i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(width: _pillGap),
            _NavCell(
              item: items[i],
              iconSize: _iconSize,
              isActive: currentIndex == items[i].branchIndex,
              onTap: () => onTap(items[i].branchIndex),
            ),
          ],
        ],
      ),
    );

    // iOS-only backdrop blur — clipped to the pill's rounded shape so
    // the blur mask matches the chip edge. Blur sigma AND clip radius
    // are both constant now (pill's layout no longer animates), so
    // BackdropFilter re-renders identically each frame — the
    // Transform.scale below is applied AFTER blur composition, which
    // scales the already-blurred layer instead of re-blurring at each
    // size. This is cheaper AND avoids the stepped-blur artifacting
    // that would come from re-blurring at fractional sizes each frame.
    if (_InstagramNavStyle.useBlur) {
      pill = ClipRRect(
        borderRadius: BorderRadius.circular(_pillRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: _InstagramNavStyle.iosBlurSigma,
            sigmaY: _InstagramNavStyle.iosBlurSigma,
          ),
          child: pill,
        ),
      );
    }

    // The ONLY thing that changes per animation frame is this scale
    // factor. Transform.scale is a paint-time matrix multiply — no
    // layout invalidation, no constraint propagation, no re-measure
    // of any child. The whole widget subtree below has identical
    // layout every frame. Combined with the outer RepaintBoundary in
    // MainShell.build(), this animation costs a few microseconds per
    // frame in raster + a single GPU composite.
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        // Row + mainAxisAlignment.center (NOT Align.center) — Align
        // expands to fill both axes of the loosely-constrained bottom
        // slot, drifting the pill to the middle of the screen. A Row
        // takes only the pill's intrinsic height, keeping it anchored
        // at the bottom while still centred horizontally.
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Transform.scale(
              scale: scale,
              alignment: Alignment.center,
              child: pill,
            ),
          ],
        ),
      ),
    );
  }
}

/// Descriptor for one item in the unified pill nav.
class _PillItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final int branchIndex;
  final bool liveDot;
  const _PillItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.branchIndex,
    this.liveDot = false,
  });
}

/// One tap cell inside the unified pill. Renders the icon at the
/// caller-supplied [iconSize] (interpolated by the scroll-responsive
/// animation in [_BottomNavBar]) and plays a per-cell "pop" scale on
/// becoming active. Same visual grammar as the pre-merge [_PillCell]
/// — no filled violet chip, only an icon-colour tint on active — so
/// the merge is visually invisible apart from the layout change.
class _NavCell extends StatefulWidget {
  final _PillItem item;
  final double iconSize;
  final bool isActive;
  final VoidCallback onTap;

  const _NavCell({
    required this.item,
    required this.iconSize,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<_NavCell> createState() => _NavCellState();
}

class _NavCellState extends State<_NavCell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pop;

  @override
  void initState() {
    super.initState();
    _pop = AnimationController(vsync: this, duration: Motion.d.fast);
  }

  @override
  void didUpdateWidget(covariant _NavCell old) {
    super.didUpdateWidget(old);
    if (!old.isActive && widget.isActive) _pop.forward(from: 0);
  }

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activeFg = AppColors.primary;
    final inactiveFg =
        AppColors.isLight ? Colors.black.withValues(alpha: 0.72) : Colors.white70;

    // Cell hit-target width scales with icon size + tap padding so
    // the pill's overall width naturally shrinks with the icons
    // during compress. Minimum tap area stays comfortable even at
    // the smallest icon (22 dp icon + 22 dp padding = 44 dp cell).
    final cellWidth = widget.iconSize + 22;

    return GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: cellWidth,
        child: Center(
          child: AnimatedBuilder(
            animation: _pop,
            builder: (_, child) {
              final t = _pop.value;
              // Perf: 99% of the time _pop is at rest (0.0). Only
              // wrap in Transform.scale during the brief post-tap
              // bump — avoids a Matrix4 identity allocation on every
              // scroll-animation frame across 5 cells.
              if (t == 0) return child!;
              final pop = 4 * t * (1 - t) * 0.15;
              return Transform.scale(scale: 1.0 + pop, child: child);
            },
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                AnimatedSwitcher(
                  duration: Motion.d.fast,
                  // Key on (branchIndex, isActive). Icon SIZE changes
                  // from the scroll-responsive interpolation must NOT
                  // trigger a crossfade — only active-state flips do.
                  child: Icon(
                    widget.isActive ? widget.item.activeIcon : widget.item.icon,
                    key: ValueKey('${widget.item.branchIndex}_${widget.isActive}'),
                    color: widget.isActive ? activeFg : inactiveFg,
                    size: widget.iconSize,
                  ),
                ),
                if (widget.item.liveDot)
                  Positioned(
                    top: -2,
                    right: -4,
                    child: Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: AppColors.success,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.success.withValues(alpha: 0.6),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

