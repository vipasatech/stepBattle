/// Application-wide constants: XP thresholds, level table, mission defaults, timing.
abstract final class AppConstants {
  // -------------------------------------------------------------------------
  // Level thresholds — cumulative XP required per level
  // -------------------------------------------------------------------------
  static const Map<int, int> levelThresholds = {
    1: 0,
    2: 500,
    3: 1200,
    4: 2000,
    5: 3000,
    6: 4500,
    7: 6000,
    8: 8000,
    9: 11000,
    10: 15000,
    11: 20000,
    12: 25000,
    13: 30000,
    14: 32500,
    15: 35000,
    16: 40000,
    17: 50000,
    18: 60000,
    19: 70000,
    20: 75000,
  };

  /// Given cumulative XP, returns the current level.
  static int levelForXP(int xp) {
    int level = 1;
    for (final entry in levelThresholds.entries) {
      if (xp >= entry.value) {
        level = entry.key;
      } else {
        break;
      }
    }
    return level;
  }

  /// XP required to reach the next level from current cumulative XP.
  static int xpToNextLevel(int currentXP) {
    final currentLevel = levelForXP(currentXP);
    final nextLevel = currentLevel + 1;
    final threshold = levelThresholds[nextLevel];
    if (threshold == null) return 0; // Max level
    return threshold - currentXP;
  }

  /// Progress fraction (0.0–1.0) within the current level.
  static double levelProgress(int currentXP) {
    final currentLevel = levelForXP(currentXP);
    final currentThreshold = levelThresholds[currentLevel] ?? 0;
    final nextThreshold = levelThresholds[currentLevel + 1];
    if (nextThreshold == null) return 1.0; // Max level
    final range = nextThreshold - currentThreshold;
    if (range <= 0) return 1.0;
    return ((currentXP - currentThreshold) / range).clamp(0.0, 1.0);
  }

  // -------------------------------------------------------------------------
  // XP reward table
  // -------------------------------------------------------------------------
  static const int xpPer1000Steps = 10;
  static const int xpDailyGoalReached = 75;
  static const int xpDailyMissionMin = 50;
  static const int xpDailyMissionMax = 150;
  static const int xpWin1v1 = 200;
  static const int xpWinGroup = 300;
  static const int xpWinClanBattle = 300;
  static const int xp7DayStreak = 100;
  static const int xpAllDailyMissionsBonus = 150;
  static const int xpWeeklyChallengeMin = 300;
  static const int xpWeeklyChallengeMax = 500;

  // -------------------------------------------------------------------------
  // Step tracking
  // -------------------------------------------------------------------------
  static const int defaultDailyStepGoal = 8000;
  static const int minStepGoal = 1000;
  static const int maxStepGoal = 50000;
  static const int stepGoalIncrement = 500;
  static const double caloriesPerStep = 0.04;

  /// Background sync interval in minutes.
  static const int backgroundSyncIntervalMinutes = 15;

  /// Active battle sync interval in minutes.
  static const int activeBattleSyncIntervalMinutes = 5;

  // -------------------------------------------------------------------------
  // Battle
  // -------------------------------------------------------------------------
  static const int maxGroupBattleParticipants = 10;
  static const int groupBattleJoinWindowMinutes = 60;

  // -------------------------------------------------------------------------
  // Clan
  // -------------------------------------------------------------------------
  static const int minClanCreationLevel = 5;
  static const int maxClanMembers = 10;
  static const int clanNameMinLength = 3;
  static const int clanNameMaxLength = 20;

  // -------------------------------------------------------------------------
  // Leaderboard
  // -------------------------------------------------------------------------
  static const int leaderboardPageSize = 50;
  static const int leaderboardRefreshIntervalMinutes = 15;

  // -------------------------------------------------------------------------
  // Navigation
  // -------------------------------------------------------------------------
  static const int tabCount = 5;
}
