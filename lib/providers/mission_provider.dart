import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/mission_model.dart';
import '../models/user_mission_progress_model.dart';
import '../services/mission_service.dart';
import 'auth_provider.dart';

/// Mission service singleton.
final missionServiceProvider = Provider<MissionService>((ref) {
  return MissionService();
});

/// Daily mission definitions.
final dailyMissionsProvider = FutureProvider<List<MissionModel>>((ref) {
  return ref.read(missionServiceProvider).getDailyMissions();
});

/// Weekly mission definitions.
final weeklyMissionsProvider = FutureProvider<List<MissionModel>>((ref) {
  return ref.read(missionServiceProvider).getWeeklyMissions();
});

/// Stream of daily mission progress for current user.
final dailyProgressProvider =
    StreamProvider<List<UserMissionProgress>>((ref) {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return Stream.value([]);
  return ref.read(missionServiceProvider).watchDailyProgress(user.uid);
});

/// Stream of weekly mission progress for current user.
final weeklyProgressProvider =
    StreamProvider<List<UserMissionProgress>>((ref) {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return Stream.value([]);
  return ref.read(missionServiceProvider).watchWeeklyProgress(user.uid);
});

/// Number of daily missions completed today.
final completedDailyCountProvider = FutureProvider<int>((ref) async {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return 0;
  return ref.read(missionServiceProvider).completedDailyCount(user.uid);
});

/// Helper: find progress for a specific mission from the progress list.
UserMissionProgress? findProgress(
    List<UserMissionProgress> progressList, String missionId) {
  try {
    return progressList.firstWhere((p) => p.missionId == missionId);
  } catch (_) {
    return null;
  }
}
