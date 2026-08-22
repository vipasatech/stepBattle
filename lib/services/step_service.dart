import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/constants.dart';
import '../models/mission_model.dart';
import '../models/step_log_model.dart';
import '../utils/app_logger.dart';
import 'google_fit_service.dart';
import 'mission_service.dart';
import 'native_step_service.dart';
import 'perfect_month_service.dart';
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
  final PerfectMonthService _perfectMonthService;

  StepService({
    SupabaseClient? supabase,
    MissionService? missionService,
    XPService? xpService,
    PerfectMonthService? perfectMonthService,
  })  : _supabase = supabase ?? Supabase.instance.client,
        _missionService = missionService ?? MissionService(),
        _xpService = xpService ?? XPService(),
        _perfectMonthService =
            perfectMonthService ?? PerfectMonthService();

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

      // Streak-milestone XP — the streak counters themselves are
      // updated by a DB trigger on step_logs insert; we just read
      // the fresh values and pay out first-7 / every-30-day bonuses
      // if the user crossed a new threshold.
      await _awardStreakMilestoneXP(userId: userId);

      // Perfect-month XP — tier-scaled bonus for a calendar month
      // with `step_count > 0` on every day. Idempotent (guarded by
      // profiles.last_perfect_month_awarded), safe to call every
      // sync — short-circuits quickly on months we've already paid.
      await _perfectMonthService.checkAndAward(userId: userId);

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

  /// Fetch the user's current + best streak from `profiles` (both
  /// maintained server-side by the step-log trigger) and delegate to
  /// [XPService.checkStreakMilestones] to award the first-7-day and
  /// every-30-day bonuses if the user has crossed a new threshold.
  /// Fires on every step sync — the XP service's flags make repeated
  /// calls idempotent.
  Future<void> _awardStreakMilestoneXP({required String userId}) async {
    try {
      final profile = await _supabase
          .from('profiles')
          .select('current_streak, longest_streak')
          .eq('id', userId)
          .maybeSingle();
      if (profile == null) return;
      final currentStreak =
          (profile['current_streak'] as num?)?.toInt() ?? 0;
      final bestStreak =
          (profile['longest_streak'] as num?)?.toInt() ?? 0;
      await _xpService.checkStreakMilestones(
        userId: userId,
        currentStreak: currentStreak,
        bestStreak: bestStreak,
      );
    } catch (e) {
      AppLogger.step.w('awardStreakMilestoneXP:failed',
          fields: {'userId': userId, 'err': e.toString()});
    }
  }

  // ---------------------------------------------------------------------------
  // Read helpers
  // ---------------------------------------------------------------------------

  /// Stream today's step log row. Emits null when the row doesn't exist
  /// yet (fresh day, no sync has run).
  ///
  /// Filter is `date == today` server-side. `step_logs` has an RLS
  /// policy scoping every row to `user_id = auth.uid()` (migration
  /// 0001), so the client already only ever sees the current user's
  /// rows — filtering by date alone is enough to reduce the wire
  /// payload to one row. Previously we filtered on `user_id` and
  /// picked today's row client-side, which streamed every daily row
  /// the user had (hundreds after a year) on every change.
  ///
  /// Supabase's realtime `.stream()` supports only ONE filter — see
  /// SupabaseStreamFilterBuilder in supabase 2.10; chaining a second
  /// `.eq()` doesn't compose.
  ///
  /// `today` is captured at subscription time; if the day rolls over
  /// while the stream is live, the caller should invalidate this
  /// provider to re-anchor on the new date.
  Stream<StepLogModel?> watchTodaySteps(String userId) {
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    return _supabase
        .from('step_logs')
        .stream(primaryKey: ['id'])
        .eq('date', today)
        .map((rows) {
          // Defensive: RLS should already restrict rows to this user,
          // but pin the check client-side too so a mis-scoped policy
          // can't leak someone else's row into the widget.
          final match = rows.firstWhere(
            (r) => r['user_id'] == userId,
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
    // Same auth-identity guard as _propagateToMissions — skip when
    // the caller's userId doesn't match the current session (typical
    // when a step-sync tick outlives a sign-out).
    final authUid = _supabase.auth.currentUser?.id;
    if (authUid == null || authUid != userId) {
      AppLogger.battle.w('propagateStepsToBattles:skipStaleUser', fields: {
        'requested': userId,
        'authUid': authUid,
      });
      return;
    }
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
      int healed = 0;
      for (final r in rows as List) {
        final m = r as Map<String, dynamic>;
        final battleId = m['battle_id'] as String;
        final rawBaseline = m['start_steps_baseline'] as num?;

        // AUTO-HEAL — daily-recurring series instances are spawned by
        // the SQL function in migration 0046 without a start_steps_baseline
        // (the spawn INSERT omits the column). That left every daily
        // battle stuck at current_steps = 0 because the null baseline
        // fell back to lifetime, making `lifetime - baseline` always 0.
        //
        // Detect the NULL baseline on an active battle and patch it to
        // the user's current lifetime so tracking starts from THIS
        // moment. Progress made before the heal is lost (there's no
        // way to recover the historical value), but the battle starts
        // working going forward instead of never counting steps.
        //
        // A server-side migration in PENDING_MIGRATIONS.md fixes the
        // spawn function so future daily instances arrive with a
        // proper baseline; this client patch keeps existing instances
        // working until that ships.
        if (rawBaseline == null) {
          await _supabase
              .from('battle_participants')
              .update({
                'start_steps_baseline': lifetime,
                'current_steps': 0,
              })
              .eq('battle_id', battleId)
              .eq('user_id', userId);
          healed++;
          AppLogger.battle.i('battle:baselineAutoHealed', fields: {
            'battleId': battleId,
            'baseline': lifetime,
          });
          continue;
        }

        final baseline = rawBaseline.toInt();
        final battleSteps = (lifetime - baseline).clamp(0, lifetime);
        await _supabase
            .from('battle_participants')
            .update({'current_steps': battleSteps})
            .eq('battle_id', battleId)
            .eq('user_id', userId);
        updated++;
      }

      if (healed > 0) {
        AppLogger.battle.i('propagateStepsToBattles:autoHealed',
            fields: {'userId': userId, 'count': healed});
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
    // Auth-identity guard. `_upsertProgress` writes rows keyed by
    // `user_id = userId`, and RLS enforces `user_id = auth.uid()`.
    // If `userId` comes from a stale reference (typical case: user
    // signed out of account A, signed in as B, but a pending
    // step-sync tick still holds A's uid), the upsert 42501s and
    // spams Diagnostics with `upsertProgress:failed`. Skip early
    // when the caller's userId doesn't match the current session.
    final authUid = _supabase.auth.currentUser?.id;
    if (authUid == null || authUid != userId) {
      AppLogger.mission.w('propagateSteps:skipStaleUser', fields: {
        'requested': userId,
        'authUid': authUid,
      });
      return;
    }
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
        await _xpService.awardXP(
          userId: userId,
          amount: mission.xpReward,
          reason: mission.title,
        );
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

  // ---------------------------------------------------------------------------
  // MISSED-DAYS BACKFILL
  //
  // When the app was terminated across one or more calendar days and the
  // user walked during that window, the periodic WorkManager sync may
  // have missed writing step_logs rows for those days entirely (Xiaomi /
  // Realme aggressive battery savers). This routine reconciles those
  // gaps on next app open.
  //
  // Strategy — try sources in order of accuracy:
  //   1. Google Fit history (if the user enabled the Fit fallback).
  //      Fit's REST API returns per-day totals; accurate to whatever
  //      Fit itself observed via its own background sensor listener.
  //   2. Native pedometer time-proportional estimate. We know the
  //      sensor cumulative at the last snapshot + the cumulative now,
  //      and how much wall-clock time elapsed. Distribute the delta
  //      across the missed days weighted by hours-in-window. Rough,
  //      but honest — the resulting rows are tagged with source
  //      `native_estimate` so downstream code / the UI can flag them.
  //
  // Rows already present with non-trivial step_count (>100) are left
  // alone — we assume WorkManager captured them at some point during
  // that day, and any better value we could synthesise is speculative.
  //
  // Runs once per session from MainShell._runInitialSync. Skips
  // silently when there's no gap to fill.
  // ---------------------------------------------------------------------------

  /// Max number of calendar days back to check. Prevents runaway
  /// backfill for users who haven't opened the app in months (which
  /// would be a much bigger data-quality problem anyway).
  static const int _maxBackfillDays = 14;

  /// Threshold for "this row already has plausible data" — a WorkManager
  /// sync that only ran once and wrote a partial 3pm value would still
  /// exceed 100, so we don't overwrite it.
  static const int _plausibleStepFloor = 100;

  Future<void> backfillMissedDays({
    required String userId,
    required NativeStepService native,
    required GoogleFitService googleFit,
  }) async {
    try {
      // Bail early if we've never captured a snapshot — nothing to
      // reason about.
      final lastKnownDate = native.lastKnownDate;
      if (lastKnownDate == null) return;

      final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
      if (lastKnownDate == today) return;   // no gap

      final lastDate = _parseYmd(lastKnownDate);
      final todayDate = _parseYmd(today);
      if (lastDate == null || todayDate == null) return;

      // Missed days are the calendar days STRICTLY BETWEEN lastDate
      // and today. lastDate itself may have received a rollover
      // snapshot; today is being handled by normal sync flow.
      final daysGap = todayDate.difference(lastDate).inDays;
      if (daysGap <= 0) return;
      // Include lastDate in the backfill sweep too — its final total
      // was frozen at whatever time we snapshotted, so if any steps
      // happened between that snapshot and midnight, the row is
      // under-reported. Bounded by _maxBackfillDays for safety.
      final missedDays = <DateTime>[];
      for (var i = 0; i <= daysGap - 1; i++) {
        missedDays.add(lastDate.add(Duration(days: i)));
        if (missedDays.length >= _maxBackfillDays) break;
      }
      if (missedDays.isEmpty) return;

      AppLogger.step.i('backfillMissedDays:start', fields: {
        'userId': userId,
        'lastKnownDate': lastKnownDate,
        'today': today,
        'daysToBackfill': missedDays.length,
        'fitEnabled': googleFit.isEnabled,
      });

      // Fetch existing rows in ONE round-trip so we can skip days
      // that already have plausible data.
      final existingRows = await _supabase
          .from('step_logs')
          .select('date, step_count')
          .eq('user_id', userId)
          .inFilter(
            'date',
            missedDays
                .map((d) => DateFormat('yyyy-MM-dd').format(d))
                .toList(),
          );
      final existingByDate = <String, int>{
        for (final r in existingRows as List)
          (r as Map)['date'] as String:
              (r['step_count'] as num?)?.toInt() ?? 0,
      };

      // Pre-compute the total sensor delta across the whole silent
      // window. Only used for the time-proportional fallback.
      final currentCumulative = native.currentCumulative;
      final lastCumulative = native.lastKnownCumulative;
      final lastAt = native.lastKnownAt;
      final sensorDelta = (currentCumulative != null &&
              lastCumulative != null &&
              currentCumulative >= lastCumulative)
          ? currentCumulative - lastCumulative
          : 0;
      final elapsedHours = lastAt == null
          ? 0.0
          : DateTime.now().difference(lastAt).inMinutes / 60.0;

      var backfilled = 0;
      var skippedExisting = 0;
      var skippedNoSource = 0;

      for (final missedDate in missedDays) {
        final dateStr = DateFormat('yyyy-MM-dd').format(missedDate);
        final existing = existingByDate[dateStr] ?? 0;
        if (existing >= _plausibleStepFloor) {
          skippedExisting++;
          continue;
        }

        // Try Google Fit first — authoritative when available.
        int? steps;
        String source = 'unknown';
        if (googleFit.isEnabled) {
          steps = await googleFit.getStepsForDate(missedDate);
          if (steps != null && steps > 0) source = 'google_fit_backfill';
        }

        // Fall back to native time-proportional estimation. Only
        // meaningful when we have a sensor delta AND a reasonable
        // elapsed window; otherwise skip (better than fabricating a
        // number out of nowhere).
        if ((steps == null || steps == 0) &&
            sensorDelta > 0 &&
            elapsedHours > 0.5) {
          steps = _proportionalEstimate(
            date: missedDate,
            lastAt: lastAt!,
            totalDelta: sensorDelta,
            totalElapsedHours: elapsedHours,
          );
          if (steps > 0) source = 'native_estimate';
        }

        if (steps == null || steps <= 0) {
          skippedNoSource++;
          continue;
        }

        // UPSERT the row. Never OVERWRITE a plausibly-larger existing
        // count — if for some reason the row already has more, keep it.
        final finalCount = steps > existing ? steps : existing;
        try {
          await _supabase.from('step_logs').upsert(
            {
              'user_id': userId,
              'date': dateStr,
              'step_count': finalCount,
              // Calories derived from step count via the same
              // constant used elsewhere. Better than 0.
              'calories': (finalCount * AppConstants.caloriesPerStep).round(),
              'source': source,
              // Distance not attempted here — the client's stride
              // conversion is a stroll approximation; missed-day
              // estimates shouldn't fabricate distance too.
            },
            onConflict: 'user_id,date',
          );
          backfilled++;
          AppLogger.step.i('backfillMissedDays:filled', fields: {
            'date': dateStr,
            'source': source,
            'steps': finalCount,
          });
        } catch (e) {
          AppLogger.step.w('backfillMissedDays:upsertFailed', fields: {
            'date': dateStr,
            'err': e.toString(),
          });
        }
      }

      AppLogger.step.i('backfillMissedDays:done', fields: {
        'userId': userId,
        'backfilled': backfilled,
        'skippedExisting': skippedExisting,
        'skippedNoSource': skippedNoSource,
      });
    } catch (e, s) {
      // Never abort startup on backfill failure.
      AppLogger.step.e('backfillMissedDays:failed',
          fields: {'userId': userId}, error: e, stack: s);
    }
  }

  /// Time-proportional attribution of `totalDelta` to a single day
  /// within the silent window `[lastAt .. now]`. Weighted by the
  /// number of hours of `date` that fall inside the window.
  ///
  /// Example: if lastAt was yesterday 8pm and now is today 10am (14h
  /// window), yesterday contributed 4h and today 10h. A delta of
  /// 5000 steps allocates 5000 * (4/14) ≈ 1428 to yesterday.
  int _proportionalEstimate({
    required DateTime date,
    required DateTime lastAt,
    required int totalDelta,
    required double totalElapsedHours,
  }) {
    final dayStart = DateTime(date.year, date.month, date.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final windowStart = lastAt.isBefore(dayStart) ? dayStart : lastAt;
    final now = DateTime.now();
    final windowEnd = now.isAfter(dayEnd) ? dayEnd : now;
    if (!windowEnd.isAfter(windowStart)) return 0;
    final hoursInDay =
        windowEnd.difference(windowStart).inMinutes / 60.0;
    final ratio = hoursInDay / totalElapsedHours;
    return (totalDelta * ratio).round();
  }

  static DateTime? _parseYmd(String s) {
    try {
      return DateFormat('yyyy-MM-dd').parseStrict(s);
    } catch (_) {
      return null;
    }
  }
}
