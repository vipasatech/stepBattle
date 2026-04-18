import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/friend_relationship_model.dart';
import '../models/user_model.dart';

/// Friend system — approval-based. Searches by username or userCode.
class FriendService {
  final FirebaseFirestore _firestore;

  FriendService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _users =>
      _firestore.collection('users');

  CollectionReference<Map<String, dynamic>> get _relationships =>
      _firestore.collection('friend_relationships');

  CollectionReference<Map<String, dynamic>> get _notifications =>
      _firestore.collection('notifications');

  // ---------------------------------------------------------------------------
  // Search — by username prefix OR by userCode
  // ---------------------------------------------------------------------------

  /// Smart search: if query starts with "#" treat as userCode, otherwise as username.
  Future<List<UserModel>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    if (q.startsWith('#')) {
      final user = await searchByUserCode(q.toUpperCase());
      return user != null ? [user] : [];
    }
    return searchByUsername(q);
  }

  /// Case-insensitive username prefix search.
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

  /// Exact userCode match (e.g. "#U4X92").
  Future<UserModel?> searchByUserCode(String userCode) async {
    final snap = await _users
        .where('userCode', isEqualTo: userCode)
        .limit(1)
        .get();
    if (snap.docs.isEmpty) return null;
    return UserModel.fromFirestore(snap.docs.first);
  }

  /// Exact userId lookup.
  Future<UserModel?> searchByUserId(String userId) async {
    final doc = await _users.doc(userId).get();
    if (!doc.exists) return null;
    return UserModel.fromFirestore(doc);
  }

  // ---------------------------------------------------------------------------
  // Friend requests
  // ---------------------------------------------------------------------------

  /// Send a friend request. Creates a pending relationship doc + notification.
  /// Returns the relationship ID, or null if request already existed.
  Future<String?> sendRequest({
    required String fromUserId,
    required String toUserId,
    required String fromDisplayName,
  }) async {
    if (fromUserId == toUserId) return null;

    // Deduplicate: check either direction
    final forward = await _relationships
        .where('fromUserId', isEqualTo: fromUserId)
        .where('toUserId', isEqualTo: toUserId)
        .limit(1)
        .get();
    if (forward.docs.isNotEmpty) return forward.docs.first.id;

    final reverse = await _relationships
        .where('fromUserId', isEqualTo: toUserId)
        .where('toUserId', isEqualTo: fromUserId)
        .limit(1)
        .get();
    if (reverse.docs.isNotEmpty) return reverse.docs.first.id;

    // Create request
    final doc = await _relationships.add(FriendRelationship(
      relationshipId: '',
      fromUserId: fromUserId,
      toUserId: toUserId,
      status: FriendStatus.pending,
      createdAt: DateTime.now(),
    ).toFirestore());

    // Queue push notification (Cloud Function picks this up)
    await _notifications.add({
      'userId': toUserId,
      'type': 'friend_request',
      'title': 'New Friend Request',
      'body': '$fromDisplayName wants to be your friend',
      'data': {
        'relationshipId': doc.id,
        'fromUserId': fromUserId,
      },
      'read': false,
      'createdAt': Timestamp.now(),
    });

    return doc.id;
  }

  /// Accept a friend request — updates status, adds to both friends arrays,
  /// queues push notification to the sender.
  Future<void> acceptRequest(String relationshipId) async {
    final doc = await _relationships.doc(relationshipId).get();
    if (!doc.exists) return;
    final rel = FriendRelationship.fromFirestore(doc);

    await _relationships.doc(relationshipId).update({'status': 'accepted'});

    await _users.doc(rel.fromUserId).update({
      'friends': FieldValue.arrayUnion([rel.toUserId]),
    });
    await _users.doc(rel.toUserId).update({
      'friends': FieldValue.arrayUnion([rel.fromUserId]),
    });

    // Notify sender
    final accepterDoc = await _users.doc(rel.toUserId).get();
    final accepterName =
        accepterDoc.data()?['displayName'] as String? ?? 'Someone';
    await _notifications.add({
      'userId': rel.fromUserId,
      'type': 'friend_accepted',
      'title': 'Friend Request Accepted',
      'body': '$accepterName is now your friend',
      'data': {'friendUserId': rel.toUserId},
      'read': false,
      'createdAt': Timestamp.now(),
    });
  }

  Future<void> rejectRequest(String relationshipId) async {
    await _relationships.doc(relationshipId).update({'status': 'rejected'});
  }

  /// Cancel an outgoing pending request (from sender).
  Future<void> cancelRequest(String relationshipId) async {
    await _relationships.doc(relationshipId).delete();
  }

  /// Remove an accepted friend from both users.
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
    // Also clean up the relationship doc
    final rels = await _relationships
        .where('fromUserId', whereIn: [userId, friendId])
        .get();
    for (final d in rels.docs) {
      final r = FriendRelationship.fromFirestore(d);
      if ((r.fromUserId == userId && r.toUserId == friendId) ||
          (r.fromUserId == friendId && r.toUserId == userId)) {
        await d.reference.delete();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------------

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

  /// Stream incoming pending friend requests.
  Stream<List<FriendRelationship>> watchIncomingRequests(String userId) {
    return _relationships
        .where('toUserId', isEqualTo: userId)
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => FriendRelationship.fromFirestore(d)).toList());
  }

  /// Stream outgoing pending friend requests.
  Stream<List<FriendRelationship>> watchOutgoingRequests(String userId) {
    return _relationships
        .where('fromUserId', isEqualTo: userId)
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => FriendRelationship.fromFirestore(d)).toList());
  }
}
