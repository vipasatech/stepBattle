import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../config/colors.dart';
import '../../utils/health_connect_launcher.dart';

/// Per-brand short setup guide. Fired from the device-connect prompt
/// sheet's brand chip picker. Renders a 3-step instruction list tuned
/// for that brand's companion app + a primary "Open Health Connect"
/// CTA that deep-links via [HealthConnectLauncher].
///
/// Kept as a single screen with a `brand` param (rather than one file
/// per brand) so adding a new brand is one entry in [_catalog] instead
/// of a new route + widget. All copy lives here — no per-brand assets
/// needed, matching the design's zero-asset constraint.
class BrandSetupScreen extends StatelessWidget {
  final String brandId;
  const BrandSetupScreen({super.key, required this.brandId});

  /// Copy catalog. Keys are the URL slug (`samsung`, `fitbit`, `boat`,
  /// `xiaomi`, `wearos`, `other`). Adding a brand: drop a new entry.
  ///
  /// Instructions are intentionally short (3 steps max) and phrased
  /// as verbs. If a brand's companion app doesn't feed Health Connect
  /// at all, we still list the workaround (a bridge app like Health
  /// Sync) so the screen never dead-ends with "sorry".
  static const Map<String, _BrandGuide> _catalog = {
    'samsung': _BrandGuide(
      name: 'Samsung Galaxy Watch / Buds',
      icon: Icons.watch,
      appName: 'Samsung Health',
      steps: [
        'Open the Samsung Health app on this phone',
        'Tap Menu (☰) → Settings → Health Connect',
        'Toggle Steps and Active calories burned to ON',
      ],
      note:
          'Once Samsung Health writes to Health Connect, your Watch\'s '
          'steps flow into StepBattle within a minute.',
      hcSupported: true,
    ),
    'fitbit': _BrandGuide(
      name: 'Fitbit',
      icon: Icons.fitness_center,
      appName: 'Fitbit',
      steps: [
        'Open the Fitbit app',
        'Tap the You icon → Settings → Health Connect',
        'Sign in and grant Steps + Active calories permission',
      ],
      note:
          'Fitbit needs a Google account link inside their app first — '
          'the Fitbit app will prompt you if you haven\'t done it yet.',
      hcSupported: true,
    ),
    'boat': _BrandGuide(
      name: 'boAt Watch',
      icon: Icons.watch,
      appName: 'boAt Wave / boAt Wearables',
      steps: [
        'Open the boAt Wave (or boAt Wearables) app',
        'Look for Google Fit / Health Connect toggle in Settings',
        'If the toggle exists, enable it — data flows in a minute',
      ],
      note:
          'Heads up — many boAt models don\'t yet push to Health Connect. '
          'If the toggle isn\'t there, your phone\'s built-in step counter '
          'still catches steps taken while your phone is with you. Only '
          'workouts done with just the watch will be missing.',
      hcSupported: false,
    ),
    'xiaomi': _BrandGuide(
      name: 'Xiaomi Mi Band / Redmi Watch',
      icon: Icons.watch,
      appName: 'Mi Fitness',
      steps: [
        'Open the Mi Fitness (or Zepp Life) app',
        'Profile → Add accounts → Google Fit / Health Connect',
        'Grant Steps and Activity permission',
      ],
      note:
          'Some older Mi Band models only support Google Fit — that\'s '
          'still readable by StepBattle. Health Connect works for the '
          'newer Mi Band 8 / Redmi Watch lineup.',
      hcSupported: true,
    ),
    'wearos': _BrandGuide(
      name: 'Wear OS / Pixel Watch',
      icon: Icons.watch,
      appName: 'Fitbit or Google Fit (on the watch)',
      steps: [
        'On the Wear OS watch, open Fitbit (Pixel Watch 2/3) or '
        'Google Fit (older models)',
        'On the phone, open the same app and sign in with the '
        'same Google account',
        'Grant Health Connect permission when prompted',
      ],
      note:
          'Wear OS + Health Connect is the smoothest path on Android — '
          'once linked, workouts sync within seconds of finishing.',
      hcSupported: true,
    ),
    'other': _BrandGuide(
      name: 'Other device',
      icon: Icons.help_outline,
      appName: 'the device\'s companion app',
      steps: [
        'Open the app that came with your device',
        'Look for a Google Fit or Health Connect integration in '
        'Settings',
        'Grant Steps and Activity permission',
      ],
      note:
          'If your device doesn\'t offer a Health Connect option, try '
          'the free Health Sync bridge app on the Play Store — it '
          'copies data from most brands into Health Connect.',
      hcSupported: false,
    ),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final guide = _catalog[brandId] ?? _catalog['other']!;

    return Scaffold(
      appBar: AppBar(
        title: Text(guide.name),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Hero — brand icon on a soft violet disc.
              Center(
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    guide.icon,
                    color: AppColors.primary,
                    size: 36,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Set up ${guide.name}',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'A few taps inside ${guide.appName} and your steps '
                'flow into StepBattle.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 24),
              // Numbered steps — matches the pattern used in the
              // existing health_setup_screen so the two surfaces read
              // as the same design family.
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: scheme.onSurface.withValues(alpha: 0.06),
                  ),
                ),
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  children: [
                    for (int i = 0; i < guide.steps.length; i++)
                      _StepRow(
                        number: i + 1,
                        text: guide.steps[i],
                        isLast: i == guide.steps.length - 1,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Amber-tinted note — surfaces the "may not work" case
              // (boAt) or the "extra step required" case (Fitbit).
              // Non-blocking; not the primary attention target.
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: (guide.hcSupported
                          ? AppColors.primary
                          : AppColors.amber)
                      .withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: (guide.hcSupported
                            ? AppColors.primary
                            : AppColors.amber)
                        .withValues(alpha: 0.30),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      guide.hcSupported
                          ? Icons.info_outline_rounded
                          : Icons.warning_amber_rounded,
                      color: guide.hcSupported
                          ? AppColors.primary
                          : AppColors.amber,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        guide.note,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurface,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              // Primary CTA — deep-links straight into Health Connect
              // (or the Play Store install page if HC isn't installed
              // yet). Removes the "which app do I open first?" friction.
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    final ok = await HealthConnectLauncher.open();
                    if (!context.mounted) return;
                    if (!ok) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            "Couldn't open Health Connect. Install it "
                            'from the Play Store and try again.',
                          ),
                        ),
                      );
                    }
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    minimumSize: const Size.fromHeight(52),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Open Health Connect',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Icon(Icons.open_in_new,
                          size: 18, color: Colors.white),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // Secondary — for users who want the full advice screen
              // (Google Fit fallback, OEM-specific tips, etc.). Same
              // route the top-level Settings row uses.
              TextButton(
                onPressed: () => context.push('/profile/health-setup'),
                child: Text(
                  'See all step-tracking options',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w700,
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

class _BrandGuide {
  final String name;
  final IconData icon;
  final String appName;
  final List<String> steps;
  final String note;
  final bool hcSupported;
  const _BrandGuide({
    required this.name,
    required this.icon,
    required this.appName,
    required this.steps,
    required this.note,
    required this.hcSupported,
  });
}

class _StepRow extends StatelessWidget {
  final int number;
  final String text;
  final bool isLast;
  const _StepRow({
    required this.number,
    required this.text,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 12, 14, isLast ? 12 : 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              '$number',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                text,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurface,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
