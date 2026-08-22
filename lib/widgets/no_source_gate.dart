import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../config/colors.dart';
import '../providers/step_provider.dart';

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
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _check() async {
    if (!mounted || _dialogOpen) return;
    final aggregator = ref.read(stepAggregatorProvider);
    final native = ref.read(nativeStepServiceProvider);
    final fit = ref.read(googleFitServiceProvider);
    final reading = await aggregator.readWithDebug();
    if (!mounted) return;

    final nativeAbsent = !native.isAvailable;
    final hcAbsent = reading.healthConnectSteps == 0;
    final fitAbsent = !fit.isEnabled ||
        reading.googleFitSteps == null ||
        reading.googleFitSteps == 0;

    if (nativeAbsent && hcAbsent && fitAbsent) {
      _showBlocker();
    }
  }

  Future<void> _showBlocker() async {
    if (!mounted || _dialogOpen) return;
    _dialogOpen = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (dialogCtx) => PopScope(
        // Hard gate — back-button cannot pop the dialog. The only exit
        // is the Set up button below, which dismisses the dialog before
        // navigating so we don't stack routes.
        canPop: false,
        child: _NoSourceDialog(
          onSetUp: () {
            Navigator.of(dialogCtx).pop();
            context.push('/profile/health-setup');
          },
        ),
      ),
    );
    _dialogOpen = false;
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
