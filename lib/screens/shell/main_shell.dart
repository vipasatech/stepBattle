import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import '../../config/colors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/battle_provider.dart';
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
import '../../services/step_source_aggregator.dart';
import '../../widgets/friend_request_toast_host.dart';
import '../../widgets/permission_gate.dart';

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
  /// server has fresh numbers and (2) invalidate the data providers so the
  /// UI drops back to its shimmer skeletons and then floods in fresh values
  /// instead of showing whatever stale data was on screen when it was paused.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final uid = ref.read(authStateProvider).valueOrNull?.id;
    if (uid == null) return;

    _refreshOnResume();

    // Fresh device read → server. Battle activation/completion is owned by the
    // server-side cron (migration 0008); the invalidations above re-fetch the
    // latest battle state so a returning user sees the result within a tick.
    _syncStepsAllSources(uid);
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

    if (!mounted) return;
    // 1. Force a step sync using the aggregator (max of native + HC + Fit).
    //    Pushes today's aggregate to every downstream (step_logs, missions,
    //    battles, clan) AND writes the per-source hourly breakdown row.
    //    Needed because ref.listen only fires on CHANGE, not on first load.
    await _syncStepsAllSources(uid);

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
        child: Scaffold(
          body: shell,
          extendBody: true,
          // FAB removed: Track now lives in the bottom nav as a dedicated
          // tab. The `trackActive` flag is still surfaced inside the Track
          // tab itself (pulsing icon when a session is live).
          bottomNavigationBar: _BottomNavBar(
            trackActive: trackActive,
            currentIndex: shell.currentIndex,
            onTap: (index) => shell.goBranch(
              index,
              initialLocation: index == shell.currentIndex,
            ),
          ),
        ),
      ),
    );
  }
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

  // Missions tab dropped in favour of Track. Order matches the
  // StatefulShellRoute branch order in routes.dart.
  // `final` (not `const`) because MdiIcons.swordCross resolves at
  // runtime — one of the entries below can't be const-evaluated.
  static final _items = [
    const _NavItem(
      icon: Icons.home_outlined,
      activeIcon: Icons.home,
      label: 'Home',
    ),
    // MDI `swordCross` — two zig-zag crossed swords. Not part of
    // Flutter's built-in Material Icons, hence the extra
    // `material_design_icons_flutter` package. Same glyph for
    // active + inactive since the outline / filled distinction is
    // carried by the foreground colour swap in `_NavButton`. This
    // entry isn't `const` because MdiIcons.swordCross is a runtime
    // getter — that's why the enclosing list dropped its `const`.
    _NavItem(
      icon: MdiIcons.swordCross,
      activeIcon: MdiIcons.swordCross,
      label: 'Battles',
    ),
    const _NavItem(
      icon: Icons.directions_run_outlined,
      activeIcon: Icons.directions_run,
      label: 'Track',
    ),
    const _NavItem(
      icon: Icons.shield_outlined,
      activeIcon: Icons.shield,
      label: 'Clan',
    ),
    const _NavItem(
      icon: Icons.leaderboard_outlined,
      activeIcon: Icons.leaderboard,
      label: 'Ranks',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.background.withValues(alpha: 0.8),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
              top: BorderSide(
                color: AppColors.onSurface.withValues(alpha: 0.05),
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: AppColors.primaryBrand.withValues(alpha: 0.15),
                blurRadius: 20,
                offset: const Offset(0, -8),
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: List.generate(_items.length, (i) {
                  final item = _items[i];
                  final isActive = i == currentIndex;
                  // The Track tab (index 2) gets a small green dot
                  // overlay when a session is live, so the user spots it
                  // from any other tab.
                  final showLiveDot = i == 2 && trackActive;
                  return _NavButton(
                    item: item,
                    isActive: isActive,
                    showLiveDot: showLiveDot,
                    onTap: () => onTap(i),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  final _NavItem item;
  final bool isActive;
  final bool showLiveDot;
  final VoidCallback onTap;

  const _NavButton({
    required this.item,
    required this.isActive,
    required this.onTap,
    this.showLiveDot = false,
  });

  @override
  Widget build(BuildContext context) {
    // Light mode reads better with pure-black inactive icons/labels;
    // dark mode keeps the softer grey so inactive tabs don't punch on
    // the dark surface. Hoisted so the ternary stays terse below.
    final Color foreground = isActive
        ? AppColors.primary
        : (AppColors.isLight ? Colors.black : Colors.grey);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        // Active state is now indicated by colour-only tinting of the
        // icon + label (no surrounding pill / glow). The padding stays
        // so the tap target keeps the same size as before — only the
        // visual chrome around the active tab is removed.
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  isActive ? item.activeIcon : item.icon,
                  color: foreground,
                  size: 24,
                ),
                if (showLiveDot)
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
            const SizedBox(height: 4),
            Text(
              item.label,
              style: TextStyle(
                fontFamily: 'Manrope',
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: foreground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });
}
