import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/friend_relationship_model.dart';
import '../models/user_model.dart';
import '../services/friend_service.dart';
import 'auth_provider.dart';

final friendServiceProvider =
    Provider<FriendService>((ref) => FriendService());

/// Full friend profiles (resolved from IDs in user.friends).
final friendsListProvider = FutureProvider<List<UserModel>>((ref) {
  final user = ref.watch(currentUserProvider).valueOrNull;
  if (user == null || user.friends.isEmpty) return Future.value([]);
  return ref.read(friendServiceProvider).getFriends(user.friends);
});

/// Smart search — handles both username and userCode (#).
final friendSearchProvider =
    FutureProvider.family<List<UserModel>, String>((ref, query) {
  if (query.trim().isEmpty) return Future.value([]);
  return ref.read(friendServiceProvider).search(query);
});

/// Incoming pending friend requests (people who want to be your friend).
final incomingRequestsProvider =
    StreamProvider<List<FriendRelationship>>((ref) {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return Stream.value([]);
  return ref.read(friendServiceProvider).watchIncomingRequests(user.uid);
});

/// Outgoing pending friend requests (people you've asked to be friends with).
final outgoingRequestsProvider =
    StreamProvider<List<FriendRelationship>>((ref) {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return Stream.value([]);
  return ref.read(friendServiceProvider).watchOutgoingRequests(user.uid);
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
