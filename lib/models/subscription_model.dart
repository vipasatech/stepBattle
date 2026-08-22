/// Subscription-plan domain — tiers, per-tier caps, live usage, and the
/// `LimitDecision` helpers the UI reads before letting a user create /
/// join a battle.
///
/// Sits on top of the DB shape from migrations 0031 + 0032 + **0051**:
///   * `profiles.subscription_tier` (enum: basic / pro / max —
///     migration 0051 renamed 'free' → 'basic' and 'family' → 'max'
///     across every existing row and pushed the new default to
///     'basic'. 'free' and 'family' remain in the enum type
///     (Postgres can't drop enum values) but no row references them.)
///   * `profiles.subscription_expires_at`
///   * `profiles.subscription_billing_period` (monthly / yearly)
///   * `profiles.family_owner_id` (self-FK — kept for grandfathered
///     Family members; new Max signups don't populate it)
///   * `subscription_usage_current` view — monthly counters joined to tier
///
/// Everything downstream (button enable/disable, upgrade CTAs,
/// "remaining X" pills) reads through [SubscriptionState].
library;

import 'dart:math' as math;

/// Sentinel used inside [SubscriptionLimits] to mean "no cap". Any
/// remaining-count getter that lands on `-1` internally returns a
/// very large positive number so UI code can render "∞" or just
/// display the number without a special case.
const int _kUnlimited = -1;

/// Subscription tier. Wire values match the Postgres enum after
/// migration 0051 renamed 'free' → 'basic' and 'family' → 'max'.
/// The legacy wire strings are still parsed on the client for
/// safety (a stale profile row from before backfill would otherwise
/// fall through the switch), but the DB no longer produces them.
enum SubscriptionTier {
  basic,
  pro,
  max;

  String get wire => name;

  static SubscriptionTier fromWire(String? s) => switch (s) {
        'pro' => SubscriptionTier.pro,
        'max' => SubscriptionTier.max,
        'basic' => SubscriptionTier.basic,
        // Legacy backward-compat — migration 0051 rewrote these, but
        // parse them anyway in case a cached row precedes the migration.
        'family' => SubscriptionTier.max,
        'free' => SubscriptionTier.basic,
        _ => SubscriptionTier.basic,
      };

  /// Human-friendly label for CTA copy / plan cards.
  String get displayName => switch (this) {
        SubscriptionTier.basic => 'Basic',
        SubscriptionTier.pro => 'Pro',
        SubscriptionTier.max => 'Max',
      };

  /// The next-higher tier a user should be prompted to upgrade to, or
  /// null if already at the top.
  SubscriptionTier? get nextUp => switch (this) {
        SubscriptionTier.basic => SubscriptionTier.pro,
        SubscriptionTier.pro => SubscriptionTier.max,
        SubscriptionTier.max => null,
      };
}

/// The per-month cap matrix. Kept as a plain class instead of a map so
/// callers get compile-time field access + IDE navigation.
class SubscriptionLimits {
  /// Umbrella cap — total (created + public-joined + private-joined)
  /// per calendar month.
  final int monthlyBattleEntries;

  /// Sub-cap on creates. Cannot exceed [monthlyBattleEntries] in practice
  /// because the umbrella dominates.
  final int monthlyCreates;

  /// Sub-cap on public battles joined. `-1` = unlimited (Pro / Family).
  final int monthlyJoinPublic;

  /// Sub-cap on private battles joined.
  final int monthlyJoinPrivate;

  /// XP paid at the end of a calendar month if the user's step-log
  /// covers every day of that month. Tier-scaled (see spec).
  final int perfectMonthXpBonus;

  /// Retention (in days) — 30 for Free, ~180 for Pro / Family. Server
  /// cron enforces the actual archival; the client can use this for
  /// UI ("history stored for 30 days" / "6 months").
  final int battleHistoryDays;

  const SubscriptionLimits({
    required this.monthlyBattleEntries,
    required this.monthlyCreates,
    required this.monthlyJoinPublic,
    required this.monthlyJoinPrivate,
    required this.perfectMonthXpBonus,
    required this.battleHistoryDays,
  });

  bool get unlimitedPublic => monthlyJoinPublic == _kUnlimited;
  bool get unlimitedPrivate => monthlyJoinPrivate == _kUnlimited;

  // Migration 0051 caps — matches the spec table.
  static const SubscriptionLimits basic = SubscriptionLimits(
    monthlyBattleEntries: 30,
    monthlyCreates: 10,
    monthlyJoinPublic: 5,
    monthlyJoinPrivate: 30,
    perfectMonthXpBonus: 200,
    battleHistoryDays: 30,
  );

  static const SubscriptionLimits pro = SubscriptionLimits(
    monthlyBattleEntries: 45,
    monthlyCreates: 30,
    monthlyJoinPublic: _kUnlimited,
    monthlyJoinPrivate: 45,
    perfectMonthXpBonus: 500,
    battleHistoryDays: 180,
  );

  static const SubscriptionLimits max = SubscriptionLimits(
    monthlyBattleEntries: 60,
    monthlyCreates: 45,
    monthlyJoinPublic: _kUnlimited,
    monthlyJoinPrivate: 60,
    perfectMonthXpBonus: 1000,
    battleHistoryDays: 180,
  );

  static SubscriptionLimits forTier(SubscriptionTier tier) => switch (tier) {
        SubscriptionTier.basic => basic,
        SubscriptionTier.pro => pro,
        SubscriptionTier.max => max,
      };
}

/// INR pricing for the paid tiers. Kept alongside [SubscriptionLimits]
/// so the plan-card UI reads all tier data from one place. Change here
/// → prices update everywhere the CTA sheet renders.
class SubscriptionPricing {
  /// Recurring price if the user pays month-to-month, in whole INR.
  final int monthlyRupees;

  /// Recurring price if the user pays annually, in whole INR. Usually
  /// a discount vs `monthlyRupees × 12` (see [yearlyDiscountPercent]).
  final int yearlyRupees;

  const SubscriptionPricing({
    required this.monthlyRupees,
    required this.yearlyRupees,
  });

  /// Approximate effective monthly cost on the yearly plan. Used in
  /// the plan card's "₹125/mo when billed yearly" copy.
  int get yearlyMonthEquivalent => (yearlyRupees / 12).round();

  /// Whole-percentage discount the yearly plan gives vs paying monthly
  /// for a year. Used in the "Save X%" badge on the yearly toggle.
  int get yearlyDiscountPercent {
    if (monthlyRupees <= 0) return 0;
    final annualIfMonthly = monthlyRupees * 12;
    if (annualIfMonthly <= 0) return 0;
    return (100 - (yearlyRupees / annualIfMonthly * 100)).round();
  }

  // Pricing is unchanged from the pre-rename plans: Pro = old Pro,
  // Max = old Family. If pricing needs a rework, this is the one place.
  static const SubscriptionPricing pro = SubscriptionPricing(
    monthlyRupees: 149,
    yearlyRupees: 1499,
  );

  static const SubscriptionPricing max = SubscriptionPricing(
    monthlyRupees: 299,
    yearlyRupees: 2999,
  );

  /// Null for [SubscriptionTier.basic] — Basic is the free tier.
  static SubscriptionPricing? forTier(SubscriptionTier tier) =>
      switch (tier) {
        SubscriptionTier.basic => null,
        SubscriptionTier.pro => pro,
        SubscriptionTier.max => max,
      };
}

/// External subscription checkout — the mobile app hands off to a
/// hosted web checkout that runs the Razorpay flow. The
/// `?uid=…&plan=…&period=…` query params are appended by
/// [UpgradeCTASheet].
const String kSubscriptionUpgradeUrlBase =
    'https://www.stepbattle.fit/upgrade';

/// Live counters from `subscription_usage_current` for the current
/// calendar month. Missing DB row → all zeros (Postgres view already
/// `COALESCE`s to 0, but we default here too so a null network read
/// during cold start doesn't crash the getter chain).
class SubscriptionUsage {
  final int battlesCreated;
  final int publicBattlesJoined;
  final int privateBattlesJoined;

  const SubscriptionUsage({
    this.battlesCreated = 0,
    this.publicBattlesJoined = 0,
    this.privateBattlesJoined = 0,
  });

  static const SubscriptionUsage zero = SubscriptionUsage();

  int get totalEntries =>
      battlesCreated + publicBattlesJoined + privateBattlesJoined;

  /// Read from the `subscription_usage_current` view row.
  factory SubscriptionUsage.fromViewRow(Map<String, dynamic> row) {
    return SubscriptionUsage(
      battlesCreated: (row['battles_created'] as num?)?.toInt() ?? 0,
      publicBattlesJoined:
          (row['public_battles_joined'] as num?)?.toInt() ?? 0,
      privateBattlesJoined:
          (row['private_battles_joined'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Verdict returned by every `SubscriptionState.can*` gate. The UI
/// disables the affected button when `!allowed` and shows [reason]
/// inline (tooltip / snackbar) with a CTA to [upgradeTo].
class LimitDecision {
  final bool allowed;

  /// Non-null when [allowed] is true — how many more the user can do
  /// before hitting the cap. Reported as a large sentinel (~9999) for
  /// unlimited tiers.
  final int? remaining;

  /// Non-null when [allowed] is false — one-line human explanation
  /// ("You've used 5/5 creates this month.").
  final String? reason;

  /// The tier the user would need to upgrade to. Null when they're
  /// already at Family (no higher plan exists).
  final SubscriptionTier? upgradeTo;

  const LimitDecision._({
    required this.allowed,
    this.remaining,
    this.reason,
    this.upgradeTo,
  });

  factory LimitDecision.allowed({int? remaining}) => LimitDecision._(
        allowed: true,
        remaining: remaining,
      );

  factory LimitDecision.blocked({
    required String reason,
    SubscriptionTier? upgradeTo,
  }) =>
      LimitDecision._(
        allowed: false,
        reason: reason,
        upgradeTo: upgradeTo,
      );
}

/// The all-in-one view of the current user's subscription — tier +
/// expiry + family role + live usage + derived helpers.
///
/// Everything the UI needs to gate a battle action reads from this
/// single object. Constructed by `subscriptionProvider` on every
/// realtime update from the profile row or the usage view.
class SubscriptionState {
  final SubscriptionTier tier;
  final DateTime? expiresAt;
  final String? billingPeriod;
  final String? familyOwnerId;
  final SubscriptionUsage usage;

  const SubscriptionState({
    required this.tier,
    this.expiresAt,
    this.billingPeriod,
    this.familyOwnerId,
    this.usage = SubscriptionUsage.zero,
  });

  /// Default / free-tier state. Renamed from `free` for the Basic
  /// rename; a legacy `free` const alias is provided below so any
  /// caller that hasn't been updated still compiles.
  static const SubscriptionState basic = SubscriptionState(
    tier: SubscriptionTier.basic,
  );

  /// Deprecated alias for backward compatibility with callers written
  /// before migration 0051. Points at the same Basic default.
  @Deprecated('Use SubscriptionState.basic')
  static const SubscriptionState free = basic;

  SubscriptionLimits get limits => SubscriptionLimits.forTier(tier);

  /// True for a user grandfathered from the old Family plan — either
  /// the original owner (Max tier, familyOwnerId null) OR a member
  /// (familyOwnerId points at the owner). New Max signups don't set
  /// familyOwnerId, so this returns false for them.
  bool get isFamilyMember => familyOwnerId != null;

  /// Grandfathered Family owner — Max tier with the original owner
  /// role. New Max signups return false (no family-share for them).
  bool get isFamilyOwner =>
      tier == SubscriptionTier.max && familyOwnerId == null;

  /// The user is on a paid plan (Pro or Max).
  bool get isPaid => tier != SubscriptionTier.basic;

  /// Days until [expiresAt]. Null when not expiring. Negative if
  /// already lapsed (cron hasn't rolled them back to Free yet).
  int? get daysUntilExpiry {
    final expiry = expiresAt;
    if (expiry == null) return null;
    final now = DateTime.now();
    return expiry.difference(now).inDays;
  }

  int get remainingEntries =>
      math.max(0, limits.monthlyBattleEntries - usage.totalEntries);

  int get remainingCreates =>
      math.max(0, limits.monthlyCreates - usage.battlesCreated);

  int get remainingPublic {
    if (limits.unlimitedPublic) return 9999;
    return math.max(0, limits.monthlyJoinPublic - usage.publicBattlesJoined);
  }

  int get remainingPrivate {
    if (limits.unlimitedPrivate) return 9999;
    return math.max(
        0, limits.monthlyJoinPrivate - usage.privateBattlesJoined);
  }

  /// Can the user create a new battle right now? Checks both the
  /// per-category create cap AND the umbrella `Battle Entries` cap.
  LimitDecision canCreateBattle() {
    if (remainingCreates <= 0) {
      return LimitDecision.blocked(
        reason:
            'You\'ve used ${usage.battlesCreated}/${limits.monthlyCreates} creates this month.',
        upgradeTo: tier.nextUp,
      );
    }
    if (remainingEntries <= 0) {
      return LimitDecision.blocked(
        reason:
            'You\'ve used your monthly battle entries (${limits.monthlyBattleEntries}).',
        upgradeTo: tier.nextUp,
      );
    }
    return LimitDecision.allowed(
      remaining: math.min(remainingCreates, remainingEntries),
    );
  }

  /// Can the user join a public battle right now?
  LimitDecision canJoinPublicBattle() {
    if (!limits.unlimitedPublic && remainingPublic <= 0) {
      return LimitDecision.blocked(
        reason:
            'You\'ve used ${usage.publicBattlesJoined}/${limits.monthlyJoinPublic} public joins this month.',
        upgradeTo: tier.nextUp,
      );
    }
    if (remainingEntries <= 0) {
      return LimitDecision.blocked(
        reason:
            'You\'ve used your monthly battle entries (${limits.monthlyBattleEntries}).',
        upgradeTo: tier.nextUp,
      );
    }
    return LimitDecision.allowed(
      remaining:
          limits.unlimitedPublic ? remainingEntries : math.min(remainingPublic, remainingEntries),
    );
  }

  /// Can the user join a private battle right now?
  LimitDecision canJoinPrivateBattle() {
    if (remainingPrivate <= 0) {
      return LimitDecision.blocked(
        reason:
            'You\'ve used ${usage.privateBattlesJoined}/${limits.monthlyJoinPrivate} private joins this month.',
        upgradeTo: tier.nextUp,
      );
    }
    if (remainingEntries <= 0) {
      return LimitDecision.blocked(
        reason:
            'You\'ve used your monthly battle entries (${limits.monthlyBattleEntries}).',
        upgradeTo: tier.nextUp,
      );
    }
    return LimitDecision.allowed(
      remaining: math.min(remainingPrivate, remainingEntries),
    );
  }

  SubscriptionState copyWith({
    SubscriptionTier? tier,
    DateTime? expiresAt,
    String? billingPeriod,
    String? familyOwnerId,
    SubscriptionUsage? usage,
    bool clearFamilyOwner = false,
    bool clearExpiry = false,
  }) {
    return SubscriptionState(
      tier: tier ?? this.tier,
      expiresAt: clearExpiry ? null : (expiresAt ?? this.expiresAt),
      billingPeriod: billingPeriod ?? this.billingPeriod,
      familyOwnerId:
          clearFamilyOwner ? null : (familyOwnerId ?? this.familyOwnerId),
      usage: usage ?? this.usage,
    );
  }
}
