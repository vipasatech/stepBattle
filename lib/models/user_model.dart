import 'package:cloud_firestore/cloud_firestore.dart';

class UserModel {
  final String userId;
  final String displayName;
  final String? avatarURL;
  final String email;
  final String? phone;
  final int level;
  final int totalXP;
  final int currentStreak;
  final int bestStreak;
  final int rank;
  final int dailyStepGoal;
  final int totalStepsAllTime;
  final List<String> friends;
  final String? clanId;
  final DateTime createdAt;
  final DateTime lastActiveAt;

  const UserModel({
    required this.userId,
    required this.displayName,
    this.avatarURL,
    required this.email,
    this.phone,
    this.level = 1,
    this.totalXP = 0,
    this.currentStreak = 0,
    this.bestStreak = 0,
    this.rank = 0,
    this.dailyStepGoal = 8000,
    this.totalStepsAllTime = 0,
    this.friends = const [],
    this.clanId,
    required this.createdAt,
    required this.lastActiveAt,
  });

  factory UserModel.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return UserModel(
      userId: doc.id,
      displayName: data['displayName'] as String? ?? '',
      avatarURL: data['avatarURL'] as String?,
      email: data['email'] as String? ?? '',
      phone: data['phone'] as String?,
      level: data['level'] as int? ?? 1,
      totalXP: data['totalXP'] as int? ?? 0,
      currentStreak: data['currentStreak'] as int? ?? 0,
      bestStreak: data['bestStreak'] as int? ?? 0,
      rank: data['rank'] as int? ?? 0,
      dailyStepGoal: data['dailyStepGoal'] as int? ?? 8000,
      totalStepsAllTime: data['totalStepsAllTime'] as int? ?? 0,
      friends: List<String>.from(data['friends'] as List? ?? []),
      clanId: data['clanId'] as String?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      lastActiveAt:
          (data['lastActiveAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'displayName': displayName,
      'avatarURL': avatarURL,
      'email': email,
      'phone': phone,
      'level': level,
      'totalXP': totalXP,
      'currentStreak': currentStreak,
      'bestStreak': bestStreak,
      'rank': rank,
      'dailyStepGoal': dailyStepGoal,
      'totalStepsAllTime': totalStepsAllTime,
      'friends': friends,
      'clanId': clanId,
      'createdAt': Timestamp.fromDate(createdAt),
      'lastActiveAt': Timestamp.fromDate(lastActiveAt),
    };
  }

  UserModel copyWith({
    String? displayName,
    String? avatarURL,
    String? phone,
    int? level,
    int? totalXP,
    int? currentStreak,
    int? bestStreak,
    int? rank,
    int? dailyStepGoal,
    int? totalStepsAllTime,
    List<String>? friends,
    String? clanId,
    DateTime? lastActiveAt,
  }) {
    return UserModel(
      userId: userId,
      displayName: displayName ?? this.displayName,
      avatarURL: avatarURL ?? this.avatarURL,
      email: email,
      phone: phone ?? this.phone,
      level: level ?? this.level,
      totalXP: totalXP ?? this.totalXP,
      currentStreak: currentStreak ?? this.currentStreak,
      bestStreak: bestStreak ?? this.bestStreak,
      rank: rank ?? this.rank,
      dailyStepGoal: dailyStepGoal ?? this.dailyStepGoal,
      totalStepsAllTime: totalStepsAllTime ?? this.totalStepsAllTime,
      friends: friends ?? this.friends,
      clanId: clanId ?? this.clanId,
      createdAt: createdAt,
      lastActiveAt: lastActiveAt ?? this.lastActiveAt,
    );
  }
}
