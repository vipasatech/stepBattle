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

  Map<String, dynamic> toFirestore() => {
        'displayName': displayName,
        'avatarURL': avatarURL,
        'totalXP': totalXP,
        'rank': rank,
        'updatedAt': Timestamp.fromDate(updatedAt),
      };
}
