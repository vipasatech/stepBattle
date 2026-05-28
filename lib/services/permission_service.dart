import 'package:health/health.dart';
import 'package:permission_handler/permission_handler.dart';
import '../utils/app_logger.dart';

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

    final summary = PermissionSummary(
      health: health,
      notifications: notifications,
      activityRecognition: activity,
    );
    AppLogger.permission.i('checkAll', fields: {
      'health': health,
      'notifications': notifications,
      'activityRecognition': activity,
      'allGranted': summary.allGranted,
    });
    return summary;
  }

  /// Request all permissions in sequence. Shows native OS dialogs.
  Future<PermissionSummary> requestAll() async {
    AppLogger.permission.i('requestAll:start');
    // 1. Activity recognition (Android 10+) — required for steps
    if (!await Permission.activityRecognition.isGranted) {
      final status = await Permission.activityRecognition.request();
      AppLogger.permission
          .i('activityRecognition:request', fields: {'status': status.name});
    }

    // 2. Notifications (Android 13+)
    if (!await Permission.notification.isGranted) {
      final status = await Permission.notification.request();
      AppLogger.permission
          .i('notification:request', fields: {'status': status.name});
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
      AppLogger.permission
          .i('health:request', fields: {'granted': granted});
      return granted;
    } catch (e, s) {
      AppLogger.permission.e('health:request:failed', error: e, stack: s);
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
