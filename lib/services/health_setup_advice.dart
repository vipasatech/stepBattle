import 'device_info_service.dart';

/// Pure mapping from [DeviceFingerprint] to OEM-tailored instructions for
/// getting Health Connect to actually receive step data on this device.
///
/// Why per-OEM: Health Connect on its own doesn't track steps; it's a hub.
/// Each Android OEM ships a different "step source" app (Samsung Health,
/// Mi Fitness, etc.), and the bridge between that app and Health Connect
/// has to be enabled manually. The instructions differ for every OEM.
///
/// Tested on: samsung, xiaomi/redmi, realme, motorola, oppo, oneplus,
/// vivo/iqoo, pixel/google. Falls through to a generic advice for unknown.

enum HealthSourceQuality {
  /// Out-of-the-box or trivial setup (Pixel, modern Samsung).
  excellent,

  /// Has a native step source but user must toggle HC sharing.
  manualToggle,

  /// No reliable native step source pushing to Health Connect — user
  /// likely needs Google Fit fallback or to install something.
  needsThirdParty,

  /// Unknown OEM — generic advice.
  unknown,
}

class HealthSetupAdvice {
  /// Friendly OEM name for display (e.g., "Samsung", "Realme").
  final String oemName;

  /// Name of the recommended step-source app on this device.
  final String oemAppName;

  /// Whether to recommend installing Google Fit as a fallback.
  final bool recommendGoogleFitFallback;

  /// Whether the user likely needs to install the Health Connect Play
  /// Store app (true on Android <14 where it isn't a system service).
  final bool needsHealthConnectInstall;

  /// 1-line headline for the banner / wizard step.
  final String headline;

  /// Step-by-step instructions, each one a short sentence the user can
  /// follow without screenshots.
  final List<String> steps;

  /// Optional Play Store URL for the OEM step app (used as install CTA
  /// when the app isn't preinstalled or has gone missing).
  final String? oemAppPlayStoreUrl;

  final HealthSourceQuality quality;

  const HealthSetupAdvice({
    required this.oemName,
    required this.oemAppName,
    required this.recommendGoogleFitFallback,
    required this.needsHealthConnectInstall,
    required this.headline,
    required this.steps,
    required this.quality,
    this.oemAppPlayStoreUrl,
  });

  /// Compute the right advice for this device.
  static HealthSetupAdvice forDevice(DeviceFingerprint fp) {
    final manufacturer = fp.manufacturer.toLowerCase();
    final api = _androidApiLevel(fp.osVersion);
    final needsHcInstall = api > 0 && api < 34; // pre-Android-14

    return switch (manufacturer) {
      'samsung' => HealthSetupAdvice(
          oemName: 'Samsung',
          oemAppName: 'Samsung Health',
          recommendGoogleFitFallback: false,
          needsHealthConnectInstall: needsHcInstall,
          quality: HealthSourceQuality.manualToggle,
          headline:
              'Connect Samsung Health to share your steps with StepBattle.',
          steps: [
            'Open the Samsung Health app.',
            'Tap the menu icon, then go to Settings.',
            'Tap "Health Connect" (under Data permissions).',
            'Toggle on "Steps" and "Active calories burned".',
          ],
        ),
      'xiaomi' || 'redmi' || 'poco' => HealthSetupAdvice(
          oemName: 'Xiaomi',
          oemAppName: 'Mi Fitness',
          // Same note as above — the Fit REST fallback is retired. Field
  // kept as false to hide the CTA everywhere.
  recommendGoogleFitFallback: false,
          needsHealthConnectInstall: needsHcInstall,
          quality: HealthSourceQuality.manualToggle,
          headline: 'Enable Mi Fitness to feed Health Connect on your '
              '${fp.manufacturer.isNotEmpty ? fp.manufacturer : "Xiaomi"} device.',
          steps: [
            'Make sure Mi Fitness is installed (search Play Store).',
            'Open Mi Fitness, then go to Profile → Settings.',
            'Tap "Health Connect" and enable Steps sharing.',
            "If you don't see this option, install Google Fit from "
                "the Play Store, sign in, and let it push data to "
                "Health Connect (Fit's Settings → Manage connected "
                "apps → Health Connect).",
          ],
          oemAppPlayStoreUrl:
              'https://play.google.com/store/apps/details?id=com.mi.health',
        ),
      'realme' || 'oppo' => HealthSetupAdvice(
          oemName: fp.manufacturer == 'realme' ? 'Realme' : 'OPPO',
          oemAppName: 'OPPO/Realme Health',
          // Historically recommended enabling the built-in Google Fit REST
  // fallback. Google retired the Fit REST API on 2026-06-30 → the
  // in-app toggle is now dead and the toggle is disabled UI-side
  // (see step_sources_screen.dart). Kept the field for schema
  // stability but forced to false so nothing surfaces the CTA.
  recommendGoogleFitFallback: false,
          needsHealthConnectInstall: needsHcInstall,
          quality: api >= 34
              ? HealthSourceQuality.manualToggle
              : HealthSourceQuality.needsThirdParty,
          headline:
              'Your phone needs a step source connected to Health Connect.',
          steps: [
            if (api >= 34)
              'Open OPPO/Realme Health (or Google Fit) and enable "Health Connect" sharing for Steps.',
            'If OPPO/Realme Health doesn\'t offer Health Connect '
                'sharing, install Google Fit and enable Fit → '
                'Settings → Manage connected apps → Health Connect. '
                'That bridges into StepBattle.',
            'Make sure StepBattle has Steps permission in Health Connect.',
          ],
        ),
      'motorola' => const HealthSetupAdvice(
          oemName: 'Motorola',
          oemAppName: 'Google Fit',
          // Historically recommended enabling the built-in Google Fit REST
  // fallback. Google retired the Fit REST API on 2026-06-30 → the
  // in-app toggle is now dead and the toggle is disabled UI-side
  // (see step_sources_screen.dart). Kept the field for schema
  // stability but forced to false so nothing surfaces the CTA.
  recommendGoogleFitFallback: false,
          needsHealthConnectInstall: false,
          quality: HealthSourceQuality.needsThirdParty,
          // Motorola phones DO have a hardware pedometer — we can read
          // TYPE_STEP_COUNTER directly. What they lack is a preinstalled
          // step-tracking APP (like Samsung Health or Mi Fitness) that
          // pushes into Health Connect. So Google Fit as the feeder is
          // the shortest path to steady data.
          headline:
              'Motorola phones don\'t ship with a step-tracking app. '
              'Google Fit is the easiest source to add.',
          steps: [
            'Install Google Fit from the Play Store if not already.',
            'Open Google Fit, sign in, walk for a minute so it has data.',
            'In Fit: Profile → Settings → Manage connected apps → '
                'Connect to Health Connect.',
            'StepBattle then reads your steps via Health Connect '
                'automatically — no toggle needed.',
          ],
          oemAppPlayStoreUrl:
              'https://play.google.com/store/apps/details?id=com.google.android.apps.fitness',
        ),
      'oneplus' => HealthSetupAdvice(
          oemName: 'OnePlus',
          oemAppName: 'OnePlus Health',
          // Same note as above — the Fit REST fallback is retired. Field
  // kept as false to hide the CTA everywhere.
  recommendGoogleFitFallback: false,
          needsHealthConnectInstall: needsHcInstall,
          quality: api >= 34
              ? HealthSourceQuality.manualToggle
              : HealthSourceQuality.needsThirdParty,
          headline: 'Connect OnePlus Health to Health Connect.',
          steps: [
            'Open OnePlus Health.',
            'Settings → Health Connect → enable Steps sharing.',
            'On older OxygenOS versions this option may not exist; '
                'install Google Fit and enable Health Connect sharing '
                'from inside Fit\'s settings — that\'s the reliable '
                'bridge.',
          ],
        ),
      'vivo' || 'iqoo' => HealthSetupAdvice(
          oemName: fp.manufacturer == 'vivo' ? 'Vivo' : 'iQOO',
          oemAppName: 'Vivo Health',
          // Same note as above — the Fit REST fallback is retired. Field
  // kept as false to hide the CTA everywhere.
  recommendGoogleFitFallback: false,
          needsHealthConnectInstall: needsHcInstall,
          quality: api >= 34
              ? HealthSourceQuality.manualToggle
              : HealthSourceQuality.needsThirdParty,
          headline: 'Connect Vivo Health to Health Connect.',
          steps: [
            'Open Vivo/iQOO Health.',
            'Settings → Data sharing → Health Connect → enable Steps.',
            'Older OriginOS versions skip this — install Google Fit '
                'and enable Health Connect sharing inside Fit\'s '
                'settings as the bridge.',
          ],
        ),
      'google' || 'pixel' => const HealthSetupAdvice(
          oemName: 'Pixel',
          oemAppName: 'Google Fit',
          recommendGoogleFitFallback: false,
          needsHealthConnectInstall: false,
          quality: HealthSourceQuality.excellent,
          headline:
              'Pixel uses Health Connect natively. You\'re all set.',
          steps: [
            "Make sure Google Fit (or Fitbit) is installed and tracking.",
            'Health Connect should already see Steps data without extra setup.',
          ],
        ),
      'nothing' => const HealthSetupAdvice(
          oemName: 'Nothing',
          oemAppName: 'Google Fit',
          // Historically recommended enabling the built-in Google Fit REST
  // fallback. Google retired the Fit REST API on 2026-06-30 → the
  // in-app toggle is now dead and the toggle is disabled UI-side
  // (see step_sources_screen.dart). Kept the field for schema
  // stability but forced to false so nothing surfaces the CTA.
  recommendGoogleFitFallback: false,
          needsHealthConnectInstall: false,
          quality: HealthSourceQuality.needsThirdParty,
          headline:
              'Nothing phones rely on Google Fit for step tracking.',
          steps: [
            'Install Google Fit from the Play Store.',
            'Sign in and walk so Fit captures step data.',
            "In Fit: Profile → Settings → Manage connected apps → "
                "Connect to Health Connect. StepBattle picks up your "
                "steps from there.",
          ],
          oemAppPlayStoreUrl:
              'https://play.google.com/store/apps/details?id=com.google.android.apps.fitness',
        ),
      _ => HealthSetupAdvice(
          oemName: fp.manufacturer.isEmpty ? 'your phone' : fp.manufacturer,
          oemAppName: 'a step-source app',
          // Historically recommended enabling the built-in Google Fit REST
  // fallback. Google retired the Fit REST API on 2026-06-30 → the
  // in-app toggle is now dead and the toggle is disabled UI-side
  // (see step_sources_screen.dart). Kept the field for schema
  // stability but forced to false so nothing surfaces the CTA.
  recommendGoogleFitFallback: false,
          needsHealthConnectInstall: needsHcInstall,
          quality: HealthSourceQuality.unknown,
          headline:
              'Connect a step-source app to Health Connect.',
          steps: [
            "Most Android phones ship with a built-in fitness app — "
                "open yours and look for a 'Health Connect' setting.",
            'If yours doesn\'t support Health Connect, install Google Fit.',
            "Inside Fit: Profile → Settings → Manage connected apps → "
                "Connect to Health Connect. StepBattle then reads "
                "steps via Health Connect automatically.",
          ],
        ),
    };
  }
}

/// Parses "Android 13 (SDK 33)" → 33, "Android 14" → 34, "iOS 18" → -1.
int _androidApiLevel(String osVersion) {
  final match = RegExp(r'SDK\s*(\d+)').firstMatch(osVersion);
  if (match != null) return int.tryParse(match.group(1)!) ?? 0;
  // Fallback: estimate from Android version number.
  final m = RegExp(r'Android\s*(\d+)').firstMatch(osVersion);
  if (m != null) {
    final v = int.tryParse(m.group(1)!) ?? 0;
    return v + 20; // Android 13 ≈ SDK 33, Android 14 ≈ 34, etc.
  }
  return 0;
}
