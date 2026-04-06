import 'package:cloud_firestore/cloud_firestore.dart';
import '../config/constants.dart';
import '../models/leaderboard_entry_model.dart';

class LeaderboardService {
  final FirebaseFirestore _firestore;

  LeaderboardService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _snapshots =>
      _firestore.collection('leaderboard_snapshots');

  CollectionReference<Map<String, dynamic>> get _users =>
      _firestore.collection('users');

  /// Get global leaderboard (paginated, from pre-computed snapshots).
  Future<List<LeaderboardEntry>> getGlobalRanks({
    int limit = AppConstants.leaderboardPageSize,
    DocumentSnapshot? startAfter,
  }) async {
    var query = _snapshots.orderBy('rank').limit(limit);
    if (startAfter != null) {
      query = query.startAfterDocument(startAfter);
    }
    final snap = await query.get();
    return snap.docs.map((d) => LeaderboardEntry.fromFirestore(d)).toList();
  }

  /// Get friends leaderboard — fetches friends user docs directly, sorted by XP.
  Future<List<LeaderboardEntry>> getFriendsRanks({
    required List<String> friendIds,
  }) async {
    if (friendIds.isEmpty) return [];

    // Firestore 'whereIn' limited to 30 items; batch if needed
    final allEntries = <LeaderboardEntry>[];
    for (var i = 0; i < friendIds.length; i += 30) {
      final batch = friendIds.sublist(
          i, i + 30 > friendIds.length ? friendIds.length : i + 30);
      final snap = await _users
          .where(FieldPath.documentId, whereIn: batch)
          .get();
      for (final doc in snap.docs) {
        final d = doc.data();
        allEntries.add(LeaderboardEntry(
          userId: doc.id,
          displayName: d['displayName'] as String? ?? '',
          avatarURL: d['avatarURL'] as String?,
          totalXP: d['totalXP'] as int? ?? 0,
          rank: d['rank'] as int? ?? 0,
          updatedAt: DateTime.now(),
        ));
      }
    }

    allEntries.sort((a, b) => b.totalXP.compareTo(a.totalXP));
    return allEntries;
  }

  /// Get the current user's rank entry.
  Future<LeaderboardEntry?> getMyRank(String userId) async {
    final doc = await _snapshots.doc(userId).get();
    if (!doc.exists) {
      // Fallback: read from users collection
      final userDoc = await _users.doc(userId).get();
      if (!userDoc.exists) return null;
      final d = userDoc.data()!;
      return LeaderboardEntry(
        userId: userId,
        displayName: d['displayName'] as String? ?? '',
        avatarURL: d['avatarURL'] as String?,
        totalXP: d['totalXP'] as int? ?? 0,
        rank: d['rank'] as int? ?? 0,
        updatedAt: DateTime.now(),
      );
    }
    return LeaderboardEntry.fromFirestore(doc);
  }
}
