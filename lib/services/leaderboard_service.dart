import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/constants.dart';
import '../models/leaderboard_entry_model.dart';
import '../utils/app_logger.dart';

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
      final rows = await _supabase
          .from('profile_earned_xp')
          .select()
          .order('earned_xp', ascending: false)
          .range(offset, offset + limit - 1);
      AppLogger.leaderboard.d('getGlobalRanks',
          fields: {'count': rows.length, 'limit': limit, 'offset': offset});
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
      ..sort((a, b) => b.totalXP.compareTo(a.totalXP));

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
    // Two-step computation against the earned_xp view:
    //   1. Read the user's row from `profile_earned_xp` → grab
    //      `earned_xp`.
    //   2. Count how many rows in the view have strictly higher
    //      `earned_xp` → that count + 1 = the user's global rank.
    // Ranks must match the ranking metric used in the boards, so both
    // steps read the view (never the raw profiles table).
    try {
      final profile = await _supabase
          .from('profile_earned_xp')
          .select()
          .eq('id', userId)
          .maybeSingle();
      if (profile == null) return null;

      final myXp = (profile['earned_xp'] as num?)?.toInt() ?? 0;
      // Strict greater-than so ties resolve favourably — you share
      // rank with anyone tied at your earned XP.
      final higher = await _supabase
          .from('profile_earned_xp')
          .select('id')
          .gt('earned_xp', myXp);
      final rank = (higher as List).length + 1;

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
      final rows = await _supabase
          .from('profile_earned_xp')
          .select()
          .eq('district_name', districtName)
          .order('earned_xp', ascending: false)
          .limit(limit);
      AppLogger.leaderboard.d('getDistrictRanks',
          fields: {'districtName': districtName, 'count': rows.length});
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
      final rows = await _supabase
          .from('profile_earned_xp')
          .select()
          .eq('state_name', stateName)
          .order('earned_xp', ascending: false)
          .limit(limit);
      AppLogger.leaderboard.d('getStateRanks',
          fields: {'stateName': stateName, 'count': rows.length});
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
      final rows = await _supabase
          .from('profile_earned_xp')
          .select()
          .eq('country_code', countryCode.toUpperCase())
          .order('earned_xp', ascending: false)
          .limit(limit);
      AppLogger.leaderboard.d('getCountryRanks',
          fields: {'countryCode': countryCode, 'count': rows.length});
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
