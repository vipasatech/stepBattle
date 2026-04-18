import 'package:flutter_test/flutter_test.dart';
import 'package:stepbattle/models/user_model.dart';
import 'package:stepbattle/models/battle_model.dart';
import 'package:stepbattle/models/mission_model.dart';
import 'package:stepbattle/models/user_mission_progress_model.dart';
import 'package:stepbattle/models/clan_model.dart';
import 'package:stepbattle/models/clan_battle_model.dart';
import 'package:stepbattle/models/leaderboard_entry_model.dart';
import 'package:stepbattle/models/friend_relationship_model.dart';
import 'package:stepbattle/models/step_log_model.dart';

void main() {
  group('UserModel', () {
    test('toFirestore produces all required fields', () {
      final user = UserModel(
        userId: 'u1',
        userCode: '#TEST1',
        displayName: 'TestUser',
        email: 'test@test.com',
        level: 5,
        totalXP: 3000,
        currentStreak: 7,
        bestStreak: 14,
        rank: 42,
        dailyStepGoal: 10000,
        totalStepsAllTime: 100000,
        friends: ['f1', 'f2'],
        clanId: 'c1',
        createdAt: DateTime(2025, 1, 1),
        lastActiveAt: DateTime(2025, 4, 5),
      );

      final map = user.toFirestore();
      expect(map['displayName'], 'TestUser');
      expect(map['email'], 'test@test.com');
      expect(map['level'], 5);
      expect(map['totalXP'], 3000);
      expect(map['currentStreak'], 7);
      expect(map['bestStreak'], 14);
      expect(map['rank'], 42);
      expect(map['dailyStepGoal'], 10000);
      expect(map['totalStepsAllTime'], 100000);
      expect(map['friends'], ['f1', 'f2']);
      expect(map['clanId'], 'c1');
    });

    test('copyWith preserves unchanged fields', () {
      final user = UserModel(
        userId: 'u1',
        userCode: '#TEST2',
        displayName: 'OldName',
        email: 'test@test.com',
        createdAt: DateTime(2025, 1, 1),
        lastActiveAt: DateTime(2025, 4, 5),
      );

      final updated = user.copyWith(displayName: 'NewName', level: 10);
      expect(updated.displayName, 'NewName');
      expect(updated.level, 10);
      expect(updated.email, 'test@test.com'); // unchanged
      expect(updated.userId, 'u1'); // immutable
    });
  });

  group('BattleModel', () {
    test('toFirestore serializes all fields', () {
      final battle = BattleModel(
        battleId: 'b1',
        type: BattleType.oneVsOne,
        status: BattleStatus.active,
        participants: [
          BattleParticipant(userId: 'u1', displayName: 'Player1', currentSteps: 5000),
          BattleParticipant(userId: 'u2', displayName: 'Player2', currentSteps: 3000),
        ],
        startTime: DateTime(2025, 4, 1),
        endTime: DateTime(2025, 4, 2),
        durationDays: 1,
        xpReward: 200,
        winnerId: null,
        createdBy: 'u1',
        createdAt: DateTime(2025, 1, 1),
      );

      final map = battle.toFirestore();
      expect(map['type'], '1v1');
      expect(map['status'], 'active');
      expect((map['participants'] as List).length, 2);
      expect(map['durationDays'], 1);
      expect(map['xpReward'], 200);
      expect(map['createdBy'], 'u1');
    });

    test('opponentFor returns correct participant', () {
      final battle = BattleModel(
        battleId: 'b1',
        type: BattleType.oneVsOne,
        status: BattleStatus.active,
        participants: [
          BattleParticipant(userId: 'u1', displayName: 'Me'),
          BattleParticipant(userId: 'u2', displayName: 'Them'),
        ],
        startTime: DateTime.now(),
        endTime: DateTime.now().add(const Duration(days: 1)),
        durationDays: 1,
        xpReward: 200,
        createdBy: 'u1',
        createdAt: DateTime(2025, 1, 1),
      );

      expect(battle.opponentFor('u1')?.displayName, 'Them');
      expect(battle.opponentFor('u2')?.displayName, 'Me');
    });

    test('participantFor returns self', () {
      final battle = BattleModel(
        battleId: 'b1',
        type: BattleType.oneVsOne,
        status: BattleStatus.active,
        participants: [
          BattleParticipant(userId: 'u1', displayName: 'Me', currentSteps: 5000),
        ],
        startTime: DateTime.now(),
        endTime: DateTime.now().add(const Duration(days: 1)),
        durationDays: 1,
        xpReward: 200,
        createdBy: 'u1',
        createdAt: DateTime(2025, 1, 1),
      );

      expect(battle.participantFor('u1')?.currentSteps, 5000);
      expect(battle.participantFor('nonexistent'), null);
    });

    test('shortId returns first 4 characters', () {
      final battle = BattleModel(
        battleId: 'abc123xyz',
        type: BattleType.oneVsOne,
        status: BattleStatus.pending,
        participants: [],
        startTime: DateTime.now(),
        endTime: DateTime.now(),
        durationDays: 1,
        xpReward: 200,
        createdBy: 'u1',
        createdAt: DateTime(2025, 1, 1),
      );

      expect(battle.shortId, '#ABC1');
    });

    test('timeRemaining returns zero for past battles', () {
      final battle = BattleModel(
        battleId: 'b1',
        type: BattleType.oneVsOne,
        status: BattleStatus.completed,
        participants: [],
        startTime: DateTime(2024, 1, 1),
        endTime: DateTime(2024, 1, 2),
        durationDays: 1,
        xpReward: 200,
        createdBy: 'u1',
        createdAt: DateTime(2025, 1, 1),
      );

      expect(battle.timeRemaining, Duration.zero);
      expect(battle.timeRemainingLabel, 'Ended');
    });
  });

  group('BattleParticipant', () {
    test('toMap/fromMap roundtrip', () {
      final p = BattleParticipant(
        userId: 'u1',
        displayName: 'Player',
        avatarURL: 'https://example.com/avatar.jpg',
        currentSteps: 8000,
        isWinner: true,
      );

      final map = p.toMap();
      final restored = BattleParticipant.fromMap(map);
      expect(restored.userId, 'u1');
      expect(restored.displayName, 'Player');
      expect(restored.avatarURL, 'https://example.com/avatar.jpg');
      expect(restored.currentSteps, 8000);
      expect(restored.isWinner, true);
    });
  });

  group('MissionModel', () {
    test('default daily missions has 3 entries', () {
      expect(MissionModel.defaultDaily.length, 3);
    });

    test('default weekly missions has 3 entries', () {
      expect(MissionModel.defaultWeekly.length, 3);
    });

    test('default daily missions cover steps, battle, streak', () {
      final categories =
          MissionModel.defaultDaily.map((m) => m.category).toSet();
      expect(categories, contains(MissionCategory.steps));
      expect(categories, contains(MissionCategory.battle));
      expect(categories, contains(MissionCategory.streak));
    });

    test('toFirestore serializes type correctly', () {
      const mission = MissionModel(
        missionId: 'm1',
        type: MissionType.weekly,
        title: 'Test',
        description: 'Desc',
        category: MissionCategory.steps,
        targetValue: 50000,
        xpReward: 500,
        difficulty: 'hard',
      );

      final map = mission.toFirestore();
      expect(map['type'], 'weekly');
      expect(map['category'], 'steps');
    });
  });

  group('UserMissionProgress', () {
    test('progressFraction computes correctly', () {
      final p = UserMissionProgress(
        id: 'p1',
        userId: 'u1',
        missionId: 'm1',
        currentValue: 3200,
        targetValue: 5000,
        periodStart: '2025-04-05',
      );

      expect(p.progressFraction, closeTo(0.64, 0.01));
      expect(p.percentLabel, '64%');
    });

    test('progressFraction clamps to 1.0 when exceeded', () {
      final p = UserMissionProgress(
        id: 'p1',
        userId: 'u1',
        missionId: 'm1',
        currentValue: 6000,
        targetValue: 5000,
        periodStart: '2025-04-05',
      );

      expect(p.progressFraction, 1.0);
    });

    test('empty factory sets defaults', () {
      final p = UserMissionProgress.empty(
        userId: 'u1',
        missionId: 'm1',
        targetValue: 5000,
        periodStart: '2025-04-05',
      );

      expect(p.currentValue, 0);
      expect(p.isCompleted, false);
      expect(p.completedAt, null);
      expect(p.id, 'u1_m1_2025-04-05');
    });

    test('progressLabel formats large numbers', () {
      final p = UserMissionProgress(
        id: 'p1',
        userId: 'u1',
        missionId: 'm1',
        currentValue: 32000,
        targetValue: 50000,
        periodStart: '2025-04-05',
      );

      expect(p.progressLabel, contains('32,000'));
      expect(p.progressLabel, contains('50,000'));
    });
  });

  group('ClanModel', () {
    test('isFull returns true at max capacity', () {
      final clan = ClanModel(
        clanId: 'c1',
        name: 'Test Clan',
        clanIdCode: '#TEST1',
        captainId: 'u1',
        memberIds: List.generate(10, (i) => 'u$i'),
        createdAt: DateTime.now(),
        maxMembers: 10,
      );

      expect(clan.isFull, true);
      expect(clan.memberCount, 10);
    });

    test('isFull returns false under capacity', () {
      final clan = ClanModel(
        clanId: 'c1',
        name: 'Test Clan',
        clanIdCode: '#TEST1',
        captainId: 'u1',
        memberIds: ['u1', 'u2'],
        createdAt: DateTime.now(),
      );

      expect(clan.isFull, false);
    });
  });

  group('ClanMember', () {
    test('isCaptain detects role correctly', () {
      final captain = ClanMember(
          userId: 'u1', displayName: 'Cap', role: 'captain');
      final soldier = ClanMember(
          userId: 'u2', displayName: 'Sol', role: 'soldier');

      expect(captain.isCaptain, true);
      expect(soldier.isCaptain, false);
    });

    test('toMap/fromMap roundtrip', () {
      final m = ClanMember(
        userId: 'u1',
        displayName: 'Test',
        role: 'captain',
        stepsToday: 5000,
      );

      final restored = ClanMember.fromMap(m.toMap());
      expect(restored.userId, 'u1');
      expect(restored.isCaptain, true);
      expect(restored.stepsToday, 5000);
    });
  });

  group('ClanBattleModel', () {
    test('timeRemaining returns zero for past battles', () {
      final b = ClanBattleModel(
        clanBattleId: 'cb1',
        status: ClanBattleStatus.completed,
        clanA: ClanBattleTeam(clanId: 'c1', clanName: 'Alpha'),
        clanB: ClanBattleTeam(clanId: 'c2', clanName: 'Beta'),
        startTime: DateTime(2024, 1, 1),
        endTime: DateTime(2024, 1, 4),
        durationDays: 3,
        battleType: 'total_steps',
      );

      expect(b.timeRemaining, Duration.zero);
    });
  });

  group('ClanBattleTeam', () {
    test('toMap/fromMap roundtrip', () {
      final t = ClanBattleTeam(
          clanId: 'c1', clanName: 'Warriors', totalSteps: 42000);
      final restored = ClanBattleTeam.fromMap(t.toMap());
      expect(restored.clanId, 'c1');
      expect(restored.clanName, 'Warriors');
      expect(restored.totalSteps, 42000);
    });
  });

  group('StepLogModel', () {
    test('toFirestore serializes all fields', () {
      final log = StepLogModel(
        logId: 'l1',
        userId: 'u1',
        date: '2025-04-05',
        stepCount: 8500,
        calories: 340,
        source: 'healthkit',
        syncedAt: DateTime(2025, 4, 5, 12, 0),
      );

      final map = log.toFirestore();
      expect(map['userId'], 'u1');
      expect(map['date'], '2025-04-05');
      expect(map['stepCount'], 8500);
      expect(map['calories'], 340);
      expect(map['source'], 'healthkit');
    });

    test('copyWith updates selected fields', () {
      final log = StepLogModel(
        logId: 'l1',
        userId: 'u1',
        date: '2025-04-05',
        stepCount: 5000,
        calories: 200,
        source: 'healthkit',
        syncedAt: DateTime.now(),
      );

      final updated = log.copyWith(stepCount: 8000, calories: 320);
      expect(updated.stepCount, 8000);
      expect(updated.calories, 320);
      expect(updated.userId, 'u1'); // unchanged
    });
  });

  group('LeaderboardEntry', () {
    test('toFirestore produces correct structure', () {
      final entry = LeaderboardEntry(
        userId: 'u1',
        displayName: 'Champ',
        totalXP: 150000,
        rank: 1,
        updatedAt: DateTime(2025, 4, 5),
      );

      final map = entry.toFirestore();
      expect(map['displayName'], 'Champ');
      expect(map['totalXP'], 150000);
      expect(map['rank'], 1);
    });
  });

  group('FriendRelationship', () {
    test('toFirestore serializes status', () {
      final rel = FriendRelationship(
        relationshipId: 'r1',
        fromUserId: 'u1',
        toUserId: 'u2',
        status: FriendStatus.pending,
        createdAt: DateTime(2025, 4, 5),
      );

      final map = rel.toFirestore();
      expect(map['status'], 'pending');
      expect(map['fromUserId'], 'u1');
      expect(map['toUserId'], 'u2');
    });
  });
}
