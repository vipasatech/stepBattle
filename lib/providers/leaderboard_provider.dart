import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/leaderboard_entry_model.dart';
import '../services/leaderboard_service.dart';
import 'auth_provider.dart';

final leaderboardServiceProvider =
    Provider<LeaderboardService>((ref) => LeaderboardService());

/// Global leaderboard (first page).
final globalLeaderboardProvider =
    FutureProvider<List<LeaderboardEntry>>((ref) {
  return ref.read(leaderboardServiceProvider).getGlobalRanks();
});

/// Friends leaderboard.
final friendsLeaderboardProvider =
    FutureProvider<List<LeaderboardEntry>>((ref) async {
  final user = ref.watch(currentUserProvider).valueOrNull;
  if (user == null || user.friends.isEmpty) return [];
  return ref
      .read(leaderboardServiceProvider)
      .getFriendsRanks(friendIds: [...user.friends, user.userId]);
});

/// Current user's own rank.
final myRankProvider = FutureProvider<LeaderboardEntry?>((ref) {
  final uid = ref.watch(authStateProvider).valueOrNull?.uid;
  if (uid == null) return Future.value(null);
  return ref.read(leaderboardServiceProvider).getMyRank(uid);
});
