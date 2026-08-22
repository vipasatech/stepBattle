import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'config/colors.dart';
import 'config/theme.dart';
import 'config/routes.dart';
import 'providers/battle_activation_detector.dart';
import 'providers/local_profile_photo_provider.dart';
import 'providers/mission_provider.dart';
import 'providers/theme_mode_provider.dart';
import 'providers/xp_telemetry_provider.dart';
import 'services/local_profile_photo_service.dart';
import 'utils/permission_coordinator.dart';

class StepBattleApp extends ConsumerStatefulWidget {
  const StepBattleApp({super.key});

  @override
  ConsumerState<StepBattleApp> createState() => _StepBattleAppState();
}

class _StepBattleAppState extends ConsumerState<StepBattleApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Retry any queued profile-photo upload when the app comes back to
    // the foreground. Covers the "user picked a photo while offline →
    // network came back later" case so home + leaderboard eventually
    // sync without the user re-opening the picker.
    if (state == AppLifecycleState.resumed) {
      // Fire-and-forget; the service handles its own idempotency and
      // logs failures instead of throwing. Bump the retry tick so the
      // "Syncing…" chip in the profile UI re-checks the pref on
      // completion.
      LocalProfilePhotoService.retryPendingUpload().whenComplete(() {
        if (mounted) {
          ref.read(profilePhotoRetryTickProvider.notifier).state++;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Instantiate the connectivity listener once — the provider owns
    // the subscription for the app's lifetime and re-drives the
    // pending-upload retry the moment the device reconnects. Read
    // (not watch) — we don't want a rebuild every network flip.
    ref.read(photoRetryConnectivityProvider);

    // Push the device's local timezone offset to the server the first
    // time auth becomes available (and any time it changes — travel).
    // Watched so the provider re-runs on the auth-state transition.
    ref.watch(tzOffsetSyncProvider);

    // XP delta telemetry — logs every profiles.total_xp change to the
    // Diagnostics "xp" filter with before/after/delta + best-effort
    // ledger reason lookup. Empty return type; kept alive here for
    // its side effects. Testers use the xp filter to correlate
    // battle wins / mission credits / streak milestones with what
    // the leaderboard actually sees.
    ref.watch(xpDeltaTelemetryProvider);

    final router = ref.watch(routerProvider);

    // Foreground-auto-nav to the arena when any of the user's battles
    // transitions to `active`. The detector emits a battle id via
    // this provider on transition; we push /battle-ground/{id} and
    // consume the signal so a subsequent identical status doesn't
    // re-fire. Backgrounded users get the same nav via the FCM push
    // route resolver (`extractRoute` → `battle_started`).
    ref.listen<String?>(battleActivationDetectorProvider, (prev, next) async {
      if (next == null) return;
      // Defer nav while a permission dialog is showing. Route-pushing
      // during a permission flow tears down the dialog's parent context
      // → dialog callback never fires → app hangs in "loading" state.
      // Waiting for the coordinator's queue to drain is cheap when
      // idle (immediate) and correct when a dialog IS up.
      if (PermissionCoordinator.instance.isFlowActive) {
        await PermissionCoordinator.instance.awaitDrain();
      }
      // Push through the router. If the user is already on that
      // battle-ground route, the router's redirect handles same-route
      // no-op. Consumer clears the state so we're re-armed.
      router.push('/battle-ground/$next');
      ref.read(battleActivationDetectorProvider.notifier).consume();
    });
    final mode = ref.watch(themeModePrefProvider);

    // Resolve effective brightness BEFORE MaterialApp.router builds, so the
    // first frame of every descendant reads the right value from
    // AppColors.X getters. Doing this from MaterialApp.builder was too
    // late — the builder wraps the navigator output, by which point
    // children have already built with the stale (dark-default) value.
    final platformBrightness = MediaQuery.platformBrightnessOf(context);
    final effective = switch (mode) {
      ThemeMode.system => platformBrightness,
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
    };
    AppColors.updateBrightness(effective);

    return MaterialApp.router(
      title: 'StepBattle',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: mode,
      routerConfig: router,
      // Clamp the OS-level text scaling so very aggressive accessibility
      // settings (e.g. Android "Largest" / iOS 200% Dynamic Type) don't
      // blow out our fixed-height pills, app-bars, and battle cards.
      // We still respect the user's preference up to 1.2× — past that
      // we hold the line. Users who need bigger text can still use
      // pinch-zoom on screens that support it (Profile, leaderboards).
      builder: (context, child) {
        // Defensive double-update — Theme.of inside the builder reflects
        // the FINAL resolved brightness (incl. any platform overrides
        // applied between StepBattleApp.build and here). Cheap no-op
        // when the parent already set the right value.
        AppColors.updateBrightness(Theme.of(context).brightness);

        final mq = MediaQuery.of(context);
        final clampedScale =
            mq.textScaler.scale(1.0).clamp(0.85, 1.20);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(clampedScale)),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
