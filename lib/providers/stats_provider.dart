import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'auth_provider.dart';
import 'battle_provider.dart';
import 'mission_provider.dart';
import 'user_provider.dart';

/// Battle stats for the current user.
class BattleStats {
  final int totalWon;
  final int totalLost;
  final int totalCompleted;
  final int thisWeekWon;
  final int thisWeekTotal;

  const BattleStats({
    this.totalWon = 0,
    this.totalLost = 0,
    this.totalCompleted = 0,
    this.thisWeekWon = 0,
    this.thisWeekTotal = 0,
  });

  String get thisWeekLabel => '$thisWeekWon / $thisWeekTotal';
  String get allTimeLabel => '${totalWon}W / ${totalLost}L';
}

/// Compute battle stats from the completed battles list.
final battleStatsProvider = Provider<BattleStats>((ref) {
  final uid = ref.watch(authStateProvider).valueOrNull?.uid;
  final completed = ref.watch(completedBattlesProvider);

  if (uid == null || completed.isEmpty) return const BattleStats();

  final now = DateTime.now();
  final weekStart =
      DateTime(now.year, now.month, now.day - (now.weekday - 1));

  int totalWon = 0;
  int totalLost = 0;
  int thisWeekWon = 0;
  int thisWeekTotal = 0;

  for (final b in completed) {
    final isMine = b.participants.any((p) => p.userId == uid);
    if (!isMine) continue;

    final won = b.winnerId == uid;
    if (won) {
      totalWon++;
    } else {
      totalLost++;
    }

    if (b.endTime.isAfter(weekStart)) {
      thisWeekTotal++;
      if (won) thisWeekWon++;
    }
  }

  return BattleStats(
    totalWon: totalWon,
    totalLost: totalLost,
    totalCompleted: completed.length,
    thisWeekWon: thisWeekWon,
    thisWeekTotal: thisWeekTotal,
  );
});

/// Mission completion stats.
class MissionStats {
  final int completedToday;
  final int totalToday;
  final int completedThisWeek;
  final int totalThisWeek;
  final int xpEarnedToday;

  const MissionStats({
    this.completedToday = 0,
    this.totalToday = 0,
    this.completedThisWeek = 0,
    this.totalThisWeek = 0,
    this.xpEarnedToday = 0,
  });

  String get todayLabel => '$completedToday / $totalToday';
  String get thisWeekLabel => '$completedThisWeek / $totalThisWeek';
}

/// Compute mission stats from daily + weekly progress.
/// `xpEarnedToday` is the full "earned today" total (drip + goal + missions +
/// battles), not just mission XP — sourced from `users.xpEarnedToday`.
final missionStatsProvider = Provider<MissionStats>((ref) {
  final dailyMissions = ref.watch(dailyMissionsProvider).valueOrNull ?? [];
  final weeklyMissions = ref.watch(weeklyMissionsProvider).valueOrNull ?? [];
  final dailyProgress = ref.watch(dailyProgressProvider).valueOrNull ?? [];
  final weeklyProgress = ref.watch(weeklyProgressProvider).valueOrNull ?? [];
  final profile = ref.watch(userProfileProvider).valueOrNull;

  final completedDailyIds = dailyProgress
      .where((p) => p.isCompleted)
      .map((p) => p.missionId)
      .toSet();
  final completedWeeklyIds = weeklyProgress
      .where((p) => p.isCompleted)
      .map((p) => p.missionId)
      .toSet();

  // Use user.xpEarnedToday as source of truth, but zero it out if stored
  // date is stale (pre-midnight, next day reset).
  final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
  final xpToday =
      (profile != null && profile.xpEarnedTodayDate == today)
          ? profile.xpEarnedToday
          : 0;

  return MissionStats(
    completedToday: completedDailyIds.length,
    totalToday: dailyMissions.length,
    completedThisWeek:
        completedDailyIds.length + completedWeeklyIds.length,
    totalThisWeek: dailyMissions.length + weeklyMissions.length,
    xpEarnedToday: xpToday,
  );
});
