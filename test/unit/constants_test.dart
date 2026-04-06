import 'package:flutter_test/flutter_test.dart';
import 'package:stepbattle/config/constants.dart';

void main() {
  group('AppConstants.levelForXP', () {
    test('0 XP = level 1', () {
      expect(AppConstants.levelForXP(0), 1);
    });

    test('499 XP = level 1', () {
      expect(AppConstants.levelForXP(499), 1);
    });

    test('500 XP = level 2', () {
      expect(AppConstants.levelForXP(500), 2);
    });

    test('1200 XP = level 3', () {
      expect(AppConstants.levelForXP(1200), 3);
    });

    test('3000 XP = level 5', () {
      expect(AppConstants.levelForXP(3000), 5);
    });

    test('8000 XP = level 8', () {
      expect(AppConstants.levelForXP(8000), 8);
    });

    test('15000 XP = level 10', () {
      expect(AppConstants.levelForXP(15000), 10);
    });

    test('75000 XP = level 20 (max)', () {
      expect(AppConstants.levelForXP(75000), 20);
    });

    test('100000 XP still = level 20 (capped)', () {
      expect(AppConstants.levelForXP(100000), 20);
    });

    test('mid-level XP: 6500 = level 7', () {
      expect(AppConstants.levelForXP(6500), 7);
    });
  });

  group('AppConstants.xpToNextLevel', () {
    test('0 XP → 500 to next level', () {
      expect(AppConstants.xpToNextLevel(0), 500);
    });

    test('250 XP → 250 to next level', () {
      expect(AppConstants.xpToNextLevel(250), 250);
    });

    test('500 XP (level 2) → 700 to level 3', () {
      expect(AppConstants.xpToNextLevel(500), 700);
    });

    test('max level XP → 0 to next', () {
      expect(AppConstants.xpToNextLevel(75000), 0);
    });

    test('beyond max → 0', () {
      expect(AppConstants.xpToNextLevel(100000), 0);
    });
  });

  group('AppConstants.levelProgress', () {
    test('0 XP → 0.0 progress', () {
      expect(AppConstants.levelProgress(0), 0.0);
    });

    test('250 XP → 0.5 progress (halfway through level 1)', () {
      expect(AppConstants.levelProgress(250), closeTo(0.5, 0.01));
    });

    test('500 XP → 0.0 progress (start of level 2)', () {
      expect(AppConstants.levelProgress(500), closeTo(0.0, 0.01));
    });

    test('850 XP → 0.5 progress in level 2 (500-1200 range)', () {
      expect(AppConstants.levelProgress(850), closeTo(0.5, 0.01));
    });

    test('max XP → 1.0', () {
      expect(AppConstants.levelProgress(75000), 1.0);
    });
  });

  group('XP reward constants', () {
    test('step XP rate is 10 per 1000', () {
      expect(AppConstants.xpPer1000Steps, 10);
    });

    test('1v1 win reward is 200', () {
      expect(AppConstants.xpWin1v1, 200);
    });

    test('group win reward is 300', () {
      expect(AppConstants.xpWinGroup, 300);
    });

    test('daily goal reached is 75', () {
      expect(AppConstants.xpDailyGoalReached, 75);
    });

    test('7-day streak bonus is 100', () {
      expect(AppConstants.xp7DayStreak, 100);
    });
  });

  group('Goal constraints', () {
    test('default goal is 8000', () {
      expect(AppConstants.defaultDailyStepGoal, 8000);
    });

    test('min goal is 1000', () {
      expect(AppConstants.minStepGoal, 1000);
    });

    test('max goal is 50000', () {
      expect(AppConstants.maxStepGoal, 50000);
    });

    test('increment is 500', () {
      expect(AppConstants.stepGoalIncrement, 500);
    });
  });

  group('Clan constraints', () {
    test('min creation level is 5', () {
      expect(AppConstants.minClanCreationLevel, 5);
    });

    test('max members is 10', () {
      expect(AppConstants.maxClanMembers, 10);
    });

    test('clan name length 3-20', () {
      expect(AppConstants.clanNameMinLength, 3);
      expect(AppConstants.clanNameMaxLength, 20);
    });
  });
}
