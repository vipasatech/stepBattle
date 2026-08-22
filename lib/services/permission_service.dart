import 'package:health/health.dart';
import 'package:permission_handler/permission_handler.dart';
import '../utils/app_logger.dart';
import '../utils/permission_coordinator.dart';

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
  ///
  /// Health Connect availability is checked SEPARATELY from grant state.
  /// Some devices (older MIUI/HyperOS, some tablets, Nothing) don't have
  /// Health Connect installable at all. On those we can't grant it, so
  /// including it in the "missing" set would trigger the permission
  /// dialog on every foreground with no way to satisfy it — exactly the
  /// nag testers reported.
  Future<PermissionSummary> checkAll() async {
    final healthAvailable = await _healthConnectAvailable();
    final health = healthAvailable ? await _checkHealth() : false;
    final notifications = await Permission.notification.isGranted;
    final activity = await Permission.activityRecognition.isGranted;

    final summary = PermissionSummary(
      health: health,
      healthConnectAvailable: healthAvailable,
      notifications: notifications,
      activityRecognition: activity,
    );
    AppLogger.permission.i('checkAll', fields: {
      'health': health,
      'healthConnectAvailable': healthAvailable,
      'notifications': notifications,
      'activityRecognition': activity,
      'allGranted': summary.allGranted,
    });
    return summary;
  }

  /// Whether the device even has Health Connect available to grant.
  /// Uses `getHealthConnectSdkStatus()` from the `health` package.
  /// Returns false if the SDK reports unavailable / needs update / any
  /// error — matching the "there's nothing to grant here" cases.
  Future<bool> _healthConnectAvailable() async {
    try {
      final status = await _health.getHealthConnectSdkStatus();
      // Only `sdkAvailable` is truly grantable. `sdkUnavailable` and
      // `sdkUnavailableProviderUpdateRequired` both mean Health Connect
      // isn't usable right now — we shouldn't treat those as "missing
      // permission" and nag the user.
      return status == HealthConnectSdkStatus.sdkAvailable;
    } catch (_) {
      // Any error path — plugin not initialised, platform unsupported,
      // etc. — is treated as "not available."
      return false;
    }
  }

  /// Request all permissions in sequence. Shows native OS dialogs.
  ///
  /// Every request goes through [PermissionCoordinator] so it can't
  /// collide with a parallel request from elsewhere (main-shell's
  /// notification-permission fire on login was the historical culprit —
  /// Android drops one of two concurrent dialogs with "Can request only
  /// one set of permissions at a time" and the dropped one's Future
  /// never resolves, hanging the UI). The coordinator's dedupe means a
  /// second caller for the same permission piggybacks on the same OS
  /// dialog rather than firing a duplicate.
  Future<PermissionSummary> requestAll() async {
    AppLogger.permission.i('requestAll:start');
    // 1. Activity recognition (Android 10+) — required for steps
    if (!await Permission.activityRecognition.isGranted) {
      final status = await PermissionCoordinator.instance.enqueue(
        tag: 'activityRecognition',
        priority: PermissionPriority.activityRecognition,
        action: () => Permission.activityRecognition.request(),
      );
      AppLogger.permission
          .i('activityRecognition:request', fields: {'status': status.name});
    }

    // 2. Notifications (Android 13+)
    if (!await Permission.notification.isGranted) {
      final status = await PermissionCoordinator.instance.enqueue(
        tag: 'notification',
        priority: PermissionPriority.notification,
        action: () => Permission.notification.request(),
      );
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
      // Serialize through the coordinator so a Health Connect dialog
      // can't overlap with an activity/notification dialog. Health
      // Connect launches its own screen (not a native OS dialog) but
      // still counts against Android's "one permission flow at a time"
      // budget in some device flavours.
      final granted = await PermissionCoordinator.instance.enqueue(
        tag: 'health',
        priority: PermissionPriority.health,
        action: () => _health.requestAuthorization(
          _healthTypes,
          permissions: permissions,
        ),
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

  /// Run-specific location flow, called only when the user taps the Track FAB.
  /// We deliberately don't bundle this with the global PermissionGate — most
  /// of the app works without location, and ACCESS_BACKGROUND_LOCATION is a
  /// sensitive permission we only want to ask for when it'll be used.
  ///
  /// Sequence (Android 10+ requirement):
  ///   1. ACCESS_FINE_LOCATION   — foreground GPS access.
  ///   2. ACCESS_BACKGROUND_LOCATION — only after step 1 is granted; lets
  ///      the foreground service keep recording while the screen is off.
  ///
  /// Returns [RunLocationStatus.granted] only when BOTH are granted. The
  /// session can technically run with only foreground granted (it'll pause
  /// recording when the screen turns off), but Strava-style behaviour needs
  /// background.
  Future<RunLocationStatus> requestRunPermissions() async {
    AppLogger.permission.i('requestRunPermissions:start');

    final fine = await Permission.locationWhenInUse.request();
    if (!fine.isGranted) {
      AppLogger.permission
          .w('requestRunPermissions:fineDenied', fields: {'status': fine.name});
      return fine.isPermanentlyDenied
          ? RunLocationStatus.permanentlyDenied
          : RunLocationStatus.denied;
    }

    final background = await Permission.locationAlways.request();
    AppLogger.permission.i('requestRunPermissions:done', fields: {
      'fine': fine.name,
      'background': background.name,
    });
    if (background.isGranted) return RunLocationStatus.granted;
    if (background.isPermanentlyDenied) {
      return RunLocationStatus.foregroundOnlyPermanent;
    }
    return RunLocationStatus.foregroundOnly;
  }
}

/// Outcome of the run-permission flow. The Track FAB / hub uses this to
/// decide whether to start the session, prompt for upgrade, or open settings.
enum RunLocationStatus {
  granted,                    // fine + background — full Strava-like recording
  foregroundOnly,             // fine yes, background no — recording pauses w/ screen off
  foregroundOnlyPermanent,    // background denied forever — needs settings trip
  denied,                     // fine denied this round
  permanentlyDenied,          // fine denied forever — settings trip required
}

/// Snapshot of all permission states.
class PermissionSummary {
  final bool health;
  /// Whether Health Connect is installable on this device at all.
  /// When false, [health] is meaningless and should not gate the
  /// permission dialog — see [allGranted].
  final bool healthConnectAvailable;
  final bool notifications;
  final bool activityRecognition;

  const PermissionSummary({
    required this.health,
    required this.healthConnectAvailable,
    required this.notifications,
    required this.activityRecognition,
  });

  /// Only ACTIVITY_RECOGNITION is compulsory. Health Connect and
  /// Notifications are nice-to-haves that used to gate the dialog and
  /// nag users on every foreground return:
  ///
  ///   • Health Connect — the hardware pedometer already covers step
  ///     tracking. HC only adds value when an OEM app feeds it; the
  ///     Home "From pedometer · tap to set up sync" hint + the
  ///     `/profile/health-setup` guide are the discoverable path for
  ///     users who want richer data. Nagging on every foreground
  ///     because HC isn't connected wasted user attention.
  ///
  ///   • Notifications — desirable for battle invites / reminders but
  ///     never blocks core functionality. Users who denied
  ///     notifications shouldn't see the "Almost ready!" dialog again.
  ///
  /// Trade-off: if activity recognition itself is denied, the dialog
  /// still fires — without it we can't count steps at all.
  bool get allGranted => activityRecognition;

  /// Any permissions missing?
  bool get anyMissing => !allGranted;
}
