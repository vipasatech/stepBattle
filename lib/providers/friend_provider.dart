import 'package:flutter_riverpod/flutter_riverpod.dart';
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

/// Search results for adding friends.
final friendSearchProvider =
    FutureProvider.family<List<UserModel>, String>((ref, query) {
  if (query.trim().isEmpty) return Future.value([]);
  return ref.read(friendServiceProvider).searchByUsername(query);
});
