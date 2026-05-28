import 'package:cloud_firestore/cloud_firestore.dart';

enum FriendStatus { pending, accepted, rejected }

class FriendRelationship {
  final String relationshipId;
  final String fromUserId;
  final String toUserId;
  final FriendStatus status;
  final DateTime createdAt;

  const FriendRelationship({
    required this.relationshipId,
    required this.fromUserId,
    required this.toUserId,
    required this.status,
    required this.createdAt,
  });

  factory FriendRelationship.fromFirestore(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    return FriendRelationship(
      relationshipId: doc.id,
      fromUserId: d['fromUserId'] as String? ?? '',
      toUserId: d['toUserId'] as String? ?? '',
      status: _parseStatus(d['status'] as String? ?? 'pending'),
      createdAt: (d['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  /// Build from a Supabase `public.friend_relationships` row.
  factory FriendRelationship.fromSupabaseRow(Map<String, dynamic> d) {
    return FriendRelationship(
      relationshipId: d['id'] as String? ?? '',
      fromUserId: d['from_user_id'] as String? ?? '',
      toUserId: d['to_user_id'] as String? ?? '',
      status: _parseStatus(d['status'] as String? ?? 'pending'),
      createdAt:
          DateTime.tryParse(d['created_at']?.toString() ?? '') ??
              DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() => {
        'fromUserId': fromUserId,
        'toUserId': toUserId,
        'status': status.name,
        'createdAt': Timestamp.fromDate(createdAt),
      };

  static FriendStatus _parseStatus(String s) => switch (s) {
        'accepted' => FriendStatus.accepted,
        'rejected' => FriendStatus.rejected,
        _ => FriendStatus.pending,
      };
}
