import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/step_log_model.dart';
import '../services/device_info_service.dart';
import '../services/google_fit_service.dart';
import '../services/health_service.dart';
import '../services/mission_service.dart';
import '../services/native_step_service.dart';
import '../services/source_step_hourly_log_service.dart';
import '../services/step_service.dart';
import '../services/step_source_aggregator.dart';
import '../services/xp_service.dart';
import 'auth_provider.dart';

/// Health service singleton.
final healthServiceProvider = Provider<HealthService>((ref) {
  return HealthService();
});

/// Hardware pedometer service. Subscribes to TYPE_STEP_COUNTER (Android) /
/// CMPedometer (iOS), persists daily baseline + reboot deltas in Hive.
/// Always-on once `ACTIVITY_RECOGNITION` is granted.
final nativeStepServiceProvider = Provider<NativeStepService>((ref) {
  final svc = NativeStepService();
  // Fire-and-forget startup. If permissions aren't granted yet the service
  // no-ops; call `restartNativeStepServiceProvider` after granting.
  svc.start();
  ref.onDispose(svc.stop);
  return svc;
});

/// Re-arm the native step subscription after a permission grant.
final restartNativeStepServiceProvider =
    Provider<Future<void> Function()>((ref) {
  return () async {
    final svc = ref.read(nativeStepServiceProvider);
    await svc.stop();
    await svc.start();
  };
});

/// Google Fit REST fallback. Default OFF; user opts in from Profile →
/// Step Sources → "Use Google Fit as a fallback". Lazily requests the
/// `fitness.activity.read` OAuth scope on enable.
final googleFitServiceProvider = Provider<GoogleFitService>((ref) {
  return GoogleFitService();
});

/// Aggregates native + Health Connect + Google Fit behind a single API.
/// Max-of-sources policy lives inside; rest of the app shouldn't care
/// which source produced the number.
final stepAggregatorProvider = Provider<StepSourceAggregator>((ref) {
  final native = ref.watch(nativeStepServiceProvider);
  final hc = ref.watch(healthServiceProvider);
  final fit = ref.watch(googleFitServiceProvider);
  return StepSourceAggregator(
    native: native,
    healthService: hc,
    googleFit: fit,
  );
});

/// Device fingerprint singleton (manufacturer, model, OS, app version).
/// Cached after first read.
final deviceInfoServiceProvider = Provider<DeviceInfoService>((ref) {
  return DeviceInfoService();
});

/// Service that persists per-source hourly snapshots to Firestore.
/// Throttles intra-hour writes (~10 min) so we don't burn quota.
final sourceStepHourlyLogServiceProvider =
    Provider<SourceStepHourlyLogService>((ref) {
  return SourceStepHourlyLogService(
    deviceInfo: ref.watch(deviceInfoServiceProvider),
  );
});

/// Step service singleton — depends on MissionService and XPService
/// for fan-out propagation.
final stepServiceProvider = Provider<StepService>((ref) {
  return StepService(
    missionService: MissionService(),
    xpService: XPService(),
  );
});

/// Whether health permissions have been granted.
final healthPermissionProvider = FutureProvider<bool>((ref) {
  return ref.read(healthServiceProvider).hasPermissions();
});

/// Today's step count, polled from the StepSourceAggregator.
/// Emits immediately on subscribe, then every 60s.
///
/// The aggregator returns `max(native, healthConnect)` so:
///   - On Samsung with HC sharing on: usually HC wins (has full history).
///   - On Realme/Motorola or fresh installs: native sensor wins (HC is empty).
///   - During the 1–15 min window after Samsung Health pushes a batch,
///     whichever is fresher wins.
///
/// `HealthService.getTodaySteps()` is monotonic within a day and never
/// returns 0 once a real reading has been captured, so the UI doesn't
/// flicker even when Health Connect blocks background reads.
final localTodayStepsProvider = StreamProvider<int>((ref) {
  final aggregator = ref.read(stepAggregatorProvider);

  Stream<int> stream() async* {
    // Emit first value immediately (no 60s wait on cold start)
    yield await aggregator.getTodaySteps();
    await for (final _ in Stream.periodic(const Duration(seconds: 60))) {
      yield await aggregator.getTodaySteps();
    }
  }

  return stream().distinct();
});

/// Today's calories (from health store or estimated).
final todayCaloriesProvider = FutureProvider<double>((ref) {
  return ref.read(healthServiceProvider).getTodayCalories();
});

/// Today's step log from Firestore (real-time, reflects server state).
final firestoreTodayStepsProvider = StreamProvider<StepLogModel?>((ref) {
  final authState = ref.watch(authStateProvider);
  final user = authState.valueOrNull;
  if (user == null) return Stream.value(null);
  return ref.read(stepServiceProvider).watchTodaySteps(user.uid);
});

/// Combined "best available" today step count:
/// Uses local device steps (freshest), falls back to Firestore.
final todayStepsProvider = Provider<int>((ref) {
  final local = ref.watch(localTodayStepsProvider);
  final firestore = ref.watch(firestoreTodayStepsProvider);

  return local.when(
    data: (steps) => steps,
    loading: () => firestore.valueOrNull?.stepCount ?? 0,
    error: (_, __) => firestore.valueOrNull?.stepCount ?? 0,
  );
});

/// Trigger a sync of device steps to Firestore. Call this periodically.
/// Two writes per call:
///   1. `step_logs/{userId}_{date}` — daily aggregate (existing) + fan-out
///      to missions/battles/clan as before.
///   2. `source_step_hourly/{userId}_{hourKey}` — per-source breakdown
///      for analytics, throttled to ~6 writes/hour. See
///      [SourceStepHourlyLogService.maybeLog].
final stepSyncProvider = FutureProvider.family<void, String>((ref, userId) async {
  final aggregator = ref.read(stepAggregatorProvider);
  final healthService = ref.read(healthServiceProvider);
  final stepService = ref.read(stepServiceProvider);
  final hourlyLog = ref.read(sourceStepHourlyLogServiceProvider);

  final reading = await aggregator.readWithDebug();
  final steps = reading.aggregate;

  // Always log the per-source breakdown (even at 0 steps) so analytics
  // can detect "users whose every source is empty" (the hardest debugging
  // case — usually missing Health Connect feeder).
  await hourlyLog.maybeLog(userId: userId, reading: reading);

  if (steps > 0) {
    // Source label reflects which path produced the winning value.
    final source = _winningSourceLabel(reading, healthService);
    await stepService.syncSteps(
      userId: userId,
      steps: steps,
      source: source,
    );
  }
});

String _winningSourceLabel(StepReading r, HealthService hc) {
  if (r.aggregate <= 0) return 'none';
  final fit = r.googleFitSteps ?? -1;
  if (fit >= r.aggregate && fit > 0) return 'google_fit';
  if (r.healthConnectSteps == r.aggregate) return hc.sourceName;
  return 'native_pedometer';
}

/// Weekly step total from Firestore.
final weeklyStepsProvider = FutureProvider<int>((ref) async {
  final authState = ref.watch(authStateProvider);
  final user = authState.valueOrNull;
  if (user == null) return 0;
  return ref.read(stepServiceProvider).getWeeklyTotal(user.uid);
});
