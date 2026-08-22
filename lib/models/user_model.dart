import 'dart:math';

import 'subscription_model.dart' show SubscriptionTier;

/// Gender — captured during the mandatory onboarding survey. Used as one
/// of three inputs into the personalized step-goal formula (see
/// `lib/services/goal_formula.dart`) and to filter gender-scoped
/// leaderboards in the future. UI labels live in the onboarding screen;
/// the wire format here matches the `profiles.gender` check constraint.
enum Gender {
  man,
  woman,
  nonBinary,
  preferNotToSay;

  String get wire => switch (this) {
        Gender.man => 'man',
        Gender.woman => 'woman',
        Gender.nonBinary => 'non_binary',
        Gender.preferNotToSay => 'prefer_not_to_say',
      };

  static Gender? fromWire(String? s) => switch (s) {
        'man' => Gender.man,
        'woman' => Gender.woman,
        'non_binary' => Gender.nonBinary,
        'prefer_not_to_say' => Gender.preferNotToSay,
        _ => null,
      };
}

/// Self-reported fitness level — second input to the step-goal formula.
/// Multipliers are documented in [`goal_formula.dart`].
enum FitnessLevel {
  beginner,
  intermediate,
  advanced,
  pro;

  String get wire => name;

  static FitnessLevel? fromWire(String? s) => switch (s) {
        'beginner' => FitnessLevel.beginner,
        'intermediate' => FitnessLevel.intermediate,
        'advanced' => FitnessLevel.advanced,
        'pro' => FitnessLevel.pro,
        _ => null,
      };
}

class UserModel {
  final String userId;
  final String userCode; // e.g. "#U4X92" — permanent public ID
  final String displayName;

  /// Optional nickname the user prefers to be addressed by. When set,
  /// [friendlyName] returns this; otherwise it falls back to
  /// [displayName]. Bounded 1..40 chars server-side (see migration
  /// 0024 for the check constraint).
  final String? preferredName;

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

  /// Activity Score — migration 0050. Derived from wins + losses +
  /// missions completed (formula: 10W + 3L + 3M). Server trigger
  /// recomputes on every completed battle / mission complete and
  /// applies a monotonic level = greatest(level, level_from_score).
  /// The client displays it for the level-progress bar; nothing else
  /// depends on it. Defaults to 0 for legacy rows / brand-new users.
  final int activityScore;

  /// Denormalized counters that back [activityScore]. Kept on the
  /// model so UI can show "3 wins · 12 played · 47 missions" without
  /// a second query. Server trigger keeps them in sync.
  final int battlesWonCount;
  final int battlesPlayedCount;
  final int missionsCompletedCount;

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

  // ── Notification preferences (migration 0033) ─────────────────────────────
  /// Master switch — false silences ALL FCM push notifications app-wide.
  final bool notifPush;

  /// Master switch for email notifications (weekly recap, receipts, etc.).
  final bool notifEmail;

  /// Battle-invite and battle-result push events.
  final bool notifBattles;

  /// Friend-request and friend-accepted push events.
  final bool notifFriends;

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

  // ── Mandatory onboarding survey (migration 0016) ──────────────────────────
  /// Date of birth (used to derive age for the step-goal formula). Null on
  /// any profile created before the survey shipped — those users are
  /// caught by the "Complete your profile" sheet on first launch.
  final DateTime? dateOfBirth;

  /// Self-reported gender. See [Gender] for wire values.
  final Gender? gender;

  /// Self-reported fitness level. See [FitnessLevel] for wire values.
  final FitnessLevel? fitnessLevel;

  /// Self-reported height in centimetres. Feeds the BMI multiplier in
  /// `GoalFormula`. Null = unanswered → formula treats BMI as neutral.
  final int? heightCm;

  /// Self-reported weight in kilograms. Feeds the BMI multiplier in
  /// `GoalFormula`. Null = unanswered → formula treats BMI as neutral.
  final double? weightKg;

  /// User's selected battle-ground runner avatar — one of the 12 bird's-
  /// eye-view PNGs in `assets/images/avatars/`. Distinct from
  /// [avatarURL], which is the profile photo. See migration 0019 and
  /// [Avatar.byId]. Defaults to 'avatar_01' for legacy rows.
  final String battleAvatarId;

  /// User's chosen 3D character id — `'women'` or `'men'`. Nullable when
  /// the user has never opened the 3D picker; in that case the client
  /// falls back to `Character3D.defaultForGender(gender)`. Loaded by
  /// `flutter_3d_controller` from `assets/images/3dAvatars/<id>/runner.glb`.
  /// See migration 0027 and `lib/models/character_3d.dart`.
  final String? character3dId;

  /// Legacy character-avatar JSON spec (migration 0026). No longer
  /// read or written by the app — the fluttermoji customizer was
  /// removed. Column stays in the DB and the field stays on the model
  /// for backward compatibility with rows that already have data.
  /// Safe to drop in a future migration.
  final Map<String, dynamic>? avatarConfig;

  // ── Streak recovery state (migration 0016) ────────────────────────────────
  /// Date of the missed day that triggered recovery mode. Null when not in
  /// recovery. When set, the user has the next two days to BOTH meet
  /// their daily target or the streak ends.
  final DateTime? streakRecoveryStartedAt;

  /// Locks the recovery mechanic to one use per streak run. Resets to
  /// false when a fresh streak begins (current_streak goes 0 → 1).
  final bool streakUsedRecoveryInCurrentRun;

  /// Highest streak length (in days) we've already awarded a +100 milestone
  /// XP for. Milestones land at day 25, 50, 75, 100, …; the streak service
  /// only awards when `current_streak % 25 == 0` AND `current_streak >
  /// last_streak_milestone_awarded`.
  final int lastStreakMilestoneAwarded;

  // ── Subscription (migration 0031) ─────────────────────────────────────────
  /// Current entitlement level — Free (default), Pro, or Family.
  final SubscriptionTier subscriptionTier;

  /// Timestamp the paid plan lapses. NULL for Free. Nightly cron
  /// (`refresh_expired_subscriptions`) reverts the tier back to Free
  /// once this is in the past.
  final DateTime? subscriptionExpiresAt;

  /// Billing cadence — "monthly" or "yearly". NULL for Free.
  final String? subscriptionBillingPeriod;

  /// Self-FK. Non-null when this user is a MEMBER of a family plan
  /// (accepted an invite). Family owners have `subscriptionTier = family`
  /// but `familyOwnerId = null`.
  final String? familyOwnerId;

  /// `yyyy-mm` of the last calendar month the user was paid the
  /// monthly-streak XP bonus (200/500/1000 XP by tier). Prevents
  /// double-payout.
  final String? lastPerfectMonthAwarded;

  const UserModel({
    required this.userId,
    required this.userCode,
    required this.displayName,
    this.preferredName,
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
    this.activityScore = 0,
    this.battlesWonCount = 0,
    this.battlesPlayedCount = 0,
    this.missionsCompletedCount = 0,
    this.lastStepXPThreshold = 0,
    this.lastStepXPDate = '',
    this.dailyGoalXPAwardedDate,
    this.xpEarnedToday = 0,
    this.xpEarnedTodayDate = '',
    this.friends = const [],
    this.clanId,
    required this.createdAt,
    required this.lastActiveAt,
    this.notifPush = true,
    this.notifEmail = true,
    this.notifBattles = true,
    this.notifFriends = true,
    this.countryCode,
    this.countryName,
    this.stateName,
    this.districtName,
    this.homeLat,
    this.homeLng,
    this.homeSetAt,
    this.dateOfBirth,
    this.gender,
    this.fitnessLevel,
    this.heightCm,
    this.weightKg,
    this.battleAvatarId = 'avatar_01',
    this.character3dId,
    this.avatarConfig,
    this.streakRecoveryStartedAt,
    this.streakUsedRecoveryInCurrentRun = false,
    this.lastStreakMilestoneAwarded = 0,
    this.subscriptionTier = SubscriptionTier.basic,
    this.subscriptionExpiresAt,
    this.subscriptionBillingPeriod,
    this.familyOwnerId,
    this.lastPerfectMonthAwarded,
  });

  /// Name to render in friendly UI surfaces (leaderboard rows,
  /// share cards, greetings, etc.). Prefers [preferredName] when the
  /// user has answered the "what do you want to be called" question;
  /// otherwise falls back to the full [displayName]. Empty / whitespace
  /// preferred names are ignored so a stray blank never eats the
  /// display name.
  String get friendlyName {
    final trimmed = preferredName?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    return displayName;
  }

  /// Whether the user has set a home district yet.
  bool get hasHome =>
      countryCode != null && countryCode!.isNotEmpty;

  /// Whether the mandatory onboarding survey has been completed. A user with
  /// `displayName` but missing DOB/gender/fitness is a pre-survey user and
  /// should be funneled through the "Complete your profile" sheet on first
  /// launch after the update.
  bool get hasCompletedSurvey =>
      displayName.isNotEmpty &&
      dateOfBirth != null &&
      gender != null &&
      fitnessLevel != null;

  /// Computed age from [dateOfBirth]. Returns null when DOB isn't set.
  int? get age {
    final dob = dateOfBirth;
    if (dob == null) return null;
    final now = DateTime.now();
    var years = now.year - dob.year;
    if (now.month < dob.month ||
        (now.month == dob.month && now.day < dob.day)) {
      years--;
    }
    return years;
  }

  /// True when [streakRecoveryStartedAt] is set — the streak is paused
  /// awaiting two consecutive made-up days before it resumes.
  bool get isInStreakRecovery => streakRecoveryStartedAt != null;

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
      preferredName: data['preferred_name'] as String?,
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
      activityScore: (data['activity_score'] as num?)?.toInt() ?? 0,
      battlesWonCount:
          (data['battles_won_count'] as num?)?.toInt() ?? 0,
      battlesPlayedCount:
          (data['battles_played_count'] as num?)?.toInt() ?? 0,
      missionsCompletedCount:
          (data['missions_completed_count'] as num?)?.toInt() ?? 0,
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
      notifPush: data['notif_push'] as bool? ?? true,
      notifEmail: data['notif_email'] as bool? ?? true,
      notifBattles: data['notif_battles'] as bool? ?? true,
      notifFriends: data['notif_friends'] as bool? ?? true,
      countryCode: data['country_code'] as String?,
      countryName: data['country_name'] as String?,
      stateName: data['state_name'] as String?,
      districtName: data['district_name'] as String?,
      homeLat: (data['home_lat'] as num?)?.toDouble(),
      homeLng: (data['home_lng'] as num?)?.toDouble(),
      homeSetAt: parseTs(data['home_set_at']),
      dateOfBirth: parseTs(data['date_of_birth']),
      gender: Gender.fromWire(data['gender'] as String?),
      fitnessLevel: FitnessLevel.fromWire(data['fitness_level'] as String?),
      heightCm: (data['height_cm'] as num?)?.toInt(),
      weightKg: (data['weight_kg'] as num?)?.toDouble(),
      battleAvatarId:
          (data['battle_avatar_id'] as String?) ?? 'avatar_01',
      character3dId: data['character_3d_id'] as String?,
      // JSONB — Supabase returns as Map<String, dynamic> already; the
      // cast keeps the value type honest.
      avatarConfig: (data['avatar_config'] as Map?)?.cast<String, dynamic>(),
      streakRecoveryStartedAt: parseTs(data['streak_recovery_started_at']),
      streakUsedRecoveryInCurrentRun:
          data['streak_used_recovery_in_current_run'] as bool? ?? false,
      lastStreakMilestoneAwarded:
          (data['last_streak_milestone_awarded'] as num?)?.toInt() ?? 0,
      subscriptionTier:
          SubscriptionTier.fromWire(data['subscription_tier'] as String?),
      subscriptionExpiresAt: parseTs(data['subscription_expires_at']),
      subscriptionBillingPeriod:
          data['subscription_billing_period'] as String?,
      familyOwnerId: data['family_owner_id'] as String?,
      lastPerfectMonthAwarded:
          data['last_perfect_month_awarded'] as String?,
    );
  }

  /// Serializes to the payload the `public.profiles` table expects
  /// (snake_case columns, ISO timestamps, no `friends` array — friends
  /// are derived from `friend_relationships`, not stored inline).
  Map<String, dynamic> toSupabaseRow() {
    String? iso(DateTime? d) => d?.toUtc().toIso8601String();
    return {
      'id': userId,
      'user_code': userCode,
      'display_name': displayName,
      'preferred_name': preferredName,
      'avatar_url': avatarURL,
      'email': email,
      'phone': phone,
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
      'notif_push': notifPush,
      'notif_email': notifEmail,
      'notif_battles': notifBattles,
      'notif_friends': notifFriends,
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
      // Date-only column on Supabase — `.toIso8601String().split('T')[0]`
      // would also work but `date` columns accept full ISO strings too and
      // Postgres truncates to the date portion.
      'date_of_birth': iso(dateOfBirth)?.split('T').first,
      'gender': gender?.wire,
      'fitness_level': fitnessLevel?.wire,
      'height_cm': heightCm,
      'weight_kg': weightKg,
      'battle_avatar_id': battleAvatarId,
      'character_3d_id': character3dId,
      'avatar_config': avatarConfig,
      'streak_recovery_started_at':
          iso(streakRecoveryStartedAt)?.split('T').first,
      'streak_used_recovery_in_current_run': streakUsedRecoveryInCurrentRun,
      'subscription_tier': subscriptionTier.wire,
      'subscription_expires_at': iso(subscriptionExpiresAt),
      'subscription_billing_period': subscriptionBillingPeriod,
      'family_owner_id': familyOwnerId,
      'last_perfect_month_awarded': lastPerfectMonthAwarded,
      'last_streak_milestone_awarded': lastStreakMilestoneAwarded,
    };
  }
  UserModel copyWith({
    String? displayName,
    String? preferredName,
    String? avatarURL,
    String? phone,
    int? level,
    int? totalXP,
    int? currentStreak,
    int? bestStreak,
    int? rank,
    int? dailyStepGoal,
    int? totalStepsAllTime,
    int? activityScore,
    int? battlesWonCount,
    int? battlesPlayedCount,
    int? missionsCompletedCount,
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
    DateTime? dateOfBirth,
    Gender? gender,
    FitnessLevel? fitnessLevel,
    int? heightCm,
    double? weightKg,
    String? battleAvatarId,
    String? character3dId,
    Map<String, dynamic>? avatarConfig,
    DateTime? streakRecoveryStartedAt,
    bool? streakUsedRecoveryInCurrentRun,
    int? lastStreakMilestoneAwarded,
    bool clearStreakRecovery = false,
    bool? notifPush,
    bool? notifEmail,
    bool? notifBattles,
    bool? notifFriends,
    SubscriptionTier? subscriptionTier,
    DateTime? subscriptionExpiresAt,
    String? subscriptionBillingPeriod,
    String? familyOwnerId,
    String? lastPerfectMonthAwarded,
    bool clearSubscription = false,
    bool clearFamilyOwner = false,
  }) {
    return UserModel(
      userId: userId,
      userCode: userCode,
      displayName: displayName ?? this.displayName,
      preferredName: preferredName ?? this.preferredName,
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
      activityScore: activityScore ?? this.activityScore,
      battlesWonCount: battlesWonCount ?? this.battlesWonCount,
      battlesPlayedCount: battlesPlayedCount ?? this.battlesPlayedCount,
      missionsCompletedCount:
          missionsCompletedCount ?? this.missionsCompletedCount,
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
      dateOfBirth: dateOfBirth ?? this.dateOfBirth,
      gender: gender ?? this.gender,
      fitnessLevel: fitnessLevel ?? this.fitnessLevel,
      heightCm: heightCm ?? this.heightCm,
      weightKg: weightKg ?? this.weightKg,
      battleAvatarId: battleAvatarId ?? this.battleAvatarId,
      character3dId: character3dId ?? this.character3dId,
      avatarConfig: avatarConfig ?? this.avatarConfig,
      // clearStreakRecovery wins over an explicit pass — used by the
      // streak service when recovery is completed or expired.
      streakRecoveryStartedAt: clearStreakRecovery
          ? null
          : (streakRecoveryStartedAt ?? this.streakRecoveryStartedAt),
      streakUsedRecoveryInCurrentRun:
          streakUsedRecoveryInCurrentRun ?? this.streakUsedRecoveryInCurrentRun,
      lastStreakMilestoneAwarded:
          lastStreakMilestoneAwarded ?? this.lastStreakMilestoneAwarded,
      notifPush: notifPush ?? this.notifPush,
      notifEmail: notifEmail ?? this.notifEmail,
      notifBattles: notifBattles ?? this.notifBattles,
      notifFriends: notifFriends ?? this.notifFriends,
      subscriptionTier: clearSubscription
          ? SubscriptionTier.basic
          : (subscriptionTier ?? this.subscriptionTier),
      subscriptionExpiresAt: clearSubscription
          ? null
          : (subscriptionExpiresAt ?? this.subscriptionExpiresAt),
      subscriptionBillingPeriod: clearSubscription
          ? null
          : (subscriptionBillingPeriod ?? this.subscriptionBillingPeriod),
      familyOwnerId: (clearSubscription || clearFamilyOwner)
          ? null
          : (familyOwnerId ?? this.familyOwnerId),
      lastPerfectMonthAwarded:
          lastPerfectMonthAwarded ?? this.lastPerfectMonthAwarded,
    );
  }
}
