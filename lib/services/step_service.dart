import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/constants.dart';
import '../models/mission_model.dart';
import '../models/step_log_model.dart';
import '../utils/app_logger.dart';
import 'mission_service.dart';
import 'xp_service.dart';

/// Syncs step data between the local health store and Supabase.
///
/// Per-sync flow:
///   1. Upsert `step_logs` row for (user, today) and increment
///      `profiles.total_steps_all_time` by the delta vs. the previous value.
///   2. Award XP for crossed 1k-step thresholds + daily-goal bonus.
///   3. Propagate to mission progress, active battles, and clan member rows.
///
/// Phase-2 status:
///   • step_logs + profile counters: Supabase ✓
///   • XP awards: Supabase ✓ (via XPService — already migrated)
///   • Mission / battle / clan propagation: stubbed; remaining phases will
///     replace these.
class StepService {
  final SupabaseClient _supabase;
  final MissionService _missionService;
  final XPService _xpService;

  StepService({
    SupabaseClient? supabase,
    MissionService? missionService,
    XPService? xpService,
  })  : _supabase = supabase ?? Supabase.instance.client,
        _missionService = missionService ?? MissionService(),
        _xpService = xpService ?? XPService();

  /// Largest jump in a single sync we'll accept. World-record steppers
  /// peak around 200k/day; any single-call delta beyond this is the
  /// poisoned-baseline failure mode we hit on 2026-05-26.
  static const int _perSyncMaxDelta = 100000;

  // ---------------------------------------------------------------------------
  // MAIN SYNC
  // ---------------------------------------------------------------------------

  Future<void> syncSteps({
    required String userId,
    required int steps,
    required String source,
  }) async {
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final calories = (steps * AppConstants.caloriesPerStep).round();

    AppLogger.step.i('syncSteps:start', fields: {
      'userId': userId,
      'steps': steps,
      'source': source,
      'today': today,
    });

    try {
      await _writeStepLog(
        userId: userId,
        today: today,
        steps: steps,
        calories: calories,
        source: source,
      );

      await _awardStepXP(userId: userId, todaySteps: steps, today: today);

      // Phase 3 — mission progress.
      await _propagateToMissions(userId, steps);

      // Phase 4 — active battles (time-window steps via lifetime baseline).
      await _propagateToActiveBattles(userId);

      // Phase 6 — clan member's `steps_today` (the dashboard ranks members
      // by this).
      await _propagateToClan(userId, steps);

      AppLogger.step.i('syncSteps:done', fields: {'userId': userId});
    } catch (e, s) {
      AppLogger.step.e('syncSteps:failed',
          fields: {'userId': userId, 'steps': steps},
          error: e,
          stack: s);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // step_logs upsert + profile lifetime counter
  // ---------------------------------------------------------------------------

  Future<void> _writeStepLog({
    required String userId,
    required String today,
    required int steps,
    required int calories,
    required String source,
  }) async {
    // Read previous so we can compute the delta to apply to total_steps_all_time.
    final existing = await _supabase
        .from('step_logs')
        .select('step_count')
        .eq('user_id', userId)
        .eq('date', today)
        .maybeSingle();
    final previousSteps = (existing?['step_count'] as num?)?.toInt() ?? 0;
    final delta = steps - previousSteps;

    AppLogger.step.d('writeStepLog', fields: {
      'userId': userId,
      'date': today,
      'previousSteps': previousSteps,
      'newSteps': steps,
      'delta': delta,
    });

    // Sanity gate: a single sync should never move today's count by more
    // than `_perSyncMaxDelta`. A larger jump means the source was
    // corrupted (the 40k/80k bug we saw with a poisoned native baseline)
    // — skip the write entirely so the lifetime counter doesn't get
    // polluted. The aggregator will repair the source on the next pass.
    if (delta.abs() > _perSyncMaxDelta) {
      AppLogger.step.w('writeStepLog:absurdDelta', fields: {
        'userId': userId,
        'date': today,
        'previousSteps': previousSteps,
        'newSteps': steps,
        'delta': delta,
        'cap': _perSyncMaxDelta,
      });
      return;
    }

    try {
      await _supabase.from('step_logs').upsert(
        {
          'user_id': userId,
          'date': today,
          'step_count': steps,
          'calories': calories,
          'source': source,
          'synced_at': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'user_id,date',
      );

      if (delta > 0) {
        // Read-modify-write the lifetime counter. Postgres doesn't expose
        // FieldValue.increment-style atomic ops through PostgREST, so we
        // approximate by reading current then writing current+delta. Two
        // concurrent syncs could under-count; we accept that for MVP (steps
        // are monotonic and converge on the next sync).
        final profile = await _supabase
            .from('profiles')
            .select('total_steps_all_time')
            .eq('id', userId)
            .maybeSingle();
        final lifetime =
            (profile?['total_steps_all_time'] as num?)?.toInt() ?? 0;
        await _supabase.from('profiles').update({
          'total_steps_all_time': lifetime + delta,
          'last_active_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', userId);
      }
    } catch (e, s) {
      AppLogger.step.e('writeStepLog:failed',
          fields: {'userId': userId, 'date': today}, error: e, stack: s);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // XP drip + daily goal bonus
  // ---------------------------------------------------------------------------

  Future<void> _awardStepXP({
    required String userId,
    required int todaySteps,
    required String today,
  }) async {
    final profile = await _supabase
        .from('profiles')
        .select(
            'last_step_xp_date, last_step_xp_threshold, daily_step_goal, daily_goal_xp_awarded_date')
        .eq('id', userId)
        .maybeSingle();
    if (profile == null) return;

    final lastDate = profile['last_step_xp_date'] as String? ?? '';
    final lastThreshold = lastDate == today
        ? ((profile['last_step_xp_threshold'] as num?)?.toInt() ?? 0)
        : 0;
    final dailyGoal = (profile['daily_step_goal'] as num?)?.toInt() ?? 8000;
    final goalAwardedDate = profile['daily_goal_xp_awarded_date'] as String?;

    final currentThreshold = todaySteps ~/ 1000;
    int xpToAward = 0;

    if (currentThreshold > lastThreshold) {
      xpToAward += (currentThreshold - lastThreshold) *
          AppConstants.xpPer1000Steps;
    }

    final shouldAwardGoal =
        todaySteps >= dailyGoal && goalAwardedDate != today;
    if (shouldAwardGoal) {
      xpToAward += AppConstants.xpDailyGoalReached;
    }

    if (xpToAward == 0 && lastDate == today) return;

    final updates = <String, dynamic>{
      'last_step_xp_threshold': currentThreshold,
      'last_step_xp_date': today,
    };
    if (shouldAwardGoal) {
      updates['daily_goal_xp_awarded_date'] = today;
    }
    await _supabase.from('profiles').update(updates).eq('id', userId);

    if (xpToAward > 0) {
      await _xpService.awardXP(userId: userId, amount: xpToAward);
    }
  }

  // ---------------------------------------------------------------------------
  // Read helpers
  // ---------------------------------------------------------------------------

  /// Stream today's step log row. Emits null when the row doesn't exist
  /// yet (fresh day, no sync has run).
  Stream<StepLogModel?> watchTodaySteps(String userId) {
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    return _supabase
        .from('step_logs')
        .stream(primaryKey: ['id'])
        .eq('user_id', userId)
        .map((rows) {
          final match = rows.firstWhere(
            (r) => r['date'] == today,
            orElse: () => <String, dynamic>{},
          );
          if (match.isEmpty) return null;
          return StepLogModel.fromSupabaseRow(match);
        });
  }

  Future<List<StepLogModel>> getStepHistory({
    required String userId,
    required DateTime from,
    required DateTime to,
  }) async {
    final fmt = DateFormat('yyyy-MM-dd');
    final fromStr = fmt.format(from);
    final toStr = fmt.format(to);

    final rows = await _supabase
        .from('step_logs')
        .select()
        .eq('user_id', userId)
        .gte('date', fromStr)
        .lte('date', toStr)
        .order('date', ascending: false);

    return (rows as List)
        .map((r) =>
            StepLogModel.fromSupabaseRow(r as Map<String, dynamic>))
        .toList();
  }

  Future<int> getDailyTotal({
    required String userId,
    required DateTime date,
  }) async {
    final dateStr = DateFormat('yyyy-MM-dd').format(date);
    final row = await _supabase
        .from('step_logs')
        .select('step_count')
        .eq('user_id', userId)
        .eq('date', dateStr)
        .maybeSingle();
    return (row?['step_count'] as num?)?.toInt() ?? 0;
  }

  Future<int> getWeeklyTotal(String userId) async {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final start = DateTime(monday.year, monday.month, monday.day);

    final logs = await getStepHistory(userId: userId, from: start, to: now);
    return logs.fold<int>(0, (total, log) => total + log.stepCount);
  }

  // ---------------------------------------------------------------------------
  // Battle propagation (Phase 4)
  //
  // For every active battle this user participates in, update their row's
  // `current_steps = profiles.total_steps_all_time − start_steps_baseline`.
  // The baseline was captured when the battle activated (BattleService.
  // _activateBattle), so steps before activation are not counted and steps
  // continue accumulating across midnight without resetting.
  // ---------------------------------------------------------------------------

  Future<void> _propagateToActiveBattles(String userId) async {
    try {
      // Read this user's lifetime counter — single profile lookup.
      final profile = await _supabase
          .from('profiles')
          .select('total_steps_all_time')
          .eq('id', userId)
          .maybeSingle();
      final lifetime =
          (profile?['total_steps_all_time'] as num?)?.toInt() ?? 0;

      // Read all participant rows for this user — server-side join with
      // battles restricts to active ones.
      final rows = await _supabase
          .from('battle_participants')
          .select('battle_id, start_steps_baseline, battles!inner(status)')
          .eq('user_id', userId)
          .eq('invite_status', 'accepted')
          .eq('battles.status', 'active');

      int updated = 0;
      for (final r in rows as List) {
        final m = r as Map<String, dynamic>;
        final battleId = m['battle_id'] as String;
        final baseline =
            (m['start_steps_baseline'] as num?)?.toInt() ?? lifetime;
        final battleSteps = (lifetime - baseline).clamp(0, lifetime);
        await _supabase
            .from('battle_participants')
            .update({'current_steps': battleSteps})
            .eq('battle_id', battleId)
            .eq('user_id', userId);
        updated++;
      }

      AppLogger.battle.d('propagateStepsToBattles', fields: {
        'userId': userId,
        'lifetime': lifetime,
        'battlesUpdated': updated,
      });
    } catch (e, s) {
      AppLogger.battle.e('propagateStepsToBattles:failed',
          fields: {'userId': userId}, error: e, stack: s);
      // Don't rethrow — same rationale as missions.
    }
  }

  // ---------------------------------------------------------------------------
  // Clan propagation (Phase 6)
  //
  // Each user's `clan_members.steps_today` row is bumped to their today's
  // step total (the dashboard ranks members by it). If the user isn't in a
  // clan, this is a no-op.
  // ---------------------------------------------------------------------------

  Future<void> _propagateToClan(String userId, int todaySteps) async {
    try {
      final profile = await _supabase
          .from('profiles')
          .select('clan_id')
          .eq('id', userId)
          .maybeSingle();
      final clanId = profile?['clan_id'] as String?;
      if (clanId == null || clanId.isEmpty) {
        AppLogger.clan.t('propagateToClan:noClan', fields: {'userId': userId});
        return;
      }
      await _supabase
          .from('clan_members')
          .update({'steps_today': todaySteps})
          .eq('clan_id', clanId)
          .eq('user_id', userId);
      AppLogger.clan.d('propagateToClan:done',
          fields: {'userId': userId, 'clanId': clanId, 'steps': todaySteps});
    } catch (e, s) {
      AppLogger.clan.e('propagateToClan:failed',
          fields: {'userId': userId}, error: e, stack: s);
      // Don't rethrow — clan propagation isn't critical to step sync.
    }
  }

  // ---------------------------------------------------------------------------
  // Mission propagation (Phase 3)
  //
  // Updates every step-category daily mission with today's step total and
  // every step-category weekly mission with this week's cumulative total.
  // Awards mission XP exactly once per (mission, period) on the false→true
  // completion transition.
  // ---------------------------------------------------------------------------

  Future<void> _propagateToMissions(String userId, int todaySteps) async {
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final weekStart = _weekStart();

    try {
      final daily = await _missionService.getDailyMissions();
      final weekly = await _missionService.getWeeklyMissions();
      final weeklyTotal = await getWeeklyTotal(userId);

      final dailySteps =
          daily.where((m) => m.category == MissionCategory.steps).toList();
      final weeklySteps =
          weekly.where((m) => m.category == MissionCategory.steps).toList();

      AppLogger.mission.i('propagateSteps:start', fields: {
        'userId': userId,
        'todaySteps': todaySteps,
        'weeklyTotal': weeklyTotal,
        'today': today,
        'weekStart': weekStart,
        'dailyStepMissions': dailySteps.map((m) => m.missionId).toList(),
        'weeklyStepMissions': weeklySteps.map((m) => m.missionId).toList(),
      });

      for (final m in dailySteps) {
        await _upsertProgress(
          userId: userId,
          mission: m,
          currentValue: todaySteps,
          periodStart: today,
        );
      }
      for (final m in weeklySteps) {
        await _upsertProgress(
          userId: userId,
          mission: m,
          currentValue: weeklyTotal,
          periodStart: weekStart,
        );
      }

      AppLogger.mission.i('propagateSteps:done', fields: {'userId': userId});
    } catch (e, s) {
      AppLogger.mission.e('propagateSteps:failed',
          fields: {'userId': userId, 'todaySteps': todaySteps},
          error: e,
          stack: s);
      // Don't rethrow — failing mission propagation shouldn't abort the
      // whole step sync; the next sync will retry.
    }
  }

  /// Upsert the (user, mission, periodStart) progress row. Idempotent on
  /// the composite PK. Awards XP on a false→true completion transition.
  Future<void> _upsertProgress({
    required String userId,
    required MissionModel mission,
    required int currentValue,
    required String periodStart,
  }) async {
    try {
      final existing = await _supabase
          .from('user_mission_progress')
          .select('current_value, is_completed')
          .eq('user_id', userId)
          .eq('mission_id', mission.missionId)
          .eq('period_start', periodStart)
          .maybeSingle();

      final priorValue =
          (existing?['current_value'] as num?)?.toInt() ?? 0;
      final wasCompleted = existing?['is_completed'] as bool? ?? false;
      final reachedTarget = currentValue >= mission.targetValue;
      // Completion is monotonic-true: once a mission is done for a period
      // it stays done, even if the source step value transiently dips
      // (we saw this when the aggregator flickered between HC=440 and a
      // poisoned native=40543 — XP got awarded on the spike and the
      // mission then un-completed). Keep XP, keep the green checkmark.
      final nowCompleted = wasCompleted || reachedTarget;

      AppLogger.mission.d('upsertProgress', fields: {
        'userId': userId,
        'missionId': mission.missionId,
        'periodStart': periodStart,
        'priorValue': priorValue,
        'currentValue': currentValue,
        'targetValue': mission.targetValue,
        'wasCompleted': wasCompleted,
        'reachedTarget': reachedTarget,
        'nowCompleted': nowCompleted,
        'existed': existing != null,
      });

      await _supabase.from('user_mission_progress').upsert(
        {
          'user_id': userId,
          'mission_id': mission.missionId,
          'period_start': periodStart,
          // Keep `current_value` honest — show the latest count even if
          // the mission is already locked completed.
          'current_value': currentValue,
          'target_value': mission.targetValue,
          'is_completed': nowCompleted,
          if (nowCompleted && !wasCompleted)
            'completed_at': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'user_id,mission_id,period_start',
      );

      if (!wasCompleted && nowCompleted) {
        AppLogger.mission.i('missionCompleted', fields: {
          'missionId': mission.missionId,
          'userId': userId,
          'xpReward': mission.xpReward,
        });
        await _xpService.awardXP(userId: userId, amount: mission.xpReward);
      }
    } catch (e, s) {
      AppLogger.mission.e('upsertProgress:failed',
          fields: {
            'userId': userId,
            'missionId': mission.missionId,
            'periodStart': periodStart,
          },
          error: e,
          stack: s);
      rethrow;
    }
  }

  static String _weekStart() {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    return DateFormat('yyyy-MM-dd').format(monday);
  }
}
