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

  /// Build from a Supabase `leaderboard_snapshots` row (precomputed) OR
  /// a `profiles` row (used for friends + geo-scoped boards, ranked
  /// client-side by query order). Both shapes share the same field names
  /// once snake_case is mapped — rank is optional since it isn't stored
  /// on profiles.
  factory LeaderboardEntry.fromSupabaseRow(
    Map<String, dynamic> d, {
    int? overrideRank,
  }) {
    return LeaderboardEntry(
      // From profiles the PK is `id`; from leaderboard_snapshots it's `user_id`.
      userId: (d['user_id'] ?? d['id']) as String? ?? '',
      displayName: d['display_name'] as String? ?? '',
      avatarURL: d['avatar_url'] as String?,
      totalXP: (d['total_xp'] as num?)?.toInt() ?? 0,
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
