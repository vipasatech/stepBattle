import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/constants.dart';
import '../models/leaderboard_entry_model.dart';
import '../utils/app_logger.dart';
import 'supabase_api_client.dart';

/// Leaderboard reads on Supabase.
///
/// All ranking queries hit `public.profile_earned_xp` — a view over
/// `profiles` that exposes an `earned_xp` column
/// (`total_xp − Σ captured xp_credited from xp_purchases`). Sorting by
/// `earned_xp` means users can't climb the board by buying XP; the
/// visible XP number on each row is the earned value too, so the
/// ranking and the displayed count match.
///
/// Scopes:
///   • Global — the whole view, paginated.
///   • Friends — batched read by user id, ranked client-side.
///   • District / State / Country — filtered by the geo columns
///     inherited from `profiles`, ordered by `earned_xp`.
class LeaderboardService {
  final SupabaseClient _supabase;

  LeaderboardService({SupabaseClient? supabase})
      : _supabase = supabase ?? Supabase.instance.client;

  // ---------------------------------------------------------------------------
  // Global (precomputed)
  // ---------------------------------------------------------------------------

  /// Paginated read of `leaderboard_snapshots`. [startAfterRank] is the
  /// numeric rank of the last item from the previous page — using rank
  /// instead of opaque cursors keeps pagination simple.
  Future<List<LeaderboardEntry>> getGlobalRanks({
    int limit = AppConstants.leaderboardPageSize,
    int? startAfterRank,
  }) async {
    // Query the live profiles table directly, ordered by total_xp DESC.
    // The previous implementation read from a `leaderboard_snapshots`
    // table that was meant to be populated by a server-side cron — but
    // that cron was never wired, so the snapshot table is empty for
    // every user and the World tab perma-rendered "No one ranked here
    // yet". Profiles-direct mirrors how getCountryRanks /
    // getStateRanks / getDistrictRanks already work and matches the
    // user's data they can actually see.
    //
    // Pagination via startAfterRank: since rank is computed
    // client-side via row order, we use offset for pagination on
    // subsequent pages.
    try {
      final offset = startAfterRank ?? 0;
      final rows = await SupabaseApiClient.instance.run<List<dynamic>>(
        () async {
          final data = await _supabase
              .from('profile_earned_xp')
              .select()
              .order('earned_xp', ascending: false)
              // Deterministic tie-breaker on `id` — required so this
              // list's positional ranks agree with getMyRank's rank
              // formula (see comment in getMyRank). Without it, tied
              // users appear at planner-arbitrary positions and the
              // "You" pill's rank number highlights the wrong row.
              .order('id', ascending: true)
              .range(offset, offset + limit - 1);
          return data;
        },
        category: LogCategory.leaderboard,
        name: 'leaderboard.getGlobalRanks',
        fields: {'limit': limit, 'offset': offset},
      );
      // _entriesFromProfiles stamps 1-based ranks; for page 2+, shift
      // the base rank by the offset so positions stay correct across
      // pages.
      final entries = _entriesFromProfiles(rows);
      if (offset == 0) return entries;
      return [
        for (final e in entries)
          LeaderboardEntry(
            userId: e.userId,
            displayName: e.displayName,
            avatarURL: e.avatarURL,
            totalXP: e.totalXP,
            rank: e.rank + offset,
            updatedAt: e.updatedAt,
          ),
      ];
    } catch (e, s) {
      AppLogger.leaderboard.e('getGlobalRanks:failed', error: e, stack: s);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Friends — sorted client-side after a batch profile fetch.
  // ---------------------------------------------------------------------------

  Future<List<LeaderboardEntry>> getFriendsRanks({
    required List<String> friendIds,
  }) async {
    if (friendIds.isEmpty) return [];

    // PostgREST's `in` filter is fine for 1k+ items; no batching needed.
    // Query the earned-xp view so client-side sort matches the ranking
    // metric — `LeaderboardEntry.totalXP` picks up `earned_xp` from the
    // row (see model's fromSupabaseRow).
    final rows = await _supabase
        .from('profile_earned_xp')
        .select()
        .inFilter('id', friendIds);

    final entries = rows
        .map<LeaderboardEntry>(LeaderboardEntry.fromSupabaseRow)
        .toList()
      ..sort((a, b) {
        // Match the server-side ORDER BY used for the global/geo lists:
        // earned XP DESC, then userId ASC as a stable tie-breaker.
        final xpCmp = b.totalXP.compareTo(a.totalXP);
        if (xpCmp != 0) return xpCmp;
        return a.userId.compareTo(b.userId);
      });

    // Stamp positional ranks (1-based) so the UI shows 1/2/3 by position
    // within the friend group — independent of any global rank that might
    // be set on the profile row.
    return [
      for (var i = 0; i < entries.length; i++)
        LeaderboardEntry(
          userId: entries[i].userId,
          displayName: entries[i].displayName,
          avatarURL: entries[i].avatarURL,
          totalXP: entries[i].totalXP,
          rank: i + 1,
          updatedAt: entries[i].updatedAt,
        ),
    ];
  }

  // ---------------------------------------------------------------------------
  // My rank — try snapshots first, fall back to profile.
  // ---------------------------------------------------------------------------

  Future<LeaderboardEntry?> getMyRank(String userId) async {
    // Rank must match the *positional* rank in the boards' list view
    // (getGlobalRanks etc.), which orders by `earned_xp DESC, id ASC`
    // and stamps 1-based positions. So the rank formula here is:
    //
    //   rank = 1
    //        + count(users with STRICTLY higher earned_xp)
    //        + count(users TIED at earned_xp but with smaller id)
    //
    // Before this three-part formula, we used a shared-rank scheme
    // (count(>) + 1) which said "everyone tied at 0 XP is rank 17".
    // But the list's positional ranks were 17, 18, 19, … for those
    // same tied users, so the "You" pill highlighted the wrong row
    // (whichever id happened to sort first among the ties). The
    // fix: use the same tie-breaker the list uses, so pill rank
    // and list position always agree.
    try {
      final profile = await _supabase
          .from('profile_earned_xp')
          .select()
          .eq('id', userId)
          .maybeSingle();
      if (profile == null) return null;

      final myXp = (profile['earned_xp'] as num?)?.toInt() ?? 0;
      final higher = await _supabase
          .from('profile_earned_xp')
          .select('id')
          .gt('earned_xp', myXp);
      final tiedEarlier = await _supabase
          .from('profile_earned_xp')
          .select('id')
          .eq('earned_xp', myXp)
          .lt('id', userId);
      final rank =
          (higher as List).length + (tiedEarlier as List).length + 1;

      return LeaderboardEntry.fromSupabaseRow(
        profile,
        overrideRank: rank,
      );
    } catch (e, s) {
      AppLogger.leaderboard
          .e('getMyRank:failed', fields: {'uid': userId}, error: e, stack: s);
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Geo-scoped boards — query the earned_xp view filtered by the geo
  // column inherited from profiles, ordered by earned_xp. The view is
  // a plain SELECT over profiles, so the composite indexes declared in
  // 0001_init.sql on (country_code, total_xp) etc. still help the
  // planner even though we're now ordering by the computed column.
  // ---------------------------------------------------------------------------

  Future<List<LeaderboardEntry>> getDistrictRanks({
    required String districtName,
    int limit = 50,
  }) async {
    try {
      final rows = await SupabaseApiClient.instance.run<List<dynamic>>(
        () async {
          final data = await _supabase
              .from('profile_earned_xp')
              .select()
              .eq('district_name', districtName)
              .order('earned_xp', ascending: false)
              .order('id', ascending: true)  // stable tie-breaker (see getGlobalRanks)
              .limit(limit);
          return data;
        },
        category: LogCategory.leaderboard,
        name: 'leaderboard.getDistrictRanks',
        fields: {'districtName': districtName, 'limit': limit},
      );
      return _entriesFromProfiles(rows);
    } catch (e, s) {
      AppLogger.leaderboard.e('getDistrictRanks:failed',
          fields: {'districtName': districtName}, error: e, stack: s);
      rethrow;
    }
  }

  Future<List<LeaderboardEntry>> getStateRanks({
    required String stateName,
    int limit = 100,
  }) async {
    try {
      final rows = await SupabaseApiClient.instance.run<List<dynamic>>(
        () async {
          final data = await _supabase
              .from('profile_earned_xp')
              .select()
              .eq('state_name', stateName)
              .order('earned_xp', ascending: false)
              .order('id', ascending: true)  // stable tie-breaker (see getGlobalRanks)
              .limit(limit);
          return data;
        },
        category: LogCategory.leaderboard,
        name: 'leaderboard.getStateRanks',
        fields: {'stateName': stateName, 'limit': limit},
      );
      return _entriesFromProfiles(rows);
    } catch (e, s) {
      AppLogger.leaderboard.e('getStateRanks:failed',
          fields: {'stateName': stateName}, error: e, stack: s);
      rethrow;
    }
  }

  Future<List<LeaderboardEntry>> getCountryRanks({
    required String countryCode,
    int limit = 100,
  }) async {
    try {
      final rows = await SupabaseApiClient.instance.run<List<dynamic>>(
        () async {
          final data = await _supabase
              .from('profile_earned_xp')
              .select()
              .eq('country_code', countryCode.toUpperCase())
              .order('earned_xp', ascending: false)
              .order('id', ascending: true)  // stable tie-breaker (see getGlobalRanks)
              .limit(limit);
          return data;
        },
        category: LogCategory.leaderboard,
        name: 'leaderboard.getCountryRanks',
        fields: {'countryCode': countryCode, 'limit': limit},
      );
      return _entriesFromProfiles(rows);
    } catch (e, s) {
      AppLogger.leaderboard.e('getCountryRanks:failed',
          fields: {'countryCode': countryCode}, error: e, stack: s);
      rethrow;
    }
  }

  /// Stamps positional ranks (1-based) so the UI shows position-within-set,
  /// matching the Firestore version's behavior.
  List<LeaderboardEntry> _entriesFromProfiles(List<dynamic> rows) {
    var rank = 1;
    return [
      for (final r in rows)
        LeaderboardEntry.fromSupabaseRow(
          r as Map<String, dynamic>,
          overrideRank: rank++,
        ),
    ];
  }
}
