import 'package:cloud_firestore/cloud_firestore.dart';

enum MissionType { daily, weekly }

enum MissionCategory { steps, battle, streak, calories }

class MissionModel {
  final String missionId;
  final MissionType type;
  final String title;
  final String description;
  final MissionCategory category;
  final int targetValue;
  final int xpReward;
  final String difficulty; // "easy" | "medium" | "hard"

  const MissionModel({
    required this.missionId,
    required this.type,
    required this.title,
    required this.description,
    required this.category,
    required this.targetValue,
    required this.xpReward,
    required this.difficulty,
  });

  factory MissionModel.fromFirestore(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    return MissionModel(
      missionId: doc.id,
      type: d['type'] == 'weekly' ? MissionType.weekly : MissionType.daily,
      title: d['title'] as String? ?? '',
      description: d['description'] as String? ?? '',
      category: _parseCategory(d['category'] as String? ?? 'steps'),
      targetValue: d['targetValue'] as int? ?? 0,
      xpReward: d['xpReward'] as int? ?? 0,
      difficulty: d['difficulty'] as String? ?? 'easy',
    );
  }

  Map<String, dynamic> toFirestore() => {
        'type': type == MissionType.weekly ? 'weekly' : 'daily',
        'title': title,
        'description': description,
        'category': category.name,
        'targetValue': targetValue,
        'xpReward': xpReward,
        'difficulty': difficulty,
      };

  static MissionCategory _parseCategory(String s) => switch (s) {
        'battle' => MissionCategory.battle,
        'streak' => MissionCategory.streak,
        'calories' => MissionCategory.calories,
        _ => MissionCategory.steps,
      };

  /// Default daily missions (used when Firestore has none seeded yet).
  static const List<MissionModel> defaultDaily = [
    MissionModel(
      missionId: 'daily_steps',
      type: MissionType.daily,
      title: 'Walk 5,000 Steps',
      description: 'Hit your daily step target',
      category: MissionCategory.steps,
      targetValue: 5000,
      xpReward: 100,
      difficulty: 'easy',
    ),
    MissionModel(
      missionId: 'daily_battle',
      type: MissionType.daily,
      title: 'Win a Battle',
      description: 'Defeat an opponent in a step battle',
      category: MissionCategory.battle,
      targetValue: 1,
      xpReward: 150,
      difficulty: 'medium',
    ),
    MissionModel(
      missionId: 'daily_streak',
      type: MissionType.daily,
      title: 'Keep Streak Alive',
      description: 'Log steps for another consecutive day',
      category: MissionCategory.streak,
      targetValue: 1,
      xpReward: 50,
      difficulty: 'easy',
    ),
  ];

  /// Default weekly challenges.
  static const List<MissionModel> defaultWeekly = [
    MissionModel(
      missionId: 'weekly_steps',
      type: MissionType.weekly,
      title: 'Walk 50,000 Steps',
      description: 'Accumulate steps across the week',
      category: MissionCategory.steps,
      targetValue: 50000,
      xpReward: 500,
      difficulty: 'hard',
    ),
    MissionModel(
      missionId: 'weekly_battles',
      type: MissionType.weekly,
      title: 'Win 3 Battles',
      description: 'Defeat 3 opponents this week',
      category: MissionCategory.battle,
      targetValue: 3,
      xpReward: 400,
      difficulty: 'medium',
    ),
    MissionModel(
      missionId: 'weekly_alldays',
      type: MissionType.weekly,
      title: 'Complete All Daily Missions 5 Days',
      description: 'Finish every daily mission 5 days in a row',
      category: MissionCategory.streak,
      targetValue: 5,
      xpReward: 300,
      difficulty: 'hard',
    ),
  ];
}
