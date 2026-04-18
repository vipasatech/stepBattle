import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';

class UserModel {
  final String userId;
  final String userCode; // e.g. "#U4X92" — permanent public ID
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

  /// Last step threshold (in thousands) we awarded XP for today.
  /// E.g. `3` means we already awarded XP for crossing 1k, 2k, 3k today.
  /// Resets to 0 at midnight (via Cloud Function or client check on new day).
  final int lastStepXPThreshold;

  /// Date string (yyyy-MM-dd) for when lastStepXPThreshold was last updated.
  /// Used to detect day change and reset the threshold.
  final String lastStepXPDate;

  /// Whether daily goal XP was already awarded today.
  final String? dailyGoalXPAwardedDate;

  /// Total XP earned today (drip + goal + missions + battles).
  /// Resets to 0 at midnight via `xpEarnedTodayDate` mismatch check.
  final int xpEarnedToday;

  /// Date (yyyy-MM-dd) for when xpEarnedToday was last updated.
  final String xpEarnedTodayDate;

  final List<String> friends;
  final String? clanId;
  final DateTime createdAt;
  final DateTime lastActiveAt;

  const UserModel({
    required this.userId,
    required this.userCode,
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
    this.lastStepXPThreshold = 0,
    this.lastStepXPDate = '',
    this.dailyGoalXPAwardedDate,
    this.xpEarnedToday = 0,
    this.xpEarnedTodayDate = '',
    this.friends = const [],
    this.clanId,
    required this.createdAt,
    required this.lastActiveAt,
  });

  /// Generate a unique 5-char user code (no ambiguous chars: no 0/O, 1/I).
  static String generateUserCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = Random();
    final code = String.fromCharCodes(
      Iterable.generate(5, (_) => chars.codeUnitAt(rng.nextInt(chars.length))),
    );
    return '#$code';
  }

  factory UserModel.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return UserModel(
      userId: doc.id,
      userCode: data['userCode'] as String? ?? '',
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
      lastStepXPThreshold: data['lastStepXPThreshold'] as int? ?? 0,
      lastStepXPDate: data['lastStepXPDate'] as String? ?? '',
      dailyGoalXPAwardedDate: data['dailyGoalXPAwardedDate'] as String?,
      xpEarnedToday: data['xpEarnedToday'] as int? ?? 0,
      xpEarnedTodayDate: data['xpEarnedTodayDate'] as String? ?? '',
      friends: List<String>.from(data['friends'] as List? ?? []),
      clanId: data['clanId'] as String?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      lastActiveAt:
          (data['lastActiveAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'userCode': userCode,
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
      'lastStepXPThreshold': lastStepXPThreshold,
      'lastStepXPDate': lastStepXPDate,
      'dailyGoalXPAwardedDate': dailyGoalXPAwardedDate,
      'xpEarnedToday': xpEarnedToday,
      'xpEarnedTodayDate': xpEarnedTodayDate,
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
    int? lastStepXPThreshold,
    String? lastStepXPDate,
    String? dailyGoalXPAwardedDate,
    int? xpEarnedToday,
    String? xpEarnedTodayDate,
    List<String>? friends,
    String? clanId,
    DateTime? lastActiveAt,
  }) {
    return UserModel(
      userId: userId,
      userCode: userCode,
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
      lastStepXPThreshold: lastStepXPThreshold ?? this.lastStepXPThreshold,
      lastStepXPDate: lastStepXPDate ?? this.lastStepXPDate,
      dailyGoalXPAwardedDate:
          dailyGoalXPAwardedDate ?? this.dailyGoalXPAwardedDate,
      xpEarnedToday: xpEarnedToday ?? this.xpEarnedToday,
      xpEarnedTodayDate: xpEarnedTodayDate ?? this.xpEarnedTodayDate,
      friends: friends ?? this.friends,
      clanId: clanId ?? this.clanId,
      createdAt: createdAt,
      lastActiveAt: lastActiveAt ?? this.lastActiveAt,
    );
  }
}
