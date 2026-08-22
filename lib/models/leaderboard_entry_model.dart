class LeaderboardEntry {
  final String userId;
  final String displayName;

  /// Optional nickname mirrored from `profiles.preferred_name` (see
  /// migration 0024). When set, [friendlyName] prefers it over
  /// [displayName]; null falls back to the display name.
  final String? preferredName;

  final String? avatarURL;

  /// Bitmoji-style character avatar spec — see [UserModel.avatarConfig].
  /// When set, renderers should prefer this over [avatarURL]. Loaded
  /// verbatim from `profiles.avatar_config` (JSONB, migration 0026).
  final Map<String, dynamic>? avatarConfig;

  final int totalXP;
  final int rank;
  final DateTime updatedAt;

  const LeaderboardEntry({
    required this.userId,
    required this.displayName,
    this.preferredName,
    this.avatarURL,
    this.avatarConfig,
    required this.totalXP,
    required this.rank,
    required this.updatedAt,
  });

  /// Rendered name for row / hero / floating card. See
  /// `UserModel.friendlyName` for the same fallback contract on the
  /// signed-in user's profile.
  String get friendlyName {
    final trimmed = preferredName?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    return displayName;
  }
  /// Build from a Supabase row. Accepted shapes:
  ///   • `profile_earned_xp` view — has both `earned_xp` and `total_xp`;
  ///     leaderboard reads use this and `totalXP` gets the *earned* value.
  ///   • `profiles` table row — only `total_xp`; legacy read paths.
  ///   • `leaderboard_snapshots` row (precomputed, unused).
  ///
  /// Rank is optional since neither view carries it — call sites stamp
  /// positional 1-based ranks after ordering.
  factory LeaderboardEntry.fromSupabaseRow(
    Map<String, dynamic> d, {
    int? overrideRank,
  }) {
    // Prefer `earned_xp` (from the leaderboard view) so the visible
    // XP number matches what the board is ranked by. Fall back to
    // `total_xp` for legacy queries that hit the raw profiles table.
    final xp = (d['earned_xp'] as num?)?.toInt() ??
        (d['total_xp'] as num?)?.toInt() ??
        0;
    return LeaderboardEntry(
      // From profiles the PK is `id`; from leaderboard_snapshots it's `user_id`.
      userId: (d['user_id'] ?? d['id']) as String? ?? '',
      displayName: d['display_name'] as String? ?? '',
      // `profile_earned_xp` inherits every column from `profiles`, so
      // the view carries preferred_name too — no query change needed.
      preferredName: d['preferred_name'] as String?,
      avatarURL: d['avatar_url'] as String?,
      avatarConfig:
          (d['avatar_config'] as Map?)?.cast<String, dynamic>(),
      totalXP: xp,
      rank: overrideRank ?? (d['rank'] as num?)?.toInt() ?? 0,
      updatedAt:
          DateTime.tryParse(d['updated_at']?.toString() ?? '') ??
              DateTime.now(),
    );
  }}
