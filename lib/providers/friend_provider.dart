import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/friend_relationship_model.dart';
import '../models/user_model.dart';
import '../services/friend_service.dart';
import '../utils/app_logger.dart';
import 'auth_provider.dart';

final friendServiceProvider =
    Provider<FriendService>((ref) => FriendService());

/// Base stream: **every** friend_relationships row the current user
/// is party to — regardless of status. Accepted / pending-incoming /
/// pending-outgoing views are cheap client-side filters over this.
///
/// Postgres can't OR across two filtered fields in one realtime
/// stream, so we open two `from('friend_relationships').stream()`
/// subscriptions — one keyed on `from_user_id == me`, one on
/// `to_user_id == me` — and merge their latest snapshots
/// client-side. This provider fans out into the four legacy views
/// (accepted, incoming, outgoing, count) as plain Providers, so
/// we're at **two** realtime channels total instead of the four the
/// separate stream providers used to open.
final allFriendRelationshipsProvider =
    StreamProvider<List<FriendRelationship>>((ref) {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return Stream.value([]);
  final uid = user.id;

  final supa = Supabase.instance.client;
  final controller = StreamController<List<FriendRelationship>>();
  List<FriendRelationship> latestAsFrom = const [];
  List<FriendRelationship> latestAsTo = const [];

  List<FriendRelationship> parseAll(List<Map<String, dynamic>> rows) =>
      rows.map(FriendRelationship.fromSupabaseRow).toList();

  void emit() {
    final merged = <String, FriendRelationship>{
      for (final r in latestAsFrom) r.relationshipId: r,
      for (final r in latestAsTo) r.relationshipId: r,
    };
    AppLogger.friend.d('friendRels:emit',
        fields: {'count': merged.length, 'userId': uid});
    controller.add(merged.values.toList());
  }

  final subAsFrom = supa
      .from('friend_relationships')
      .stream(primaryKey: ['id'])
      .eq('from_user_id', uid)
      .listen(
        (rows) {
          latestAsFrom = parseAll(rows);
          emit();
        },
        onError: (Object e, StackTrace s) {
          AppLogger.friend.e('friendRels:asFrom:streamError',
              fields: {'userId': uid}, error: e, stack: s);
        },
      );

  final subAsTo = supa
      .from('friend_relationships')
      .stream(primaryKey: ['id'])
      .eq('to_user_id', uid)
      .listen(
        (rows) {
          latestAsTo = parseAll(rows);
          emit();
        },
        onError: (Object e, StackTrace s) {
          AppLogger.friend.e('friendRels:asTo:streamError',
              fields: {'userId': uid}, error: e, stack: s);
        },
      );

  ref.onDispose(() {
    subAsFrom.cancel();
    subAsTo.cancel();
    controller.close();
  });

  return controller.stream;
});

/// Accepted friend relationships (status == 'accepted'). Derived from
/// the shared [allFriendRelationshipsProvider] — no additional
/// realtime channel.
final acceptedFriendRelationshipsProvider =
    Provider<AsyncValue<List<FriendRelationship>>>((ref) {
  final base = ref.watch(allFriendRelationshipsProvider);
  return base.whenData(
    (rels) => rels.where((r) => r.status == FriendStatus.accepted).toList(),
  );
});

/// Set of user IDs that are accepted friends of the current user — derived
/// from [acceptedFriendRelationshipsProvider] by taking the "other side" of
/// each accepted rel.
final acceptedFriendIdsProvider = Provider<Set<String>>((ref) {
  final me = ref.watch(authStateProvider).valueOrNull;
  final rels =
      ref.watch(acceptedFriendRelationshipsProvider).valueOrNull ?? const [];
  if (me == null) return const <String>{};
  final myUid = me.id;
  return {
    for (final r in rels) r.fromUserId == myUid ? r.toUserId : r.fromUserId,
  };
});

/// Full friend profiles, resolved from the accepted-rel-derived id set.
final friendsListProvider = FutureProvider<List<UserModel>>((ref) {
  final ids = ref.watch(acceptedFriendIdsProvider);
  if (ids.isEmpty) return Future.value([]);
  return ref.read(friendServiceProvider).getFriends(ids.toList());
});

/// Smart search — handles both username and userCode (#).
///
/// `.autoDispose` — every keystroke creates a new provider instance
/// keyed by the query string. Without autoDispose, each abandoned
/// search result would be pinned in memory forever.
final friendSearchProvider =
    FutureProvider.autoDispose.family<List<UserModel>, String>((ref, query) {
  if (query.trim().isEmpty) return Future.value([]);
  return ref.read(friendServiceProvider).search(query);
});

/// Incoming pending friend requests (people who want to be your
/// friend). Derived from [allFriendRelationshipsProvider] — status
/// pending AND the current user is the recipient. No dedicated
/// realtime channel; the old `watchIncomingRequests` service call is
/// no longer wired in.
final incomingRequestsProvider =
    Provider<AsyncValue<List<FriendRelationship>>>((ref) {
  final uid = ref.watch(authStateProvider).valueOrNull?.id;
  final base = ref.watch(allFriendRelationshipsProvider);
  return base.whenData((rels) => uid == null
      ? const <FriendRelationship>[]
      : rels
          .where((r) => r.status == FriendStatus.pending && r.toUserId == uid)
          .toList());
});

/// Outgoing pending friend requests (people you've asked to be
/// friends with). Derived from [allFriendRelationshipsProvider] —
/// status pending AND the current user is the sender.
final outgoingRequestsProvider =
    Provider<AsyncValue<List<FriendRelationship>>>((ref) {
  final uid = ref.watch(authStateProvider).valueOrNull?.id;
  final base = ref.watch(allFriendRelationshipsProvider);
  return base.whenData((rels) => uid == null
      ? const <FriendRelationship>[]
      : rels
          .where((r) => r.status == FriendStatus.pending && r.fromUserId == uid)
          .toList());
});

/// Resolved user profiles for incoming requests (senders).
final incomingRequestProfilesProvider =
    FutureProvider<List<({FriendRelationship rel, UserModel user})>>(
        (ref) async {
  final requests = ref.watch(incomingRequestsProvider).valueOrNull ?? [];
  if (requests.isEmpty) return [];
  final userIds = requests.map((r) => r.fromUserId).toList();
  final users = await ref.read(friendServiceProvider).getFriends(userIds);
  final byId = {for (final u in users) u.userId: u};
  return requests
      .where((r) => byId.containsKey(r.fromUserId))
      .map((r) => (rel: r, user: byId[r.fromUserId]!))
      .toList();
});

/// Resolved user profiles for outgoing requests (recipients).
final outgoingRequestProfilesProvider =
    FutureProvider<List<({FriendRelationship rel, UserModel user})>>(
        (ref) async {
  final requests = ref.watch(outgoingRequestsProvider).valueOrNull ?? [];
  if (requests.isEmpty) return [];
  final userIds = requests.map((r) => r.toUserId).toList();
  final users = await ref.read(friendServiceProvider).getFriends(userIds);
  final byId = {for (final u in users) u.userId: u};
  return requests
      .where((r) => byId.containsKey(r.toUserId))
      .map((r) => (rel: r, user: byId[r.toUserId]!))
      .toList();
});

/// Incoming request count — for badge display.
final incomingRequestCountProvider = Provider<int>((ref) {
  return ref.watch(incomingRequestsProvider).valueOrNull?.length ?? 0;
});
