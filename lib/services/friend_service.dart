import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/friend_relationship_model.dart';
import '../models/user_model.dart';
import '../utils/app_logger.dart';
import 'supabase_api_client.dart';

/// Friend graph operations on Supabase.
///
/// Friendship is derived from `friend_relationships.status == 'accepted'`
/// (see `acceptedFriendIdsProvider` for the read side). This service
/// owns the writes — send/accept/reject/cancel/remove — plus the user
/// search used by the Add Friends sheet.
class FriendService {
  final SupabaseClient _supabase;

  FriendService({SupabaseClient? supabase})
      : _supabase = supabase ?? Supabase.instance.client;

  // ---------------------------------------------------------------------------
  // Search — by username prefix OR by userCode
  // ---------------------------------------------------------------------------

  Future<List<UserModel>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    if (q.startsWith('#')) {
      final user = await searchByUserCode(q.toUpperCase());
      return user != null ? [user] : [];
    }
    return searchByUsername(q);
  }

  /// Case-insensitive username prefix search via PostgREST's `ilike`.
  ///
  /// Uses a `text_pattern_ops` B-tree index on `LOWER(display_name)`
  /// server-side (migration 0037) so this stays sub-10 ms even at 50k+
  /// profiles. Routed through [SupabaseApiClient] for retry + timing so
  /// a flaky network on a "type-and-Enter" search doesn't just show
  /// empty results without a reason.
  Future<List<UserModel>> searchByUsername(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    try {
      final rows = await SupabaseApiClient.instance.run<List<dynamic>>(
        () async {
          final data = await _supabase
              .from('profiles_public')
              .select()
              .ilike('display_name', '$q%')
              .limit(15);
          return data;
        },
        category: LogCategory.friend,
        name: 'friends.searchByUsername',
        fields: {'qLen': q.length},
      );
      return rows
          .map((r) => UserModel.fromSupabaseRow(r as Map<String, dynamic>))
          .toList();
    } catch (e, s) {
      AppLogger.friend
          .e('searchByUsername:failed', fields: {'q': q}, error: e, stack: s);
      return [];
    }
  }

  Future<UserModel?> searchByUserCode(String userCode) async {
    try {
      final row = await SupabaseApiClient.instance.run<Map<String, dynamic>?>(
        () => _supabase
            .from('profiles_public')
            .select()
            .eq('user_code', userCode)
            .maybeSingle(),
        category: LogCategory.friend,
        name: 'friends.searchByUserCode',
        fields: {'code': userCode},
      );
      if (row == null) return null;
      return UserModel.fromSupabaseRow(row);
    } catch (e, s) {
      AppLogger.friend.e('searchByUserCode:failed',
          fields: {'code': userCode}, error: e, stack: s);
      return null;
    }
  }

  Future<UserModel?> searchByUserId(String userId) async {
    final row = await _supabase
        .from('profiles_public')
        .select()
        .eq('id', userId)
        .maybeSingle();
    if (row == null) return null;
    return UserModel.fromSupabaseRow(row);
  }

  // ---------------------------------------------------------------------------
  // Friend requests
  // ---------------------------------------------------------------------------

  /// Send a friend request. Pending-only dedup: rejecting and later re-asking
  /// is allowed (the rejected row will be re-inserted). Returns the
  /// `friend_relationships.id` of the (existing or new) row, or null when
  /// the call targeted the caller themselves.
  Future<String?> sendRequest({
    required String fromUserId,
    required String toUserId,
    required String fromDisplayName,
  }) async {
    AppLogger.friend.i('sendRequest:start',
        fields: {'from': fromUserId, 'to': toUserId});
    if (fromUserId == toUserId) {
      AppLogger.friend.w('sendRequest:selfTarget',
          fields: {'userId': fromUserId});
      return null;
    }

    try {
      // Dedup ONLY against pending rows — accepted ones mean "you're already
      // friends" (so the three-state button shows Friends and this code path
      // shouldn't be reached); rejected ones should be re-sendable.
      final forward = await _supabase
          .from('friend_relationships')
          .select('id')
          .eq('from_user_id', fromUserId)
          .eq('to_user_id', toUserId)
          .eq('status', 'pending')
          .maybeSingle();
      if (forward != null) {
        AppLogger.friend.i('sendRequest:dedupForward',
            fields: {'relationshipId': forward['id']});
        return forward['id'] as String;
      }

      final reverse = await _supabase
          .from('friend_relationships')
          .select('id')
          .eq('from_user_id', toUserId)
          .eq('to_user_id', fromUserId)
          .eq('status', 'pending')
          .maybeSingle();
      if (reverse != null) {
        AppLogger.friend.i('sendRequest:dedupReverse',
            fields: {'relationshipId': reverse['id']});
        return reverse['id'] as String;
      }

      final inserted = await _supabase
          .from('friend_relationships')
          .insert({
            'from_user_id': fromUserId,
            'to_user_id': toUserId,
            'status': 'pending',
          })
          .select('id')
          .single();
      final relId = inserted['id'] as String;

      AppLogger.friend.i('sendRequest:relationshipCreated', fields: {
        'relationshipId': relId,
        'from': fromUserId,
        'to': toUserId,
      });

      // In-app notification for the recipient.
      await _supabase.from('notifications').insert({
        'user_id': toUserId,
        'type': 'friend_request',
        'title': 'New Friend Request',
        'body': '$fromDisplayName wants to be your friend',
        'data': {
          'relationship_id': relId,
          'from_user_id': fromUserId,
        },
      });

      AppLogger.friend
          .i('sendRequest:done', fields: {'relationshipId': relId});
      return relId;
    } catch (e, s) {
      AppLogger.friend.e('sendRequest:failed',
          fields: {'from': fromUserId, 'to': toUserId},
          error: e,
          stack: s);
      rethrow;
    }
  }

  /// Accept a friend request — flips status to 'accepted'. The accepted-rel
  /// stream picks it up on both sides; we no longer mirror to user.friends[].
  Future<void> acceptRequest(String relationshipId) async {
    AppLogger.friend.i('acceptRequest:start',
        fields: {'relationshipId': relationshipId});
    try {
      final rel = await _supabase
          .from('friend_relationships')
          .select()
          .eq('id', relationshipId)
          .maybeSingle();
      if (rel == null) {
        AppLogger.friend.w('acceptRequest:missing',
            fields: {'relationshipId': relationshipId});
        return;
      }
      if (rel['status'] != 'pending') {
        AppLogger.friend.t('acceptRequest:alreadyResolved', fields: {
          'relationshipId': relationshipId,
          'status': rel['status'],
        });
        return;
      }

      await _supabase
          .from('friend_relationships')
          .update({'status': 'accepted'}).eq('id', relationshipId);

      // Notify the sender. We can read the accepter's display name from
      // profiles — `allow read: authenticated` lets us see any profile row.
      final accepterId = rel['to_user_id'] as String;
      final senderId = rel['from_user_id'] as String;
      final accepter = await _supabase
          .from('profiles_public')
          .select('display_name')
          .eq('id', accepterId)
          .maybeSingle();
      final accepterName =
          (accepter?['display_name'] as String?)?.trim().isNotEmpty == true
              ? accepter!['display_name'] as String
              : 'Someone';
      await _supabase.from('notifications').insert({
        'user_id': senderId,
        'type': 'friend_accepted',
        'title': 'Friend Request Accepted',
        'body': '$accepterName is now your friend',
        'data': {
          'friend_user_id': accepterId,
          'from_user_id': accepterId,
        },
      });

      AppLogger.friend.i('acceptRequest:done',
          fields: {'relationshipId': relationshipId});
    } catch (e, s) {
      AppLogger.friend.e('acceptRequest:failed',
          fields: {'relationshipId': relationshipId}, error: e, stack: s);
      rethrow;
    }
  }

  Future<void> rejectRequest(String relationshipId) async {
    AppLogger.friend
        .i('rejectRequest', fields: {'relationshipId': relationshipId});
    await _supabase
        .from('friend_relationships')
        .update({'status': 'rejected'}).eq('id', relationshipId);
  }

  /// Cancel an outgoing pending request — delete the row entirely.
  /// RLS lets either party delete.
  Future<void> cancelRequest(String relationshipId) async {
    AppLogger.friend
        .i('cancelRequest', fields: {'relationshipId': relationshipId});
    await _supabase
        .from('friend_relationships')
        .delete()
        .eq('id', relationshipId);
  }

  /// Unfriend by deleting both possible direction rows. Either party can
  /// delete (see friend_relationships RLS in 0001_init.sql).
  Future<void> removeFriend({
    required String userId,
    required String friendId,
  }) async {
    AppLogger.friend.i('removeFriend:start',
        fields: {'userId': userId, 'friendId': friendId});
    try {
      // PostgREST doesn't have native OR-of-row-conditions for deletes, so
      // we issue two filtered deletes — one per direction. Each is a no-op
      // if the row doesn't exist.
      await _supabase
          .from('friend_relationships')
          .delete()
          .eq('from_user_id', userId)
          .eq('to_user_id', friendId);
      await _supabase
          .from('friend_relationships')
          .delete()
          .eq('from_user_id', friendId)
          .eq('to_user_id', userId);

      AppLogger.friend.i('removeFriend:done',
          fields: {'userId': userId, 'friendId': friendId});
    } catch (e, s) {
      AppLogger.friend.e('removeFriend:failed',
          fields: {'userId': userId, 'friendId': friendId},
          error: e,
          stack: s);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------------

  /// Batch-fetch profiles by id. PostgREST's `in` filter accepts up to ~100
  /// values comfortably; for an MVP friends list (<1k friends) we issue one
  /// query.
  Future<List<UserModel>> getFriends(List<String> friendIds) async {
    if (friendIds.isEmpty) return [];
    final rows = await _supabase
        .from('profiles_public')
        .select()
        .inFilter('id', friendIds);
    return (rows as List)
        .map((r) => UserModel.fromSupabaseRow(r as Map<String, dynamic>))
        .toList();
  }

  Stream<List<FriendRelationship>> watchIncomingRequests(String userId) {
    return _supabase
        .from('friend_relationships')
        .stream(primaryKey: ['id'])
        .eq('to_user_id', userId)
        .map((rows) => rows
            .where((r) => r['status'] == 'pending')
            .map((r) => FriendRelationship.fromSupabaseRow(r))
            .toList());
  }

  Stream<List<FriendRelationship>> watchOutgoingRequests(String userId) {
    return _supabase
        .from('friend_relationships')
        .stream(primaryKey: ['id'])
        .eq('from_user_id', userId)
        .map((rows) => rows
            .where((r) => r['status'] == 'pending')
            .map((r) => FriendRelationship.fromSupabaseRow(r))
            .toList());
  }
}
