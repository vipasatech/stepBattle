import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../utils/step_permission.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../config/colors.dart';
import '../../providers/step_provider.dart';
import '../../services/health_setup_advice.dart';
import '../../services/native_step_service.dart';
import '../../widgets/shimmer_loader.dart';

/// Detects the device's OEM and walks the user through the exact toggle
/// they need to flip to get Health Connect receiving step data.
///
/// Shown ONCE after the user completes initial permission grants. The
/// `health_setup_seen` flag in the `step_tracker` Hive box gates re-showing
/// it on subsequent launches — but the screen is also reachable from
/// Profile → "How my steps are tracked" → "View setup guide" if the user
/// wants to revisit it.
class HealthSetupScreen extends ConsumerStatefulWidget {
  /// When true, this screen is being shown as part of the *first-run*
  /// onboarding flow and should mark itself "seen" on dismiss. When false
  /// (revisited from Profile), no flag is touched.
  final bool isFirstRun;

  const HealthSetupScreen({super.key, this.isFirstRun = false});

  /// Hive flag key — also used by `shouldShowFirstRunWizard()`.
  static const String seenFlagKey = 'health_setup_seen';

  /// Whether the first-run wizard should fire. False once the user has
  /// dismissed it once.
  static bool shouldShowFirstRunWizard() {
    final box = Hive.box(NativeStepService.boxName);
    return (box.get(seenFlagKey) as bool? ?? false) == false;
  }

  static Future<void> markSeen() async {
    final box = Hive.box(NativeStepService.boxName);
    await box.put(seenFlagKey, true);
  }

  /// True while this screen is on-screen. [NoSourceGate] watches it and
  /// suppresses its "No step data detected" blocker for the duration —
  /// otherwise the blocker re-fires the moment it pushes the user HERE
  /// and covers the one screen that can resolve it. Same static-notifier
  /// pattern as `PermissionGate.primerOpen` / `NoSourceGate.blockerOpen`.
  /// Added 2026-10-31 after a tester denied every permission and got
  /// trapped in an unescapable dialog loop.
  static final ValueNotifier<bool> isOpen = ValueNotifier<bool>(false);

  @override
  ConsumerState<HealthSetupScreen> createState() =>
      _HealthSetupScreenState();
}

class _HealthSetupScreenState extends ConsumerState<HealthSetupScreen>
    with WidgetsBindingObserver {
  HealthSetupAdvice? _advice;
  bool _enablingFit = false;

  /// Live status of ACTIVITY_RECOGNITION. Null until the first read.
  /// Drives [_ActivityPermissionCard] — without the OS permission, no
  /// amount of Samsung Health / Health Connect wiring produces steps,
  /// so this gates everything else on the screen.
  PermissionStatus? _activityStatus;
  bool _requestingActivity = false;

  @override
  void initState() {
    super.initState();
    HealthSetupScreen.isOpen.value = true;
    WidgetsBinding.instance.addObserver(this);
    _loadAdvice();
    _refreshActivityStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HealthSetupScreen.isOpen.value = false;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The user may have just come back from the system settings page
    // where they flipped Physical activity on. Re-read so the card
    // updates (and disappears) without needing a manual refresh.
    if (state == AppLifecycleState.resumed) _refreshActivityStatus();
  }

  Future<void> _loadAdvice() async {
    final fp = await ref.read(deviceInfoServiceProvider).getFingerprint();
    if (!mounted) return;
    setState(() => _advice = HealthSetupAdvice.forDevice(fp));
  }

  Future<void> _refreshActivityStatus() async {
    final status = await stepPermission.status;
    if (!mounted) return;
    setState(() => _activityStatus = status);
  }

  /// Ask for ACTIVITY_RECOGNITION, or route to App Settings when Android
  /// has stopped showing the system prompt.
  ///
  /// Once a user denies twice (or picks "Don't allow" on Android 11+),
  /// the permission goes `permanentlyDenied` and `request()` returns
  /// INSTANTLY with no visible dialog. That is exactly the "I click Set
  /// up and nothing happens" report — the call succeeded, it just can't
  /// prompt any more. The only recovery is the system settings page.
  Future<void> _requestOrOpenSettings() async {
    if (_requestingActivity) return;
    setState(() => _requestingActivity = true);
    try {
      final current = await stepPermission.status;
      if (current.isPermanentlyDenied || current.isRestricted) {
        await openAppSettings();
        // Status is re-read in didChangeDependencies-equivalent fashion
        // when the user returns; _refreshActivityStatus is also called
        // from the lifecycle hook below.
        return;
      }
      final result = await stepPermission.request();
      if (!mounted) return;
      setState(() => _activityStatus = result);
      if (result.isPermanentlyDenied && mounted) {
        // The request itself flipped it to permanently-denied (user hit
        // "Don't allow" again). Tell them plainly rather than leaving a
        // button that silently does nothing next tap.
        // Platform-split: iOS has no "Physical activity" permission and
        // the settings path differs, so naming Android's sends an iPhone
        // user hunting for a toggle that does not exist. Missed in the
        // first pass at this screen (2026-11-20) because it lives in a
        // snackbar rather than the banner.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              Platform.isIOS
                  ? 'iOS won\'t ask again. Use Open Settings to allow '
                      'Motion & Fitness.'
                  : 'Android won\'t show the prompt again. '
                      'Use Open Settings to allow Physical activity.',
            ),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _requestingActivity = false);
    }
  }

  Future<void> _enableFit() async {
    setState(() => _enablingFit = true);
    final svc = ref.read(googleFitServiceProvider);
    final ok = await svc.setEnabled(true);
    if (!mounted) return;
    setState(() => _enablingFit = false);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(svc.lastError ?? 'Could not enable Google Fit')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Google Fit fallback enabled')),
      );
    }
  }

  Future<void> _dismiss() async {
    if (widget.isFirstRun) {
      await HealthSetupScreen.markSeen();
    }
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final advice = _advice;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _dismiss,
        ),
        title: Text('Step Tracking Setup',
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700)),
      ),
      body: advice == null
          ? ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: const [
                ShimmerLoader(height: 100, borderRadius: 20),
                SizedBox(height: 12),
                ShimmerCard(),
                SizedBox(height: 12),
                ShimmerCard(),
              ],
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                // Sits ABOVE the hero deliberately. Without
                // ACTIVITY_RECOGNITION the phone's pedometer is mute,
                // so no amount of Samsung Health / Health Connect
                // wiring below produces a single step. Fix this first
                // or the rest of the page is wasted effort.
                if (_activityStatus != null && !_activityStatus!.isGranted) ...[
                  _ActivityPermissionCard(
                    status: _activityStatus!,
                    busy: _requestingActivity,
                    onAction: _requestOrOpenSettings,
                  ),
                  const SizedBox(height: 20),
                ],
                _Hero(advice: advice),
                const SizedBox(height: 20),
                _StepList(steps: advice.steps),
                if (advice.needsHealthConnectInstall) ...[
                  const SizedBox(height: 20),
                  _InstallCard(
                    title: 'Install Health Connect',
                    body:
                        'Your Android version doesn\'t include Health Connect '
                        'as a system service. Install the Health Connect app '
                        'from the Play Store — it\'s free and takes a moment.',
                    cta: 'Open Play Store',
                    url:
                        'https://play.google.com/store/apps/details?id=com.google.android.apps.healthdata',
                  ),
                ],
                if (advice.oemAppPlayStoreUrl != null) ...[
                  const SizedBox(height: 12),
                  _InstallCard(
                    title: 'Install ${advice.oemAppName}',
                    body:
                        '${advice.oemAppName} is the recommended step-source '
                        'on your device.',
                    cta: 'Open Play Store',
                    url: advice.oemAppPlayStoreUrl!,
                  ),
                ],
                if (advice.recommendGoogleFitFallback) ...[
                  const SizedBox(height: 12),
                  _FitFallbackCard(
                    enabled: ref.watch(googleFitServiceProvider).isEnabled,
                    busy: _enablingFit,
                    onEnable: _enableFit,
                  ),
                ],
                const SizedBox(height: 28),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () =>
                            context.push('/profile/step-sources'),
                        child: const Text('View live values'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        onPressed: _dismiss,
                        child: Text(widget.isFirstRun ? 'I\'m set' : 'Done'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}

// =============================================================================
// Hero — quality badge + headline
// =============================================================================
class _Hero extends StatelessWidget {
  final HealthSetupAdvice advice;
  const _Hero({required this.advice});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (badgeBg, badgeFg, badgeText, icon) = switch (advice.quality) {
      HealthSourceQuality.excellent => (
          AppColors.success.withValues(alpha: 0.12),
          AppColors.success,
          'Out of the box',
          Icons.check_circle,
        ),
      HealthSourceQuality.manualToggle => (
          AppColors.primary.withValues(alpha: 0.12),
          AppColors.primary,
          'Quick toggle needed',
          Icons.toggle_on,
        ),
      HealthSourceQuality.needsThirdParty => (
          AppColors.amber.withValues(alpha: 0.14),
          AppColors.amber,
          'Setup required',
          Icons.warning_amber,
        ),
      HealthSourceQuality.unknown => (
          AppColors.surfaceContainerHigh,
          AppColors.onSurfaceVariant,
          'Generic guidance',
          Icons.help_outline,
        ),
    };

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: badgeFg.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: badgeBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 14, color: badgeFg),
                    const SizedBox(width: 4),
                    Text(badgeText,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: badgeFg,
                          fontWeight: FontWeight.w800,
                          fontSize: 10,
                          letterSpacing: 0.6,
                        )),
                  ],
                ),
              ),
              const Spacer(),
              Text(advice.oemName,
                  style: theme.textTheme.labelMedium?.copyWith(
                      color: AppColors.onSurfaceVariant,
                      fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 14),
          Text(advice.headline,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700, height: 1.3)),
        ],
      ),
    );
  }
}

// =============================================================================
// Numbered step list
// =============================================================================
class _StepList extends StatelessWidget {
  final List<String> steps;
  const _StepList({required this.steps});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.onSurface.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Steps',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                letterSpacing: 1.5,
              )),
          const SizedBox(height: 8),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    margin: const EdgeInsets.only(top: 2),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text('${i + 1}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w900,
                        )),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(steps[i],
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(height: 1.45)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// =============================================================================
// Install card with Play Store deep-link
// =============================================================================
class _InstallCard extends StatelessWidget {
  final String title;
  final String body;
  final String cta;
  final String url;

  const _InstallCard({
    required this.title,
    required this.body,
    required this.cta,
    required this.url,
  });

  Future<void> _open(BuildContext context) async {
    // Play Store URLs already do the right thing — if the target app is
    // installed the store surfaces its "Open" button; if not, "Install".
    // No need for a market:// scheme.
    //
    // Previous version copied the URL to clipboard because "url_launcher
    // isn't in deps" — that stopped being true when subscriptions shipped
    // and shipped this button as a no-op on Motorola / Xiaomi / Nothing.
    final uri = Uri.parse(url);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open Play Store.')),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open Play Store.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: AppColors.primary.withValues(alpha: 0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.download, size: 16, color: AppColors.primary),
              const SizedBox(width: 6),
              Text(title,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 6),
          Text(body,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppColors.onSurfaceVariant, height: 1.4)),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => _open(context),
              child: Text(cta),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Google Fit fallback card with toggle
// =============================================================================
class _FitFallbackCard extends StatelessWidget {
  final bool enabled;
  final bool busy;
  final VoidCallback onEnable;

  const _FitFallbackCard({
    required this.enabled,
    required this.busy,
    required this.onEnable,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: AppColors.tertiary.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.layers, color: AppColors.tertiary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Google Fit fallback',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  enabled
                      ? 'Enabled. We\'ll use Google Fit if Health Connect is empty.'
                      : 'Recommended for your device. Adds an extra Google permission.',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.onSurfaceVariant, height: 1.4),
                ),
              ],
            ),
          ),
          if (busy)
            SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.primary))
          else if (!enabled)
            FilledButton(
              onPressed: onEnable,
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Enable'),
            )
          else
            const Icon(Icons.check_circle, color: AppColors.success),
        ],
      ),
    );
  }
}

// =============================================================================
// Activity-recognition permission card
// =============================================================================

/// Surfaces a denied ACTIVITY_RECOGNITION permission and offers the ONE
/// action that can actually resolve it from the current state.
///
/// Why this exists (2026-10-31): a tester denied every permission during
/// onboarding and was then trapped. `NoSourceGate` hard-blocks Home with
/// an unescapable "No step data detected" dialog whose only button pushes
/// here — but this screen had no permission handling whatsoever, only
/// Samsung Health / Health Connect / Google Fit wiring. With the OS
/// permission denied, none of those can emit a step, so the blocker
/// re-fired forever.
///
/// The action flips on status because `request()` is a SILENT NO-OP once
/// Android marks the permission permanently denied — showing a "Grant"
/// button there produces a dead tap, which is precisely what the tester
/// reported.
class _ActivityPermissionCard extends StatelessWidget {
  final PermissionStatus status;
  final bool busy;
  final VoidCallback onAction;

  const _ActivityPermissionCard({
    required this.status,
    required this.busy,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // permanentlyDenied → the system prompt is gone for good; Settings
    // is the only route. restricted → parental/device policy, same.
    final needsSettings = status.isPermanentlyDenied || status.isRestricted;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.directions_walk, color: AppColors.error, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  // iOS calls this permission "Motion & Fitness"; there is
                  // no "Physical activity" toggle anywhere on an iPhone, so
                  // naming it that sent users hunting for a setting that
                  // does not exist.
                  Platform.isIOS
                      ? 'Motion & Fitness is blocked'
                      : 'Physical activity is blocked',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AppColors.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            needsSettings
                ? (Platform.isIOS
                    ? 'iOS won\'t ask again because the permission was '
                        'declined. Open Settings → StepBattle → Motion & '
                        'Fitness and turn it on. Nothing below can count '
                        'steps until you do.'
                    : 'Android won\'t show the permission prompt again '
                        'because it was declined. Open Settings → '
                        'Permissions → Physical activity and set it to '
                        'Allow. Nothing below can count steps until you do.')
                : (Platform.isIOS
                    ? 'StepBattle needs Motion & Fitness access to read your '
                        'iPhone\'s step counter. Nothing below can count '
                        'steps until this is allowed.'
                    : 'StepBattle needs the Physical activity permission to '
                        'read your phone\'s step counter. Nothing below can '
                        'count steps until this is allowed.'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppColors.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: FilledButton.icon(
              onPressed: busy ? null : onAction,
              icon: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(needsSettings ? Icons.settings : Icons.check_circle,
                      size: 18),
              label: Text(needsSettings ? 'Open Settings' : 'Allow access'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.error,
                foregroundColor: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
