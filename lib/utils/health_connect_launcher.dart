import 'dart:io' show Platform;

import 'package:url_launcher/url_launcher.dart';

import 'app_logger.dart';

/// One-liner API for jumping the user directly to Health Connect (on
/// Android) or the Health app (on iOS) — the fastest path from any
/// "Set up your device" affordance in our UI to the actual OS surface
/// where permissions are granted.
///
/// **Why not use the `health` package?** We already read Health Connect
/// via [HealthService] with our own MethodChannel wiring. Adding
/// another package just to launch a deep link is dead weight; the
/// existing `url_launcher` dependency handles both platforms via
/// well-known URI schemes.
///
/// **Android strategy** — tries in order until one succeeds:
///   1. `market://details?id=com.google.android.apps.healthdata` — if
///      HC is installed this opens the Play Store's HC entry which
///      offers "Open" / "Manage app" affordances that reach the same
///      permissions screen. If HC isn't installed this is the
///      one-tap install path.
///   2. `https://play.google.com/store/apps/details?id=com.google.android.apps.healthdata`
///      — plain https fallback for devices without a Play Store app
///      (rare — e.g., Huawei GMS-less phones).
///
/// **iOS strategy** — opens Apple Health via `x-apple-health://`. Every
/// iPhone ships with Health, so this is a one-hop.
class HealthConnectLauncher {
  HealthConnectLauncher._();

  /// Opens Health Connect on Android or Health on iOS. Returns `true`
  /// if any of the fallbacks succeeded. Callers that want to surface
  /// an error message can use the return value to decide whether to
  /// show a snackbar.
  ///
  /// Fire-and-forget-safe: any launch failures are logged, never
  /// thrown.
  static Future<bool> open() async {
    try {
      if (Platform.isIOS) {
        return await _tryLaunch(Uri.parse('x-apple-health://'));
      }
      // Android — try market:// first (opens Play Store natively),
      // then https fallback.
      final marketUri = Uri.parse(
        'market://details?id=com.google.android.apps.healthdata',
      );
      if (await _tryLaunch(marketUri)) return true;
      final webUri = Uri.parse(
        'https://play.google.com/store/apps/details?id=com.google.android.apps.healthdata',
      );
      return await _tryLaunch(webUri);
    } catch (e, s) {
      AppLogger.permission.w('healthConnectLauncher:openFailed',
          fields: {'err': e.toString()});
      AppLogger.permission
          .e('healthConnectLauncher:openFailed_stack', error: e, stack: s);
      return false;
    }
  }

  static Future<bool> _tryLaunch(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      AppLogger.permission.d('healthConnectLauncher:tryFailed',
          fields: {'uri': uri.toString(), 'err': e.toString()});
      return false;
    }
  }
}
