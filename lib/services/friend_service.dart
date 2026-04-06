import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/friend_relationship_model.dart';
import '../models/user_model.dart';

class FriendService {
  final FirebaseFirestore _firestore;

  FriendService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _users =>
      _firestore.collection('users');

  CollectionReference<Map<String, dynamic>> get _relationships =>
      _firestore.collection('friend_relationships');

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  /// Search users by display name prefix.
  Future<List<UserModel>> searchByUsername(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    final snap = await _users
        .where('displayName', isGreaterThanOrEqualTo: q)
        .where('displayName', isLessThanOrEqualTo: '$q\uf8ff')
        .limit(15)
        .get();
    return snap.docs.map((d) => UserModel.fromFirestore(d)).toList();
  }

  /// Search user by exact user ID.
  Future<UserModel?> searchByUserId(String userId) async {
    final doc = await _users.doc(userId).get();
    if (!doc.exists) return null;
    return UserModel.fromFirestore(doc);
  }

  // ---------------------------------------------------------------------------
  // Friend requests
  // ---------------------------------------------------------------------------

  /// Send a friend request.
  Future<void> sendRequest({
    required String fromUserId,
    required String toUserId,
  }) async {
    // Check if relationship already exists
    final existing = await _relationships
        .where('fromUserId', isEqualTo: fromUserId)
        .where('toUserId', isEqualTo: toUserId)
        .limit(1)
        .get();
    if (existing.docs.isNotEmpty) return;

    // Check reverse direction too
    final reverse = await _relationships
        .where('fromUserId', isEqualTo: toUserId)
        .where('toUserId', isEqualTo: fromUserId)
        .limit(1)
        .get();
    if (reverse.docs.isNotEmpty) return;

    await _relationships.add(FriendRelationship(
      relationshipId: '',
      fromUserId: fromUserId,
      toUserId: toUserId,
      status: FriendStatus.pending,
      createdAt: DateTime.now(),
    ).toFirestore());
  }

  /// Accept a friend request — updates relationship + adds to both users' friends lists.
  Future<void> acceptRequest(String relationshipId) async {
    final doc = await _relationships.doc(relationshipId).get();
    if (!doc.exists) return;
    final rel = FriendRelationship.fromFirestore(doc);

    await _relationships.doc(relationshipId).update({'status': 'accepted'});

    // Add to both users' friends arrays
    await _users.doc(rel.fromUserId).update({
      'friends': FieldValue.arrayUnion([rel.toUserId]),
    });
    await _users.doc(rel.toUserId).update({
      'friends': FieldValue.arrayUnion([rel.fromUserId]),
    });
  }

  /// Reject a friend request.
  Future<void> rejectRequest(String relationshipId) async {
    await _relationships.doc(relationshipId).update({'status': 'rejected'});
  }

  /// Remove a friend from both users.
  Future<void> removeFriend({
    required String userId,
    required String friendId,
  }) async {
    await _users.doc(userId).update({
      'friends': FieldValue.arrayRemove([friendId]),
    });
    await _users.doc(friendId).update({
      'friends': FieldValue.arrayRemove([userId]),
    });
  }

  // ---------------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------------

  /// Get the full UserModel for each friend ID.
  Future<List<UserModel>> getFriends(List<String> friendIds) async {
    if (friendIds.isEmpty) return [];
    final results = <UserModel>[];
    for (var i = 0; i < friendIds.length; i += 30) {
      final batch = friendIds.sublist(
          i, i + 30 > friendIds.length ? friendIds.length : i + 30);
      final snap =
          await _users.where(FieldPath.documentId, whereIn: batch).get();
      results.addAll(snap.docs.map((d) => UserModel.fromFirestore(d)));
    }
    return results;
  }

  /// Stream pending friend requests for a user.
  Stream<List<FriendRelationship>> watchPendingRequests(String userId) {
    return _relationships
        .where('toUserId', isEqualTo: userId)
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => FriendRelationship.fromFirestore(d)).toList());
  }
}
