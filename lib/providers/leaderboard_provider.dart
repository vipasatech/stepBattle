import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/leaderboard_entry_model.dart';
import '../repositories/leaderboard_repository.dart';
import '../services/leaderboard_service.dart';
import 'auth_provider.dart';
import 'friend_provider.dart';

/// Underlying service (used by [LeaderboardRepository] and any legacy
/// call site that needs a one-shot fetch outside the cache layer).
final leaderboardServiceProvider =
    Provider<LeaderboardService>((ref) => LeaderboardService());

/// Cache-then-poll leaderboard repository — emits the last-known list
/// on frame 1, then refreshes every 60 s while listened. Sign-out
/// invalidation lives in [supabase_auth_service.signOut].
final leaderboardRepositoryProvider =
    Provider<LeaderboardRepository>((ref) => LeaderboardRepository());

// Every leaderboard provider is `.autoDispose` — the underlying stream
// spins a 60 s Timer.periodic while listened. Without autoDispose, all
// six timers stay alive for the process lifetime after first listen,
// polling Supabase forever even when the Leaderboard tab isn't visible.

/// Global leaderboard (first page).
final globalLeaderboardProvider =
    StreamProvider.autoDispose<List<LeaderboardEntry>>((ref) {
  return ref.read(leaderboardRepositoryProvider).watchGlobal();
});

/// Friends leaderboard. Sources friend IDs from
/// `acceptedFriendIdsProvider` and prepends the current user so the
/// group ranking includes them.
final friendsLeaderboardProvider =
    StreamProvider.autoDispose<List<LeaderboardEntry>>((ref) {
  final user = ref.watch(currentUserProvider).valueOrNull;
  final friendIds = ref.watch(acceptedFriendIdsProvider);
  if (user == null || friendIds.isEmpty) {
    return Stream.value(const <LeaderboardEntry>[]);
  }
  return ref.read(leaderboardRepositoryProvider).watchFriends(
        uid: user.userId,
        friendIds: friendIds.toList(),
      );
});

/// District-scoped leaderboard. Returns empty when home isn't set.
final districtLeaderboardProvider =
    StreamProvider.autoDispose<List<LeaderboardEntry>>((ref) {
  final user = ref.watch(currentUserProvider).valueOrNull;
  final district = user?.districtName;
  if (district == null || district.isEmpty) {
    return Stream.value(const <LeaderboardEntry>[]);
  }
  return ref
      .read(leaderboardRepositoryProvider)
      .watchDistrict(districtName: district);
});

/// State-scoped leaderboard. Returns empty when home isn't set.
final stateLeaderboardProvider =
    StreamProvider.autoDispose<List<LeaderboardEntry>>((ref) {
  final user = ref.watch(currentUserProvider).valueOrNull;
  final state = user?.stateName;
  if (state == null || state.isEmpty) {
    return Stream.value(const <LeaderboardEntry>[]);
  }
  return ref
      .read(leaderboardRepositoryProvider)
      .watchState(stateName: state);
});

/// Country-scoped leaderboard. Returns empty when home isn't set.
final countryLeaderboardProvider =
    StreamProvider.autoDispose<List<LeaderboardEntry>>((ref) {
  final user = ref.watch(currentUserProvider).valueOrNull;
  final country = user?.countryCode;
  if (country == null || country.isEmpty) {
    return Stream.value(const <LeaderboardEntry>[]);
  }
  return ref
      .read(leaderboardRepositoryProvider)
      .watchCountry(countryCode: country);
});

/// Current user's own rank card. Cache-then-poll like the boards above,
/// so the Home screen's rank pill paints instantly on cold boot.
///
/// `.autoDispose` — Home always watches this, so it effectively lives
/// for the length of a signed-in session; on sign-out the last listener
/// drops and the poll timer tears down cleanly.
final myRankProvider = StreamProvider.autoDispose<LeaderboardEntry?>((ref) {
  final uid = ref.watch(authStateProvider).valueOrNull?.id;
  if (uid == null) return Stream.value(null);
  return ref.read(leaderboardRepositoryProvider).watchMyRank(uid);
});

/// The five leaderboard scopes the user can filter by on the
/// Leaderboards screen. Kept in the provider file so both the screen
/// and the rank-pill provider stay in sync on naming/order.
enum LeaderboardScope { worldwide, friends, district, state, country }

/// Scoped rank — the current user's rank within the currently-selected
/// filter tab on the Leaderboards screen. Powers the floating "You are
/// #N" pill, which prior to 1.1.6+27 always showed the WORLDWIDE rank
/// regardless of which tab was active. (Reported 2026-08-17: user
/// switched tabs, list re-rendered, pill number stayed frozen.)
///
/// Implementation: worldwide delegates to [myRankProvider] (server-
/// side count query — the global list is paginated so a list scan
/// wouldn't work). For the other four scopes we scan the already-
/// loaded scoped leaderboard list:
///   • friends → [friendsLeaderboardProvider] (always includes the
///     current user, per that provider's docstring)
///   • district/state/country → the corresponding list provider.
///     Returns null (pill hides) if the user isn't in the top-N of
///     that scope — bounded at 50 for district, 100 for state and
///     country. If a top-N-not-you edge case becomes visible we'll
///     add server-side scoped-count queries; not needed today because
///     the tester population is small enough to always be in the band.
final myScopedRankProvider =
    Provider.autoDispose.family<LeaderboardEntry?, LeaderboardScope>(
  (ref, scope) {
    final uid = ref.watch(authStateProvider).valueOrNull?.id;
    if (uid == null) return null;
    switch (scope) {
      case LeaderboardScope.worldwide:
        return ref.watch(myRankProvider).valueOrNull;
      case LeaderboardScope.friends:
        return _findInList(
            ref.watch(friendsLeaderboardProvider).valueOrNull, uid);
      case LeaderboardScope.district:
        return _findInList(
            ref.watch(districtLeaderboardProvider).valueOrNull, uid);
      case LeaderboardScope.state:
        return _findInList(
            ref.watch(stateLeaderboardProvider).valueOrNull, uid);
      case LeaderboardScope.country:
        return _findInList(
            ref.watch(countryLeaderboardProvider).valueOrNull, uid);
    }
  },
);

LeaderboardEntry? _findInList(List<LeaderboardEntry>? list, String uid) {
  if (list == null) return null;
  for (final e in list) {
    if (e.userId == uid) return e;
  }
  return null;
}
