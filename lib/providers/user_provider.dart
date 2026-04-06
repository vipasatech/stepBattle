import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/constants.dart';
import '../models/user_model.dart';
import '../services/xp_service.dart';
import 'auth_provider.dart';

/// XP service singleton.
final xpServiceProvider = Provider<XPService>((ref) {
  return XPService();
});

/// The current user's Firestore profile (re-exported from auth for convenience).
/// Use this in UI to get level, XP, streak, rank, goal, etc.
final userProfileProvider = StreamProvider<UserModel?>((ref) {
  final authState = ref.watch(authStateProvider);
  final user = authState.valueOrNull;
  if (user == null) return Stream.value(null);
  return ref.read(authServiceProvider).watchUser(user.uid);
});

/// Current level derived from user profile.
final userLevelProvider = Provider<int>((ref) {
  final profile = ref.watch(userProfileProvider).valueOrNull;
  if (profile == null) return 1;
  return AppConstants.levelForXP(profile.totalXP);
});

/// Progress fraction (0.0–1.0) within the current level.
final levelProgressProvider = Provider<double>((ref) {
  final profile = ref.watch(userProfileProvider).valueOrNull;
  if (profile == null) return 0.0;
  return AppConstants.levelProgress(profile.totalXP);
});

/// Steps remaining to reach next level.
final xpToNextLevelProvider = Provider<int>((ref) {
  final profile = ref.watch(userProfileProvider).valueOrNull;
  if (profile == null) return 0;
  return AppConstants.xpToNextLevel(profile.totalXP);
});

/// Daily step goal from user profile.
final dailyGoalProvider = Provider<int>((ref) {
  final profile = ref.watch(userProfileProvider).valueOrNull;
  return profile?.dailyStepGoal ?? AppConstants.defaultDailyStepGoal;
});
