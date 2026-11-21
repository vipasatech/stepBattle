import 'dart:io' show Platform;

import 'package:permission_handler/permission_handler.dart';

/// The OS permission that lets us read the device pedometer.
///
/// The two platforms call this different things, and using the wrong one on
/// iOS fails in the worst possible way — silently.
///
/// **Android** → `Permission.activityRecognition`, the ACTIVITY_RECOGNITION
/// runtime permission. This is what the app has always used.
///
/// **iOS** → `Permission.sensors`, which permission_handler maps to
/// `SensorPermissionStrategy` → CoreMotion → the "Motion & Fitness" toggle.
///
/// Why this file exists (2026-11-20): every call site used
/// `Permission.activityRecognition` unconditionally. Look at
/// permission_handler_apple's `PermissionManager.m` and
/// `PermissionGroupActivityRecognition` has NO case in the strategy switch —
/// it falls through to `default: UnknownPermissionStrategy`. On iOS that
/// means `.status` always reports denied and `.request()` returns denied
/// *without ever presenting a prompt*.
///
/// The visible symptom was a dead end: the app declared motion access
/// blocked, offered "Open Settings", and sent the user to a Settings page
/// with no Motion & Fitness row on it — because iOS only lists a permission
/// once the app has actually asked for it, and we never had.
///
/// Do NOT "simplify" this to `Permission.sensors` on both platforms. On
/// Android that enum maps to BODY_SENSORS (heart rate, ECG), which is a
/// different permission entirely and not one we want or need.
Permission get stepPermission =>
    Platform.isIOS ? Permission.sensors : Permission.activityRecognition;
