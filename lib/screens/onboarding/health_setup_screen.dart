import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';
import '../../config/colors.dart';
import '../../providers/step_provider.dart';
import '../../services/health_setup_advice.dart';
import '../../services/native_step_service.dart';

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

  @override
  ConsumerState<HealthSetupScreen> createState() =>
      _HealthSetupScreenState();
}

class _HealthSetupScreenState extends ConsumerState<HealthSetupScreen> {
  HealthSetupAdvice? _advice;
  bool _enablingFit = false;

  @override
  void initState() {
    super.initState();
    _loadAdvice();
  }

  Future<void> _loadAdvice() async {
    final fp = await ref.read(deviceInfoServiceProvider).getFingerprint();
    if (!mounted) return;
    setState(() => _advice = HealthSetupAdvice.forDevice(fp));
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
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary))
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
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
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
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
    // We don't have url_launcher in deps yet — copy URL to clipboard +
    // toast so user can paste in Play Store. Avoids adding a package
    // just for this one flow.
    await Clipboard.setData(ClipboardData(text: url));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Play Store URL copied to clipboard')),
    );
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
            const SizedBox(
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
