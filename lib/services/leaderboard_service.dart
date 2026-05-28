import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/constants.dart';
import '../models/leaderboard_entry_model.dart';
import '../utils/app_logger.dart';

/// Leaderboard reads on Supabase.
///
///   • Global ranks come from `leaderboard_snapshots` (read-only, populated
///     by a future cron / edge function — for now this returns empty until
///     we add that job).
///   • Friends + geo-scoped (district/state/country) boards query
///     `profiles` directly and rank by `total_xp` client-side.
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
    try {
      var query = _supabase.from('leaderboard_snapshots').select();
      if (startAfterRank != null) {
        query = query.gt('rank', startAfterRank);
      }
      final rows = await query.order('rank').limit(limit);
      AppLogger.leaderboard
          .d('getGlobalRanks', fields: {'count': rows.length, 'limit': limit});
      return rows
          .map<LeaderboardEntry>(LeaderboardEntry.fromSupabaseRow)
          .toList();
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
    final rows = await _supabase
        .from('profiles')
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
    final snap = await _supabase
        .from('leaderboard_snapshots')
        .select()
        .eq('user_id', userId)
        .maybeSingle();
    if (snap != null) return LeaderboardEntry.fromSupabaseRow(snap);

    final profile = await _supabase
        .from('profiles')
        .select()
        .eq('id', userId)
        .maybeSingle();
    if (profile == null) return null;
    return LeaderboardEntry.fromSupabaseRow(profile);
  }

  // ---------------------------------------------------------------------------
  // Geo-scoped boards — query `profiles` directly ordered by total_xp.
  // The composite indexes that made this fast on Firestore aren't needed
  // here: Postgres picks the right plan on its own given the indexes we
  // declared on (country_code, total_xp) / (state_name, total_xp) /
  // (district_name, total_xp) in 0001_init.sql.
  // ---------------------------------------------------------------------------

  Future<List<LeaderboardEntry>> getDistrictRanks({
    required String districtName,
    int limit = 50,
  }) async {
    try {
      final rows = await _supabase
          .from('profiles')
          .select()
          .eq('district_name', districtName)
          .order('total_xp', ascending: false)
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
          .from('profiles')
          .select()
          .eq('state_name', stateName)
          .order('total_xp', ascending: false)
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
          .from('profiles')
          .select()
          .eq('country_code', countryCode.toUpperCase())
          .order('total_xp', ascending: false)
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
