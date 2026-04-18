import 'package:health/health.dart';
import 'package:permission_handler/permission_handler.dart';

/// Central permission manager.
/// - Health Connect (steps, calories) — via `health` package
/// - Notifications — via `permission_handler`
/// - Activity recognition (required for step data on Android)
class PermissionService {
  final Health _health = Health();

  static const List<HealthDataType> _healthTypes = [
    HealthDataType.STEPS,
    HealthDataType.ACTIVE_ENERGY_BURNED,
  ];

  /// Check all required permissions. Returns map of what's granted.
  Future<PermissionSummary> checkAll() async {
    final health = await _checkHealth();
    final notifications = await Permission.notification.isGranted;
    final activity = await Permission.activityRecognition.isGranted;

    return PermissionSummary(
      health: health,
      notifications: notifications,
      activityRecognition: activity,
    );
  }

  /// Request all permissions in sequence. Shows native OS dialogs.
  Future<PermissionSummary> requestAll() async {
    // 1. Activity recognition (Android 10+) — required for steps
    if (!await Permission.activityRecognition.isGranted) {
      await Permission.activityRecognition.request();
    }

    // 2. Notifications (Android 13+)
    if (!await Permission.notification.isGranted) {
      await Permission.notification.request();
    }

    // 3. Health Connect — triggers in-app permission dialog
    await _requestHealth();

    return checkAll();
  }

  Future<bool> _checkHealth() async {
    try {
      final granted = await _health.hasPermissions(_healthTypes);
      return granted ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _requestHealth() async {
    try {
      final permissions =
          _healthTypes.map((_) => HealthDataAccess.READ).toList();
      final granted = await _health.requestAuthorization(
        _healthTypes,
        permissions: permissions,
      );
      return granted;
    } catch (_) {
      return false;
    }
  }

  /// Open the app settings page (last resort for denied-forever permissions).
  Future<void> openAppSettingsPage() async {
    await openAppSettings();
  }
}

/// Snapshot of all permission states.
class PermissionSummary {
  final bool health;
  final bool notifications;
  final bool activityRecognition;

  const PermissionSummary({
    required this.health,
    required this.notifications,
    required this.activityRecognition,
  });

  /// All critical permissions granted?
  bool get allGranted => health && activityRecognition;

  /// Any permissions missing?
  bool get anyMissing => !allGranted;
}
