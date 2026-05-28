import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/leaderboard_entry_model.dart';
import '../services/leaderboard_service.dart';
import 'auth_provider.dart';
import 'friend_provider.dart';

final leaderboardServiceProvider =
    Provider<LeaderboardService>((ref) => LeaderboardService());

/// Global leaderboard (first page).
final globalLeaderboardProvider =
    FutureProvider<List<LeaderboardEntry>>((ref) {
  return ref.read(leaderboardServiceProvider).getGlobalRanks();
});

/// Friends leaderboard. Sources friend IDs from `acceptedFriendIdsProvider`
/// (derived from friend_relationships) since users.friends[] is no longer
/// mirrored cross-user.
final friendsLeaderboardProvider =
    FutureProvider<List<LeaderboardEntry>>((ref) async {
  final user = ref.watch(currentUserProvider).valueOrNull;
  final friendIds = ref.watch(acceptedFriendIdsProvider);
  if (user == null || friendIds.isEmpty) return [];
  return ref
      .read(leaderboardServiceProvider)
      .getFriendsRanks(friendIds: [...friendIds, user.userId]);
});

/// District-scoped leaderboard. Returns empty when home isn't set.
final districtLeaderboardProvider =
    FutureProvider<List<LeaderboardEntry>>((ref) async {
  final user = ref.watch(currentUserProvider).valueOrNull;
  if (user == null) return [];
  final district = user.districtName;
  if (district == null || district.isEmpty) return [];
  return ref
      .read(leaderboardServiceProvider)
      .getDistrictRanks(districtName: district);
});

/// State-scoped leaderboard. Returns empty when home isn't set.
final stateLeaderboardProvider =
    FutureProvider<List<LeaderboardEntry>>((ref) async {
  final user = ref.watch(currentUserProvider).valueOrNull;
  if (user == null) return [];
  final state = user.stateName;
  if (state == null || state.isEmpty) return [];
  return ref
      .read(leaderboardServiceProvider)
      .getStateRanks(stateName: state);
});

/// Country-scoped leaderboard. Returns empty when home isn't set.
final countryLeaderboardProvider =
    FutureProvider<List<LeaderboardEntry>>((ref) async {
  final user = ref.watch(currentUserProvider).valueOrNull;
  if (user == null) return [];
  final country = user.countryCode;
  if (country == null || country.isEmpty) return [];
  return ref
      .read(leaderboardServiceProvider)
      .getCountryRanks(countryCode: country);
});

/// Current user's own rank.
final myRankProvider = FutureProvider<LeaderboardEntry?>((ref) {
  final uid = ref.watch(authStateProvider).valueOrNull?.id;
  if (uid == null) return Future.value(null);
  return ref.read(leaderboardServiceProvider).getMyRank(uid);
});
