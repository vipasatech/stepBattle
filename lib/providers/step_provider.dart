import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/step_log_model.dart';
import '../services/health_service.dart';
import '../services/mission_service.dart';
import '../services/step_service.dart';
import '../services/xp_service.dart';
import 'auth_provider.dart';

/// Health service singleton.
final healthServiceProvider = Provider<HealthService>((ref) {
  return HealthService();
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

/// Today's step count from the device health store (local, polled).
/// Emits immediately, then refreshes every 60 seconds.
/// `HealthService.getTodaySteps()` is monotonic within a day and never
/// returns 0 once a real reading has been captured, so the UI won't
/// flicker even when Health Connect blocks background reads.
final localTodayStepsProvider = StreamProvider<int>((ref) {
  final healthService = ref.read(healthServiceProvider);

  Stream<int> stream() async* {
    // Emit first value immediately (no 60s wait on cold start)
    yield await healthService.getTodaySteps();
    await for (final _ in Stream.periodic(const Duration(seconds: 60))) {
      yield await healthService.getTodaySteps();
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
final stepSyncProvider = FutureProvider.family<void, String>((ref, userId) async {
  final healthService = ref.read(healthServiceProvider);
  final stepService = ref.read(stepServiceProvider);

  final steps = await healthService.getTodaySteps();
  if (steps > 0) {
    await stepService.syncSteps(
      userId: userId,
      steps: steps,
      source: healthService.sourceName,
    );
  }
});

/// Weekly step total from Firestore.
final weeklyStepsProvider = FutureProvider<int>((ref) async {
  final authState = ref.watch(authStateProvider);
  final user = authState.valueOrNull;
  if (user == null) return 0;
  return ref.read(stepServiceProvider).getWeeklyTotal(user.uid);
});
