import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/mission_model.dart';
import '../models/user_mission_progress_model.dart';
import '../utils/app_logger.dart';

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
    final row = await _supabase
        .from('user_mission_progress')
        .select()
        .eq('user_id', userId)
        .eq('mission_id', mission.missionId)
        .eq('period_start', period)
        .maybeSingle();

    if (row != null) return UserMissionProgress.fromSupabaseRow(row);

    final empty = UserMissionProgress.empty(
      userId: userId,
      missionId: mission.missionId,
      targetValue: mission.targetValue,
      periodStart: period,
    );
    await _supabase
        .from('user_mission_progress')
        .upsert(empty.toSupabaseRow(),
            onConflict: 'user_id,mission_id,period_start');
    return empty;
  }

  /// Update progress value. Caller passes the same composite-key fields
  /// so we can target the right row.
  Future<void> updateProgress({
    required String userId,
    required String missionId,
    required String periodStart,
    required int newValue,
    required int targetValue,
  }) async {
    final isComplete = newValue >= targetValue;
    await _supabase
        .from('user_mission_progress')
        .update({
          'current_value': newValue,
          'is_completed': isComplete,
          if (isComplete) 'completed_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('user_id', userId)
        .eq('mission_id', missionId)
        .eq('period_start', periodStart);
  }

  /// Count of daily missions completed today (badge on the home card).
  Future<int> completedDailyCount(String userId) async {
    final rows = await _supabase
        .from('user_mission_progress')
        .select('mission_id')
        .eq('user_id', userId)
        .eq('period_start', _todayPeriod())
        .eq('is_completed', true);
    return (rows as List).length;
  }
}
