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

  // ── Home location (used for geo-scoped leaderboards + map) ────────────────
  // Set once at signup or via Profile → Edit district. ISO 3166-1 alpha-2
  // country code (e.g., "IN", "US"); state/district names use whatever the
  // reverse geocoder returns for the user's locale.
  /// ISO 3166-1 alpha-2 country code (e.g., "IN").
  final String? countryCode;

  /// Country display name (e.g., "India") — for UI without a code lookup.
  final String? countryName;

  /// State / province name (e.g., "Telangana"). Free-form local name.
  final String? stateName;

  /// District / sub-administrative-area name (e.g., "Hyderabad"). Free-form.
  final String? districtName;

  /// Approximate home coordinates. Stored only at coarse precision (~city
  /// level) since we use COARSE_LOCATION at request time.
  final double? homeLat;
  final double? homeLng;

  /// When the user last set/changed their home — used to enforce a 30-day
  /// cooldown on changes once we add competitive seasonal leaderboards.
  final DateTime? homeSetAt;

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
    this.countryCode,
    this.countryName,
    this.stateName,
    this.districtName,
    this.homeLat,
    this.homeLng,
    this.homeSetAt,
  });

  /// Whether the user has set a home district yet.
  bool get hasHome =>
      countryCode != null && countryCode!.isNotEmpty;

  /// Generate a unique 5-char user code (no ambiguous chars: no 0/O, 1/I).
  static String generateUserCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = Random();
    final code = String.fromCharCodes(
      Iterable.generate(5, (_) => chars.codeUnitAt(rng.nextInt(chars.length))),
    );
    return '#$code';
  }

  /// Build a UserModel from a Supabase `public.profiles` row. Column names
  /// are snake_case per Postgres convention; we map them to the camelCase
  /// fields the rest of the app already uses. `friends` is intentionally
  /// always `const []` here — friends are derived from
  /// `friend_relationships` (see `acceptedFriendIdsProvider`), not stored
  /// on the profile.
  factory UserModel.fromSupabaseRow(Map<String, dynamic> data) {
    DateTime? parseTs(Object? raw) {
      if (raw == null) return null;
      return DateTime.tryParse(raw.toString());
    }

    return UserModel(
      userId: data['id'] as String? ?? '',
      userCode: data['user_code'] as String? ?? '',
      displayName: data['display_name'] as String? ?? '',
      avatarURL: data['avatar_url'] as String?,
      email: data['email'] as String? ?? '',
      phone: data['phone'] as String?,
      level: (data['level'] as num?)?.toInt() ?? 1,
      totalXP: (data['total_xp'] as num?)?.toInt() ?? 0,
      currentStreak: (data['current_streak'] as num?)?.toInt() ?? 0,
      bestStreak: (data['longest_streak'] as num?)?.toInt() ?? 0,
      rank: 0,
      dailyStepGoal: (data['daily_step_goal'] as num?)?.toInt() ?? 8000,
      totalStepsAllTime:
          (data['total_steps_all_time'] as num?)?.toInt() ?? 0,
      lastStepXPThreshold:
          (data['last_step_xp_threshold'] as num?)?.toInt() ?? 0,
      lastStepXPDate: data['last_step_xp_date'] as String? ?? '',
      dailyGoalXPAwardedDate: data['daily_goal_xp_awarded_date'] as String?,
      xpEarnedToday: (data['xp_earned_today'] as num?)?.toInt() ?? 0,
      xpEarnedTodayDate: data['xp_earned_today_date'] as String? ?? '',
      friends: const [],
      clanId: data['clan_id'] as String?,
      createdAt: parseTs(data['created_at']) ?? DateTime.now(),
      lastActiveAt: parseTs(data['last_active_at']) ?? DateTime.now(),
      countryCode: data['country_code'] as String?,
      countryName: data['country_name'] as String?,
      stateName: data['state_name'] as String?,
      districtName: data['district_name'] as String?,
      homeLat: (data['home_lat'] as num?)?.toDouble(),
      homeLng: (data['home_lng'] as num?)?.toDouble(),
      homeSetAt: parseTs(data['home_set_at']),
    );
  }

  /// Mirror of [toFirestore] for Supabase. Returns the payload the
  /// `public.profiles` table expects (snake_case columns, ISO timestamps,
  /// no `friends` array).
  Map<String, dynamic> toSupabaseRow() {
    String? iso(DateTime? d) => d?.toUtc().toIso8601String();
    return {
      'id': userId,
      'user_code': userCode,
      'display_name': displayName,
      'avatar_url': avatarURL,
      'email': email,
      // phone: no column on profiles yet; UserModel.phone stays null
      'level': level,
      'total_xp': totalXP,
      'current_streak': currentStreak,
      'longest_streak': bestStreak,
      'daily_step_goal': dailyStepGoal,
      'total_steps_all_time': totalStepsAllTime,
      'last_step_xp_threshold': lastStepXPThreshold,
      'last_step_xp_date': lastStepXPDate,
      'daily_goal_xp_awarded_date': dailyGoalXPAwardedDate,
      'xp_earned_today': xpEarnedToday,
      'xp_earned_today_date': xpEarnedTodayDate,
      'clan_id': clanId,
      'created_at': iso(createdAt),
      'last_active_at': iso(lastActiveAt),
      'country_code': countryCode,
      'country_name': countryName,
      'state_name': stateName,
      'district_name': districtName,
      'home_lat': homeLat,
      'home_lng': homeLng,
      'home_set_at': iso(homeSetAt),
    };
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
      countryCode: data['countryCode'] as String?,
      countryName: data['countryName'] as String?,
      stateName: data['stateName'] as String?,
      districtName: data['districtName'] as String?,
      homeLat: (data['homeLat'] as num?)?.toDouble(),
      homeLng: (data['homeLng'] as num?)?.toDouble(),
      homeSetAt: (data['homeSetAt'] as Timestamp?)?.toDate(),
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
      'countryCode': countryCode,
      'countryName': countryName,
      'stateName': stateName,
      'districtName': districtName,
      'homeLat': homeLat,
      'homeLng': homeLng,
      'homeSetAt':
          homeSetAt == null ? null : Timestamp.fromDate(homeSetAt!),
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
    String? countryCode,
    String? countryName,
    String? stateName,
    String? districtName,
    double? homeLat,
    double? homeLng,
    DateTime? homeSetAt,
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
      countryCode: countryCode ?? this.countryCode,
      countryName: countryName ?? this.countryName,
      stateName: stateName ?? this.stateName,
      districtName: districtName ?? this.districtName,
      homeLat: homeLat ?? this.homeLat,
      homeLng: homeLng ?? this.homeLng,
      homeSetAt: homeSetAt ?? this.homeSetAt,
    );
  }
}
