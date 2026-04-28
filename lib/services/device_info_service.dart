import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Lightweight per-device fingerprint for analytics. Cached after first read
/// since `Build.MANUFACTURER` / `Build.MODEL` etc. are immutable.
class DeviceFingerprint {
  final String manufacturer;
  final String model;
  final String osVersion;
  final String appVersion;

  const DeviceFingerprint({
    required this.manufacturer,
    required this.model,
    required this.osVersion,
    required this.appVersion,
  });

  static const empty = DeviceFingerprint(
    manufacturer: 'unknown',
    model: 'unknown',
    osVersion: 'unknown',
    appVersion: '0.0.0',
  );
}

class DeviceInfoService {
  DeviceFingerprint? _cached;

  /// Read once, cache forever. Safe to call from any thread; concurrent
  /// callers all await the same lookup.
  Future<DeviceFingerprint> getFingerprint() async {
    if (_cached != null) return _cached!;

    String manufacturer = 'unknown';
    String model = 'unknown';
    String osVersion = 'unknown';

    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final info = await plugin.androidInfo;
        manufacturer = info.manufacturer.toLowerCase();
        model = info.model;
        osVersion = 'Android ${info.version.release} (SDK ${info.version.sdkInt})';
      } else if (Platform.isIOS) {
        final info = await plugin.iosInfo;
        manufacturer = 'apple';
        model = info.utsname.machine;
        osVersion = 'iOS ${info.systemVersion}';
      }
    } catch (_) {
      // Plugin unavailable — fall through with defaults.
    }

    String appVersion = '0.0.0';
    try {
      final pkg = await PackageInfo.fromPlatform();
      appVersion = '${pkg.version}+${pkg.buildNumber}';
    } catch (_) {}

    _cached = DeviceFingerprint(
      manufacturer: manufacturer,
      model: model,
      osVersion: osVersion,
      appVersion: appVersion,
    );
    return _cached!;
  }
}
