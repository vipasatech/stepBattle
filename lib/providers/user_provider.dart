import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/constants.dart';
import '../services/xp_service.dart';
import 'auth_provider.dart';

/// XP service singleton.
final xpServiceProvider = Provider<XPService>((ref) {
  return XPService();
});

/// The current user's profile row (re-exported from auth for convenience).
/// Use this in UI to get level, XP, streak, goal, etc.
///
/// Cache-then-network: emits the Hive-cached row on cold boot, then
/// live-updates from Supabase's realtime stream.
///
/// This is an **alias** for [currentUserProvider] — Dart's `final` binds
/// the same Provider instance to both names, so Riverpod treats them as
/// one and only opens a single Supabase realtime channel to `profiles`
/// no matter how many screens watch either name. Before this alias,
/// each definition opened its own `.stream('profiles').eq('id', uid)`,
/// which meant every write fanned out twice.
final userProfileProvider = currentUserProvider;

/// Current level — derived from `total_xp` via [AppConstants.levelForXP],
/// with a monotonic floor from any level the server has already stamped
/// on `profiles.level`.
///
/// The prior implementation read `profile.level` directly, which is
/// maintained by the server's activity-score triggers (migration 0050).
/// Two problems made it wrong in practice:
///   1. `activity_score` is not a column on `profiles` (never migrated) —
///      `UserModel.fromSupabaseRow` defaults it to 0. So the client-side
///      progress bar was frozen at Level 1 · 1-to-next for every user
///      regardless of XP earned.
///   2. Even when `profiles.level` DOES get bumped by the server, users
///      who earned XP through Buy XP / battle wins never see their level
///      move until they also complete a battle/mission — the joining
///      bonus at onboarding (500 XP = Level 2) was invisible.
///
/// The client now derives level from XP via [AppConstants.levelThresholds]
/// (Level 2 = 500, Level 3 = 1200, …). The `max(profile.level, …)` guard
/// preserves the server's monotonic invariant: if some future feature
/// stamps `profiles.level` higher than the XP alone would justify, we
/// still respect it — never regress.
final userLevelProvider = Provider<int>((ref) {
  final profile = ref.watch(userProfileProvider).valueOrNull;
  if (profile == null) return 1;
  final xpLevel = AppConstants.levelForXP(profile.totalXP);
  return xpLevel > profile.level ? xpLevel : profile.level;
});

/// Progress fraction (0.0–1.0) within the current XP-derived level.
/// Uses [AppConstants.levelProgress] against `total_xp`.
final levelProgressProvider = Provider<double>((ref) {
  final profile = ref.watch(userProfileProvider).valueOrNull;
  if (profile == null) return 0.0;
  return AppConstants.levelProgress(profile.totalXP);
});

/// XP needed to reach the next level from the user's current `total_xp`.
/// Returns 0 at max level.
final pointsToNextLevelProvider = Provider<int>((ref) {
  final profile = ref.watch(userProfileProvider).valueOrNull;
  if (profile == null) return 0;
  return AppConstants.xpToNextLevel(profile.totalXP);
});

/// Deprecated alias — kept for any pre-migration caller. New code
/// should read [pointsToNextLevelProvider] instead. Same value.
@Deprecated('Use pointsToNextLevelProvider directly')
final xpToNextLevelProvider = pointsToNextLevelProvider;

/// Daily step goal from user profile.
final dailyGoalProvider = Provider<int>((ref) {
  final profile = ref.watch(userProfileProvider).valueOrNull;
  return profile?.dailyStepGoal ?? AppConstants.defaultDailyStepGoal;
});
