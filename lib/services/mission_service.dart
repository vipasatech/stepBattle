import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/mission_model.dart';
import '../models/user_mission_progress_model.dart';
import '../utils/app_logger.dart';
import 'supabase_api_client.dart';

/// Reads/writes mission progress on Supabase.
///
///   • `missions` table is read-only (admin-seeded — see the INSERTs in
///     0001_init.sql for the six default missions).
///   • `user_mission_progress` is owner-only (RLS enforces user_id ==
///     auth.uid()) and uses (user_id, mission_id, period_start) as its
///     composite primary key.
class MissionService {
  final SupabaseClient _supabase;

  MissionService({SupabaseClient? supabase})
      : _supabase = supabase ?? Supabase.instance.client;

  // ---------------------------------------------------------------------------
  // Mission catalog
  // ---------------------------------------------------------------------------

  Future<List<MissionModel>> getDailyMissions() async {
    try {
      final rows =
          await _supabase.from('missions').select().eq('type', 'daily');
      if (rows.isEmpty) {
        AppLogger.mission.w('getDailyMissions:emptyCatalog');
        return MissionModel.defaultDaily;
      }
      final result = rows
          .map<MissionModel>((r) => MissionModel.fromSupabaseRow(r))
          .toList();
      AppLogger.mission.i('getDailyMissions:supabase', fields: {
        'count': result.length,
        'ids': result.map((m) => m.missionId).toList(),
      });
      return result;
    } catch (e, s) {
      AppLogger.mission.e('getDailyMissions:failed', error: e, stack: s);
      // Fall back to defaults so the UI doesn't show an empty Missions tab
      // if the catalog read fails transiently.
      return MissionModel.defaultDaily;
    }
  }

  Future<List<MissionModel>> getWeeklyMissions() async {
    try {
      final rows =
          await _supabase.from('missions').select().eq('type', 'weekly');
      if (rows.isEmpty) {
        AppLogger.mission.w('getWeeklyMissions:emptyCatalog');
        return MissionModel.defaultWeekly;
      }
      final result = rows
          .map<MissionModel>((r) => MissionModel.fromSupabaseRow(r))
          .toList();
      AppLogger.mission.i('getWeeklyMissions:supabase', fields: {
        'count': result.length,
        'ids': result.map((m) => m.missionId).toList(),
      });
      return result;
    } catch (e, s) {
      AppLogger.mission.e('getWeeklyMissions:failed', error: e, stack: s);
      return MissionModel.defaultWeekly;
    }
  }

  // ---------------------------------------------------------------------------
  // Progress
  // ---------------------------------------------------------------------------

  String _todayPeriod() => DateFormat('yyyy-MM-dd').format(DateTime.now());

  String _weekPeriod() {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    return DateFormat('yyyy-MM-dd').format(monday);
  }

  /// Stream all progress rows for a user + period.
  Stream<List<UserMissionProgress>> watchProgress({
    required String userId,
    required String periodStart,
  }) {
    return _supabase
        .from('user_mission_progress')
        .stream(primaryKey: ['user_id', 'mission_id', 'period_start'])
        .eq('user_id', userId)
        .map((rows) => rows
            .where((r) => r['period_start'] == periodStart)
            .map((r) => UserMissionProgress.fromSupabaseRow(r))
            .toList());
  }

  Stream<List<UserMissionProgress>> watchDailyProgress(String userId) {
    return watchProgress(userId: userId, periodStart: _todayPeriod());
  }

  Stream<List<UserMissionProgress>> watchWeeklyProgress(String userId) {
    return watchProgress(userId: userId, periodStart: _weekPeriod());
  }

  /// Read (or create-empty) a single progress row.
  Future<UserMissionProgress> getOrCreateProgress({
    required String userId,
    required MissionModel mission,
  }) async {
    final period = mission.type == MissionType.daily
        ? _todayPeriod()
        : _weekPeriod();
    final row = await SupabaseApiClient.instance.run<Map<String, dynamic>?>(
      () => _supabase
          .from('user_mission_progress')
          .select()
          .eq('user_id', userId)
          .eq('mission_id', mission.missionId)
          .eq('period_start', period)
          .maybeSingle(),
      category: LogCategory.mission,
      name: 'missions.getProgress',
      fields: {'uid': userId, 'mission': mission.missionId},
    );

    if (row != null) return UserMissionProgress.fromSupabaseRow(row);

    final empty = UserMissionProgress.empty(
      userId: userId,
      missionId: mission.missionId,
      targetValue: mission.targetValue,
      periodStart: period,
    );
    // Composite-PK upsert is idempotent, but the tail retry is off so a
    // network flap can't double-log a fresh progress row.
    await SupabaseApiClient.instance.run<void>(
      () async {
        await _supabase
            .from('user_mission_progress')
            .upsert(empty.toSupabaseRow(),
                onConflict: 'user_id,mission_id,period_start');
      },
      category: LogCategory.mission,
      name: 'missions.createEmptyProgress',
      fields: {'uid': userId, 'mission': mission.missionId},
      retry: false,
    );
    return empty;
  }

  /// Update progress value. Caller passes the same composite-key fields
  /// so we can target the right row.
  ///
  /// `retry: false` — this is a straight UPDATE keyed by absolute value,
  /// not an increment, so a duplicate would produce the same row state.
  /// But we still bypass retries so the timing/latency log line
  /// truthfully reports "1 attempt, X ms" without stacking backoff for
  /// a fire-and-forget path called on every step-sync tick.
  Future<void> updateProgress({
    required String userId,
    required String missionId,
    required String periodStart,
    required int newValue,
    required int targetValue,
  }) async {
    final isComplete = newValue >= targetValue;
    await SupabaseApiClient.instance.run<void>(
      () async {
        await _supabase
            .from('user_mission_progress')
            .update({
              'current_value': newValue,
              'is_completed': isComplete,
              if (isComplete)
                'completed_at': DateTime.now().toUtc().toIso8601String(),
            })
            .eq('user_id', userId)
            .eq('mission_id', missionId)
            .eq('period_start', periodStart);
      },
      category: LogCategory.mission,
      name: 'missions.updateProgress',
      fields: {
        'uid': userId,
        'mission': missionId,
        'value': newValue,
        'completed': isComplete,
      },
      retry: false,
    );
  }

  /// Count of daily missions completed today (badge on the home card).
  ///
  /// Routed through [SupabaseApiClient] so a flaky network doesn't
  /// leave the badge stuck on 0 — one transient failure retries with
  /// backoff before falling through to the caller.
  Future<int> completedDailyCount(String userId) async {
    return SupabaseApiClient.instance.run<int>(
      () async {
        final rows = await _supabase
            .from('user_mission_progress')
            .select('mission_id')
            .eq('user_id', userId)
            .eq('period_start', _todayPeriod())
            .eq('is_completed', true);
        return (rows as List).length;
      },
      category: LogCategory.mission,
      name: 'missions.completedDailyCount',
      fields: {'uid': userId},
    );
  }

  /// Real-time streak + XP advance the moment today's step goal is
  /// crossed. Wraps the `advance_daily_progress` SECURITY DEFINER RPC
  /// (migration 0045).
  ///
  /// Atomically:
  ///   • Bumps `current_streak` (+1), clearing recovery if today is
  ///     day 1 or 2 of the 2-day recovery window.
  ///   • Credits +100 `daily_mission` XP (once per user's local day).
  ///   • Credits +100 `streak_milestone` XP if the new streak crosses
  ///     a 25-multiple.
  ///   • Stamps `streak_awarded_for_date` + `daily_goal_xp_awarded_date`
  ///     so the nightly cron backstop skips this user for the day.
  ///
  /// [localDate] is the user's local calendar date as YYYY-MM-DD.
  /// [currentSteps] is defense-in-depth — the RPC re-checks against
  /// `daily_step_goal` server-side.
  ///
  /// Returns a [DailyProgressResult] describing what happened so the
  /// UI can animate. Returns null (silent) on any error — we never
  /// want streak wiring to crash the home tab.
  Future<DailyProgressResult?> advanceDailyProgress({
    required String userId,
    required String localDate,
    required int currentSteps,
  }) async {
    try {
      final result = await _supabase.rpc(
        'advance_daily_progress',
        params: {
          'p_user_id': userId,
          'p_local_date': localDate,
          'p_current_steps': currentSteps,
        },
      );
      if (result is! Map) return null;
      final map = result.cast<String, dynamic>();
      return DailyProgressResult(
        credited: map['credited'] == true,
        streakBefore: (map['streak_before'] as num?)?.toInt() ?? 0,
        streak: (map['streak'] as num?)?.toInt() ?? 0,
        xpCredited: (map['xp_credited'] as num?)?.toInt() ?? 0,
        recovered: map['recovered'] == true,
        milestone: map['milestone'] == true,
      );
    } catch (e, s) {
      AppLogger.mission.e('advanceDailyProgress:failed',
          fields: {'uid': userId, 'date': localDate}, error: e, stack: s);
      return null;
    }
  }

  /// Pushes the caller's local timezone offset (minutes east of UTC)
  /// so the cron backstop knows how to compute their local "yesterday"
  /// when they haven't opened the app. Called once per session at
  /// login.
  ///
  /// Returns `true` on success, `false` on failure. Caller
  /// (`tzOffsetSyncProvider`) uses the return value to decide whether
  /// to cache the (uid, offset) pair — a false lets the next provider
  /// tick retry instead of caching a failed push forever.
  ///
  /// Boot-time race handling: on cold-start with a resumed session, the
  /// PostgREST client's JWT header may not have hydrated by the time
  /// `authStateProvider` emits its `initialSession` event. The RPC then
  /// reaches the server as anon → `auth.uid()` = NULL → migration 0045's
  /// `raise exception 'not_authorized'` (P0001). We catch that specific
  /// case and retry once after 400ms; by then the JWT is on the wire
  /// and the second attempt normally lands cleanly.
  Future<bool> updateTzOffset({
    required String userId,
    required int offsetMinutes,
  }) async {
    // Inner attempt — returns null to signal "retry-worthy boot race,"
    // true on success, false on real (non-retry-worthy) failure.
    Future<bool?> attempt(bool isFirst) async {
      try {
        await _supabase.rpc('update_tz_offset', params: {
          'p_user_id': userId,
          'p_offset_minutes': offsetMinutes,
        });
        return true;
      } catch (e, s) {
        final msg = e.toString().toLowerCase();
        final isBootRace =
            msg.contains('not_authorized') || msg.contains('p0001');
        if (isBootRace && isFirst) return null; // caller will retry once
        AppLogger.mission.e('updateTzOffset:failed',
            fields: {'uid': userId, 'offset': offsetMinutes},
            error: e,
            stack: s);
        return false;
      }
    }

    final first = await attempt(true);
    if (first != null) return first;
    // Boot-time race: PostgREST reached the server as anon because the
    // JWT hadn't hydrated by the time `authStateProvider` emitted its
    // initialSession event. Give it 400ms and try once more; the JWT is
    // normally on the wire by then and the RPC lands cleanly.
    AppLogger.mission.d('updateTzOffset:retryAfterAuthRace',
        fields: {'uid': userId});
    await Future.delayed(const Duration(milliseconds: 400));
    final second = await attempt(false);
    return second ?? false;
  }
}

/// Return payload from [MissionService.advanceDailyProgress]. Used to
/// drive the streak-tick animation / celebration bus on the home tab.
class DailyProgressResult {
  final bool credited;
  final int streakBefore;
  final int streak;
  final int xpCredited;
  final bool recovered;
  final bool milestone;

  const DailyProgressResult({
    required this.credited,
    required this.streakBefore,
    required this.streak,
    required this.xpCredited,
    required this.recovered,
    required this.milestone,
  });
}
