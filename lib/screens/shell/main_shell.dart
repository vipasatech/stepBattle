import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import '../../config/colors.dart';
import '../../config/motion.dart';
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
import '../../services/persistent_notifications.dart';
import '../../services/alarm_wake_scheduler.dart';
import '../../services/step_source_aggregator.dart';
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
    with WidgetsBindingObserver {
  bool _backfillTriggered = false;

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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    pendingDeepLinkNotifier.removeListener(_consumePendingDeepLink);
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

    svc.setupBackgroundTapHandler(onMessageOpenedApp: (message) {
      final route = NotificationService.extractRoute(message.data);
      if (route != null && mounted) context.go(route);
    });

    // App opened from a terminated state by tapping a push.
    svc.getInitialMessage().then((message) {
      if (message == null || !mounted) return;
      final route = NotificationService.extractRoute(message.data);
      if (route == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go(route);
      });
    });
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

  @override
  Widget build(BuildContext context) {
    // Run one-time schema backfill + force initial step sync when auth confirms.
    // Non-blocking: fires and forgets.
    final uid = ref.watch(authStateProvider).valueOrNull?.id;
    if (uid != null && !_backfillTriggered) {
      _backfillTriggered = true;
      _runInitialSync(uid);
      _setupPushNavigation();
    }

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

    final trackActive = ref.watch(isTrackActiveProvider);
    return PermissionGate(
      child: FriendRequestToastHost(
        child: TeamLobbyInviteToastHost(
        child: BattleInviteToastHost(
        child: MissionPosterHost(
          child: XPCelebrationHost(
            child: SubscriptionWelcomeGate(
              child: Scaffold(
              body: shell,
              extendBody: true,
              // FAB removed: Track now lives in the bottom nav as a
              // dedicated tab. The `trackActive` flag is still surfaced
              // inside the Track tab itself (pulsing icon when a
              // session is live).
              bottomNavigationBar: _BottomNavBar(
                trackActive: trackActive,
                currentIndex: shell.currentIndex,
                onTap: (index) {
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

  /// Fill colour for the chip surface. Solid opaque on Android, low-
  /// alpha translucent on iOS so the blur beneath it shows through.
  static Color fill(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (Platform.isIOS) {
      // systemUltraThinMaterial equivalent — very subtle vibrancy.
      // 55% alpha on top of a 20-sigma blur reads as "material" rather
      // than "translucent solid" per Apple's iOS 17 vocabulary.
      return scheme.surface.withValues(alpha: 0.55);
    }
    // Android — Instagram uses solid opaque bar chrome (no material).
    return scheme.surface;
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

class _BottomNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  /// When true, the Track tab's icon switches to its "live" variant
  /// (running figure + accent dot) so the user can see a session is in
  /// flight from any tab.
  final bool trackActive;

  const _BottomNavBar({
    required this.currentIndex,
    required this.onTap,
    required this.trackActive,
  });

  // Branch indices — MUST match the StatefulShellRoute branch order
  // in routes.dart. Visual order in this bar (Ranks | Battles Home
  // Track | Clan) is decoupled from these indices; the shell only
  // cares which branch index we hand it.
  static const int _kHome     = 0;
  static const int _kBattles  = 1;
  static const int _kTrack    = 2;
  static const int _kClan     = 3;
  static const int _kRanks    = 4;

  @override
  Widget build(BuildContext context) {
    // Three-block floating layout per the redesigned spec:
    //   [ Ranks (circle) ] [ Battles · Home · Track (pill) ] [ Clan (circle) ]
    //
    // The outer container is a transparent SafeArea insetter — the
    // actual "chrome" lives on each of the three blocks so they read
    // as detached, machined controls rather than a monolithic bar.
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // LEFT — Ranks single circle.
            _CircleNavButton(
              icon: Icons.leaderboard_outlined,
              activeIcon: Icons.leaderboard,
              tooltip: 'Ranks',
              isActive: currentIndex == _kRanks,
              onTap: () => onTap(_kRanks),
            ),

            const SizedBox(width: 10),

            // CENTER — Battles | Home | Track pill. Home visually
            // middle. Expanded so the pill fills the remaining width.
            Expanded(
              child: _PillNavGroup(
                items: [
                  _PillItem(
                    icon: MdiIcons.swordCross,
                    activeIcon: MdiIcons.swordCross,
                    label: 'Battles',
                    branchIndex: _kBattles,
                  ),
                  const _PillItem(
                    icon: Icons.home_outlined,
                    activeIcon: Icons.home,
                    label: 'Home',
                    branchIndex: _kHome,
                  ),
                  _PillItem(
                    icon: Icons.directions_run_outlined,
                    activeIcon: Icons.directions_run,
                    label: 'Track',
                    branchIndex: _kTrack,
                    liveDot: trackActive,
                  ),
                ],
                currentIndex: currentIndex,
                onTap: onTap,
              ),
            ),

            const SizedBox(width: 10),

            // RIGHT — Clan single circle.
            _CircleNavButton(
              icon: Icons.shield_outlined,
              activeIcon: Icons.shield,
              tooltip: 'Clan',
              isActive: currentIndex == _kClan,
              onTap: () => onTap(_kClan),
            ),
          ],
        ),
      ),
    );
  }
}

/// Standalone circular nav button — used for Ranks (left) and Clan
/// (right). Same glass-tinted surface + soft shadow as the pill so
/// the three blocks read as a set even when detached.
class _CircleNavButton extends StatefulWidget {
  final IconData icon;
  final IconData activeIcon;
  final String tooltip;
  final bool isActive;
  final VoidCallback onTap;

  const _CircleNavButton({
    required this.icon,
    required this.activeIcon,
    required this.tooltip,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<_CircleNavButton> createState() => _CircleNavButtonState();
}

class _CircleNavButtonState extends State<_CircleNavButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pop;

  @override
  void initState() {
    super.initState();
    _pop = AnimationController(vsync: this, duration: Motion.d.fast);
  }

  @override
  void didUpdateWidget(covariant _CircleNavButton old) {
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
    // Circle chrome is IDENTICAL whether active or inactive — only the
    // icon colour changes. Instagram's per-platform treatment lives in
    // [_InstagramNavStyle]:
    //   • Android → solid opaque surface, 1-px hairline border, no
    //     shadow.
    //   • iOS     → translucent surface over a real BackdropFilter blur
    //     (systemUltraThinMaterial equivalent), no border, no shadow.
    final activeFg = AppColors.primary;
    final inactiveFg =
        AppColors.isLight ? Colors.black.withValues(alpha: 0.75) : Colors.white70;

    Widget chip = Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: _InstagramNavStyle.fill(context),
        shape: BoxShape.circle,
        border: _InstagramNavStyle.border(context),
        boxShadow: _InstagramNavStyle.shadows(),
      ),
      alignment: Alignment.center,
      child: AnimatedBuilder(
        animation: _pop,
        builder: (_, child) {
          final t = _pop.value;
          final pop = t == 0 ? 0.0 : 4 * t * (1 - t) * 0.15;
          return Transform.scale(scale: 1.0 + pop, child: child);
        },
        // Only the icon colour transitions on active-state change.
        child: AnimatedSwitcher(
          duration: Motion.d.fast,
          child: Icon(
            widget.isActive ? widget.activeIcon : widget.icon,
            key: ValueKey(widget.isActive),
            color: widget.isActive ? activeFg : inactiveFg,
            size: 24,
          ),
        ),
      ),
    );

    // iOS-only backdrop blur — real material behind the chip so
    // content underneath softens the way Instagram's UITabBar does.
    // ClipOval matches the chip's circular shape so the blurred region
    // doesn't leak past the chip edge.
    if (_InstagramNavStyle.useBlur) {
      chip = ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: _InstagramNavStyle.iosBlurSigma,
            sigmaY: _InstagramNavStyle.iosBlurSigma,
          ),
          child: chip,
        ),
      );
    }

    return GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: Tooltip(
        message: widget.tooltip,
        child: chip,
      ),
    );
  }
}

/// Descriptor for a pill entry — Battles / Home / Track.
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

/// Centre pill holding 3 tabs. The active tab lights up with a violet
/// tint chip that morphs smoothly between positions via a shared
/// AnimatedContainer background inside each cell.
class _PillNavGroup extends StatelessWidget {
  final List<_PillItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _PillNavGroup({
    required this.items,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Same Instagram-adaptive chrome as [_CircleNavButton]:
    //   • Android → solid opaque fill, hairline border, no shadow.
    //   • iOS     → translucent fill over a real BackdropFilter blur,
    //     no border, no shadow.
    Widget pill = Container(
      height: 56,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _InstagramNavStyle.fill(context),
        borderRadius: BorderRadius.circular(32),
        border: _InstagramNavStyle.border(context),
        boxShadow: _InstagramNavStyle.shadows(),
      ),
      child: Row(
        children: items.map((item) {
          return Expanded(
            child: _PillCell(
              item: item,
              isActive: currentIndex == item.branchIndex,
              onTap: () => onTap(item.branchIndex),
            ),
          );
        }).toList(),
      ),
    );

    // iOS-only backdrop blur — clipped to the pill's rounded shape so
    // the blur mask matches the chip edge.
    if (_InstagramNavStyle.useBlur) {
      pill = ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: _InstagramNavStyle.iosBlurSigma,
            sigmaY: _InstagramNavStyle.iosBlurSigma,
          ),
          child: pill,
        ),
      );
    }

    return pill;
  }
}

class _PillCell extends StatefulWidget {
  final _PillItem item;
  final bool isActive;
  final VoidCallback onTap;

  const _PillCell({
    required this.item,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<_PillCell> createState() => _PillCellState();
}

class _PillCellState extends State<_PillCell>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pop;

  @override
  void initState() {
    super.initState();
    _pop = AnimationController(vsync: this, duration: Motion.d.fast);
  }

  @override
  void didUpdateWidget(covariant _PillCell old) {
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
    return GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      // No filled violet chip on active — matches the reference nav
      // (icon-only tint). The parent pill provides the background;
      // the cell is a transparent tap target.
      child: Container(
        alignment: Alignment.center,
        child: AnimatedBuilder(
          animation: _pop,
          builder: (_, child) {
            final t = _pop.value;
            final pop = t == 0 ? 0.0 : 4 * t * (1 - t) * 0.15;
            return Transform.scale(scale: 1.0 + pop, child: child);
          },
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              AnimatedSwitcher(
                duration: Motion.d.fast,
                child: Icon(
                  widget.isActive ? widget.item.activeIcon : widget.item.icon,
                  key: ValueKey(widget.isActive),
                  color: widget.isActive ? activeFg : inactiveFg,
                  size: 24,
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
    );
  }
}

