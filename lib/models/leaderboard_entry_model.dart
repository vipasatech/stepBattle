import 'package:cloud_firestore/cloud_firestore.dart';

class LeaderboardEntry {
  final String userId;
  final String displayName;
  final String? avatarURL;
  final int totalXP;
  final int rank;
  final DateTime updatedAt;

  const LeaderboardEntry({
    required this.userId,
    required this.displayName,
    this.avatarURL,
    required this.totalXP,
    required this.rank,
    required this.updatedAt,
  });

  factory LeaderboardEntry.fromFirestore(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    return LeaderboardEntry(
      userId: doc.id,
      displayName: d['displayName'] as String? ?? '',
      avatarURL: d['avatarURL'] as String?,
      totalXP: d['totalXP'] as int? ?? 0,
      rank: d['rank'] as int? ?? 0,
      updatedAt: (d['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
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
      avatarURL: d['avatar_url'] as String?,
      totalXP: xp,
      rank: overrideRank ?? (d['rank'] as num?)?.toInt() ?? 0,
      updatedAt:
          DateTime.tryParse(d['updated_at']?.toString() ?? '') ??
              DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() => {
        'displayName': displayName,
        'avatarURL': avatarURL,
        'totalXP': totalXP,
        'rank': rank,
        'updatedAt': Timestamp.fromDate(updatedAt),
      };
}
