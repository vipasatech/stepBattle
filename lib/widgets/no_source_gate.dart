import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../config/colors.dart';
import '../providers/step_provider.dart';
import '../screens/onboarding/health_setup_screen.dart';
import '../services/capability_service.dart';
import '../utils/app_logger.dart';
import 'permission_gate.dart';

/// Blocking gate that fires on Home mount when the device has NO
/// working step source at all — hardware pedometer unavailable AND
/// Health Connect empty AND Google Fit fallback either off or empty.
///
/// This is the "we literally cannot see any steps" case, distinct from
/// [NoStepsBanner] which shows a soft nudge when sources exist but
/// haven't produced yet. Product decision: users in the truly-no-source
/// state cannot use Home usefully, so we present a modal with the ONLY
/// action being "Set up" — no dismiss, no barrier tap, no back-button
/// escape. The gate re-fires immediately if the user returns from the
/// setup flow without a working source.
///
/// Trigger predicate (all must hold):
///   1. Native pedometer: not available (missing sensor or ACTIVITY
///      RECOGNITION permission denied).
///   2. Health Connect: today's steps == 0 (with no error surfaced
///      would mean HC has no feeder app pushing into it).
///   3. Google Fit: fallback disabled OR (enabled but returned null / 0
///      today).
///
/// Wrap the Home screen body with this widget; it's invisible when the
/// predicate is false and takes over the screen when it's true.
class NoSourceGate extends ConsumerStatefulWidget {
  final Widget child;
  const NoSourceGate({super.key, required this.child});

  /// True while the "No step data" hard-blocker dialog is on screen.
  /// Other post-onboarding surfaces (currently
  /// [DeviceConnectPromptSheet]) listen to this so they don't fire
  /// their sheet on top of a modal the user must resolve first. Same
  /// pattern as [PermissionGate.primerOpen].
  static final ValueNotifier<bool> blockerOpen = ValueNotifier<bool>(false);

  @override
  ConsumerState<NoSourceGate> createState() => _NoSourceGateState();
}

class _NoSourceGateState extends ConsumerState<NoSourceGate>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // First check runs after the first frame commits so `showDialog`
    // has a valid Overlay context.
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    // Re-poll while on Home so an OS-level permission toggle (user
    // grants ACTIVITY_RECOGNITION in Settings, then swipes back) is
    // reflected quickly.
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _check());
    // Watch the primer dialog's visibility so we can fire our own
    // dialog the moment it closes — see fix note in [_check]. On a
    // fresh install the primer typically shows first (activity
    // recognition denied); when the user resolves it (Grant All →
    // sources light up, no dialog needed; OR Later → 24h cooldown, we
    // become the only modal wanting to show), we re-check without
    // waiting for the 15 s tick.
    PermissionGate.primerOpen.addListener(_onPrimerVisibilityChange);
    // Same treatment for the health-setup screen: re-check the moment
    // the user leaves it, so the blocker returns promptly if they
    // walked away without actually fixing anything.
    HealthSetupScreen.isOpen.addListener(_onHealthSetupVisibilityChange);
  }

  /// Fires when the health-setup screen opens or closes. Only the
  /// closed transition matters — see the deferral note in [_check].
  void _onHealthSetupVisibilityChange() {
    if (!HealthSetupScreen.isOpen.value) _check();
  }

  /// Fires whenever [PermissionGate.primerOpen] changes value. We only
  /// care about the open→closed transition (fire our own check); the
  /// closed→open transition is handled inside [_check] itself.
  void _onPrimerVisibilityChange() {
    if (!PermissionGate.primerOpen.value) _check();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check on foreground — a user who taps Set up, grants a
    // permission, then swipes back into StepBattle should see the
    // gate lift or re-fire immediately.
    if (state == AppLifecycleState.resumed) _check();
  }

  @override
  void dispose() {
    _timer?.cancel();
    PermissionGate.primerOpen.removeListener(_onPrimerVisibilityChange);
    HealthSetupScreen.isOpen.removeListener(_onHealthSetupVisibilityChange);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _check() async {
    if (!mounted || _dialogOpen) return;
    // Defer while the "Almost Ready!" permission primer is on screen.
    // If we fired our own dialog now, [showDialog(useRootNavigator:true)]
    // would stack it on top of the shell-Navigator primer — the user
    // sees our Set up button but tapping it can't complete the route
    // push because the primer's still-modal barrier below intercepts.
    // The listener on PermissionGate.primerOpen re-triggers _check the
    // moment the primer closes, so waiting is safe.
    if (PermissionGate.primerOpen.value) return;

    // Defer while the user is ON the health-setup screen (2026-10-31).
    //
    // Without this the gate eats itself: `onSetUp` pops this dialog and
    // pushes /profile/health-setup, the `finally` below clears
    // `_dialogOpen`, `_check()` re-runs immediately, the source is still
    // absent (that's WHY they're going to setup), and the blocker
    // re-opens ON TOP of the setup page. Because the dialog is
    // barrierDismissible:false + canPop:false, that is an unescapable
    // loop — a tester who denied every permission could not reach the
    // one screen able to fix it. The 15 s timer and the `resumed` hook
    // re-armed the trap even after a manual dismiss.
    //
    // `isOpen` is cleared in that screen's dispose, and the listener in
    // initState re-checks on close, so the blocker still re-fires if the
    // user leaves setup without resolving anything.
    if (HealthSetupScreen.isOpen.value) return;

    final aggregator = ref.read(stepAggregatorProvider);
    final native = ref.read(nativeStepServiceProvider);
    final fit = ref.read(googleFitServiceProvider);
    final health = ref.read(healthServiceProvider);
    final reading = await aggregator.readWithDebug();
    if (!mounted) return;

    // ── Availability, NOT step count (rewritten 2026-11-02) ─────────
    //
    // The previous test was:
    //
    //     final hcAbsent = reading.healthConnectSteps == 0;
    //
    // which conflates "no step source configured" with "source works
    // fine, you just haven't walked yet". Those are completely
    // different states and only the first one warrants a hard block.
    //
    // Evidence this was wrong (logs/2026-11-02_09-30-22): a tester with
    // Health, Location, Notifications AND Physical activity all granted
    // was still blocked. health.log showed `getTodaySteps {"steps":0}`
    // at DEBUG on every poll — and that line only executes on the
    // SUCCESS path (HealthService:138). The failure path logs
    // `getTodaySteps:fetchFailed` at WARN, which never appeared. So
    // Health Connect was connected, permitted, and correctly reporting
    // zero. The gate blocked a working app.
    //
    // This hit EVERY user who opened the app before walking — first
    // thing in the morning, or straight after granting permissions.
    //
    // `hasPermissions()` asks Health Connect directly instead of
    // inferring from a number that is legitimately 0 for part of
    // every single day.
    final hcAbsent = !(await health.hasPermissions());
    if (!mounted) return;

    // Native: `isAvailable` is `_hasReading` — "the pedometer stream
    // has produced at least one event". That is false for a few
    // seconds after a cold start even on a perfectly good sensor, so
    // treat a reported error as the real absence signal and let a
    // not-yet-warmed stream count as present.
    final nativeAbsent = !native.isAvailable && reading.nativeError != null;

    // Fit is opt-in. Enabled + non-null means it answered; 0 is a
    // valid answer, same as above.
    final fitAbsent = !fit.isEnabled || reading.googleFitSteps == null;

    if (nativeAbsent && hcAbsent && fitAbsent) {
      AppLogger.step.i('noSourceGate:blocking', fields: {
        'nativeAbsent': nativeAbsent,
        'hcAbsent': hcAbsent,
        'fitAbsent': fitAbsent,
        'nativeError': reading.nativeError ?? 'none',
        'hcSteps': reading.healthConnectSteps,
      });
      _showBlocker();
    }
  }

  Future<void> _showBlocker() async {
    // Under the lock model this dialog does not exist. Home renders with
    // padlocks over the metrics that have no source, which is strictly
    // better than what this did: barrierDismissible:false + canPop:false
    // meant a user who declined the step permission could not reach
    // Settings, could not sign out, and could not delete their account.
    // App Review guideline 5.1.1 expects an app to stay usable when a
    // permission is declined, and a reviewer is exactly the person most
    // likely to decline one and then try to look around.
    //
    // Leaving `blockerOpen` false also keeps the Home coordination intact
    // — the device-connect prompt and XP celebration defer to it, and
    // with no blocker there is nothing for them to wait behind.
    if (CapabilityLocks.enabled) return;
    if (!mounted || _dialogOpen) return;
    _dialogOpen = true;
    // Publish "blocker visible" so post-onboarding sheets defer.
    NoSourceGate.blockerOpen.value = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        useRootNavigator: true,
        builder: (dialogCtx) => PopScope(
          // Hard gate — back-button cannot pop the dialog. The only exit
          // is the Set up button below, which dismisses the dialog before
          // navigating so we don't stack routes.
          canPop: false,
          // ONE action, one path (2026-11-02). A second "Open app
          // settings" button briefly lived here as an escape hatch for
          // the permanentlyDenied case. It was redundant once the
          // health-setup screen grew its own permission card — and
          // actively worse than redundant, because two buttons that
          // both read as "fix this" force a choice the user has no
          // basis to make. The setup screen can read the permission
          // state; the user can't. That decision belongs there.
          child: _NoSourceDialog(
            onSetUp: () {
              Navigator.of(dialogCtx).pop();
              context.push('/profile/health-setup');
            },
          ),
        ),
      );
    } finally {
      _dialogOpen = false;
      NoSourceGate.blockerOpen.value = false;
    }
    // Re-check after the dialog closes / user returns from setup.
    // If the source is still absent the dialog fires again next tick.
    if (mounted) _check();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _NoSourceDialog extends StatelessWidget {
  final VoidCallback onSetUp;
  const _NoSourceDialog({required this.onSetUp});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Dialog(
      backgroundColor: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              width: 56,
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.amber.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.warning_amber_rounded,
                  color: AppColors.amber, size: 30),
            ),
            const SizedBox(height: 16),
            Text(
              'No step data detected',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              "StepBattle can't see any step readings from your device. "
              'Set up a step source to start tracking.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 48,
              child: FilledButton(
                onPressed: onSetUp,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'Set up',
                  style: TextStyle(
                    fontFamily: 'Manrope',
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
