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
  // Activity-score → level (migration 0050, MIRROR of the SQL
  // `level_from_activity_score` function).
  //
  // Formula: AS = 10·W + 3·L + 3·M (see subscription_model / server
  // trigger). Compressed table: level 2 arrives after the first
  // mission (feel-good hit), level 20 is ~6 months for a regular
  // player. If either side is edited, keep BOTH tables in sync.
  // -------------------------------------------------------------------------
  static const Map<int, int> activityScoreThresholds = {
    1: 0,
    2: 1,
    3: 4,
    4: 8,
    5: 15,
    6: 25,
    7: 40,
    8: 55,
    9: 75,
    10: 100,
    11: 130,
    12: 165,
    13: 200,
    14: 240,
    15: 285,
    16: 335,
    17: 390,
    18: 445,
    19: 500,
    20: 560,
  };

  /// Given activity score, returns the derived level. Server may have
  /// pushed the stored `level` higher (monotonic guard); UI reads
  /// `userLevelProvider` (which returns the stored value), NOT this
  /// helper, for the actual level display.
  static int levelForActivityScore(int score) {
    int level = 1;
    for (final entry in activityScoreThresholds.entries) {
      if (score >= entry.value) {
        level = entry.key;
      } else {
        break;
      }
    }
    return level;
  }

  /// Progress fraction (0.0–1.0) within the current activity level.
  static double levelProgressForActivity(int score) {
    final currentLevel = levelForActivityScore(score);
    final currentThreshold = activityScoreThresholds[currentLevel] ?? 0;
    final nextThreshold = activityScoreThresholds[currentLevel + 1];
    if (nextThreshold == null) return 1.0;
    final range = nextThreshold - currentThreshold;
    if (range <= 0) return 1.0;
    return ((score - currentThreshold) / range).clamp(0.0, 1.0);
  }

  /// Activity Score points remaining to reach the next level.
  static int pointsToNextLevel(int score) {
    final currentLevel = levelForActivityScore(score);
    final nextThreshold = activityScoreThresholds[currentLevel + 1];
    if (nextThreshold == null) return 0;
    return nextThreshold - score;
  }

  // -------------------------------------------------------------------------
  // XP reward table
  // -------------------------------------------------------------------------
  //
  // v2 economy — only these five paths pay XP. Passive step XP + daily
  // step-goal + free-play battle XP + weekly challenges were retired.
  // The mission-catalog daily-streak mission keeps its `xp_reward=50`
  // through the DB-driven mission fetch (see mission_model.dart).
  //   1. Sign-up bonus (onboarding complete)              → 500
  //   2. First 7-day streak (once ever, per user)          →  50
  //   3. Every 30-day streak milestone (30/60/90/…)        → 100
  //   4. Daily "Keep Streak Alive" mission (mission model) →  50
  //   5. Stake-battle win (pot minus own stake, DB-settled)
  //      minimum stake per participant enforced at creation → 100 XP
  static const int xpSignUpBonus = 500;
  static const int xpFirst7DayStreak = 50;
  static const int xp30DayStreakMilestone = 100;
  static const int xpDailyStreakMission = 50;
  static const int minBattleStakeXp = 100;

  // -------------------------------------------------------------------------
  // XP recharge (real-money → in-game XP)
  // -------------------------------------------------------------------------
  //   Fixed exchange rate: 1 INR = 5 XP.
  //   Purchase floor: 50 INR = 250 XP.
  static const int xpPerRupee = 5;
  static const int minRechargeRupees = 50;
  static int rupeesToXp(int rupees) => rupees * xpPerRupee;
  static int minRechargeXp() => minRechargeRupees * xpPerRupee;

  // -------------------------------------------------------------------------
  // Step tracking
  // -------------------------------------------------------------------------
  static const int defaultDailyStepGoal = 8000;
  static const int minStepGoal = 1000;
  /// Hard ceiling for the custom step-goal stepper. The formula's
  /// personalized `range.max` still drives the "Suggested Max" chip
  /// and the Recommended strip — those reflect the healthy band for
  /// the user's fitness profile. This constant is the override ceiling
  /// for ambitious users who explicitly dial past their recommended
  /// max via the custom stepper. Set to 30k: the world's most active
  /// runners average around 25–28k on training days, so 30k gives
  /// headroom without letting the number go absurd (which would break
  /// downstream progress-bar math and mission chip layout).
  static const int maxStepGoal = 30000;
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
