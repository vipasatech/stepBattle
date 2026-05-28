import 'dart:math';

import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/constants.dart';
import '../models/battle_model.dart';
import '../models/mission_model.dart';
import '../utils/app_logger.dart';
import 'mission_service.dart';
import 'xp_service.dart';

/// Battles + battle_participants on Supabase.
///
/// Time-window scoring (Phase 4) uses the lifetime-counter baseline: on
/// activation we snapshot each participant's `profiles.total_steps_all_time`
/// into `battle_participants.start_steps_baseline`. During the active
/// window `current_steps = total_steps_all_time - start_steps_baseline`
/// (updated from `StepService._propagateToActiveBattles`). On completion
/// we set `end_steps_baseline` so the final score is permanently frozen
/// independent of any future totals.
class BattleService {
  final SupabaseClient _supabase;
  final XPService _xpService;
  final MissionService _missionService;

  BattleService({
    SupabaseClient? supabase,
    XPService? xpService,
    MissionService? missionService,
  })  : _supabase = supabase ?? Supabase.instance.client,
        _xpService = xpService ?? XPService(),
        _missionService = missionService ?? MissionService();

  /// Generate a short random battle ID for display. (No longer used as
  /// the primary key — Postgres generates uuids — but kept for short
  /// display codes if/when we re-introduce them.)
  static String generateBattleCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ0123456789';
    final rng = Random();
    return String.fromCharCodes(
      Iterable.generate(4, (_) => chars.codeUnitAt(rng.nextInt(chars.length))),
    );
  }

  // ---------------------------------------------------------------------------
  // Create — with invite-based flow
  // ---------------------------------------------------------------------------

  /// Create a new battle with pending invites.
  ///
  /// [startTime] and [endTime] are the user-selected step-counting window.
  /// When all invitees accept:
  ///   • if start_time has already passed → the battle activates immediately
  ///     (baselines snapshot at that moment)
  ///   • if start_time is in the future → status moves to 'scheduled';
  ///     [activateScheduledBattles] flips it to 'active' at start_time
  ///
  /// Returns the created battle ID.
  Future<String> createBattle({
    required BattleType type,
    required List<BattleParticipant> participants,
    required DateTime startTime,
    required DateTime endTime,
    required String createdBy,
  }) async {
    final now = DateTime.now();
    if (!endTime.isAfter(startTime)) {
      throw ArgumentError('endTime must be after startTime');
    }
    if (startTime.isBefore(now.subtract(const Duration(minutes: 1)))) {
      // Tolerate small clock skew; reject anything meaningfully in the past.
      throw ArgumentError('startTime cannot be in the past');
    }
    final xp = type == BattleType.oneVsOne
        ? AppConstants.xpWin1v1
        : AppConstants.xpWinGroup;

    try {
      // 1. Insert the battle row with the user-chosen window.
      final battleRow = await _supabase
          .from('battles')
          .insert({
            'type': type == BattleType.oneVsOne ? '1v1' : 'group',
            'status': 'pending',
            'start_time': startTime.toUtc().toIso8601String(),
            'end_time': endTime.toUtc().toIso8601String(),
            'xp_reward': xp,
            'created_by': createdBy,
          })
          .select('id')
          .single();
      final battleId = battleRow['id'] as String;

      // 2. Insert participants — creator auto-accepted, others pending.
      final participantRows = participants.map((p) {
        final isCreator = p.userId == createdBy;
        return {
          'battle_id': battleId,
          'user_id': p.userId,
          'display_name': p.displayName,
          'avatar_url': p.avatarURL,
          'current_steps': 0,
          'is_winner': false,
          'invite_status': isCreator ? 'accepted' : 'pending',
        };
      }).toList();
      await _supabase.from('battle_participants').insert(participantRows);

      AppLogger.battle.i('createBattle', fields: {
        'battleId': battleId,
        'type': type.name,
        'createdBy': createdBy,
        'participantCount': participants.length,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime.toIso8601String(),
        'xpReward': xp,
      });

      // 3. Fan out friend-style notifications to each invitee.
      final creator = participants.firstWhere((p) => p.userId == createdBy);
      final creatorName = creator.displayName;
      for (final p in participants) {
        if (p.userId == createdBy) continue;
        await _supabase.from('notifications').insert({
          'user_id': p.userId,
          'type': 'battle_invite',
          'title': 'Battle Invite',
          'body':
              '$creatorName challenged you to ${type == BattleType.oneVsOne ? "a 1v1" : "a group"} battle',
          'data': {
            'battle_id': battleId,
            'from_user_id': createdBy,
          },
        });
      }

      return battleId;
    } catch (e, s) {
      AppLogger.battle
          .e('createBattle:failed', error: e, stack: s);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Invite responses
  // ---------------------------------------------------------------------------

  Future<void> acceptInvite({
    required String battleId,
    required String userId,
  }) async {
    AppLogger.battle.i('acceptInvite',
        fields: {'battleId': battleId, 'userId': userId});
    try {
      // Mark this participant accepted.
      await _supabase
          .from('battle_participants')
          .update({'invite_status': 'accepted'})
          .eq('battle_id', battleId)
          .eq('user_id', userId);

      // If everyone is now accepted, either activate immediately (start_time
      // already passed) or move to 'scheduled' (start_time still future).
      final battle = await _fetchBattle(battleId);
      if (battle == null) return;
      if (battle.status != BattleStatus.pending) return;
      final allAccepted = battle.participants.every(
          (p) => p.inviteStatus == ParticipantInviteStatus.accepted);
      if (!allAccepted) return;

      if (battle.startTime.isAfter(DateTime.now())) {
        await _scheduleBattle(battle);
      } else {
        await _activateBattle(battle);
      }
    } catch (e, s) {
      AppLogger.battle.e('acceptInvite:failed',
          fields: {'battleId': battleId, 'userId': userId},
          error: e,
          stack: s);
      rethrow;
    }
  }

  Future<void> rejectInvite({
    required String battleId,
    required String userId,
  }) async {
    AppLogger.battle.i('rejectInvite',
        fields: {'battleId': battleId, 'userId': userId});
    try {
      final battle = await _fetchBattle(battleId);
      if (battle == null) return;
      if (battle.status != BattleStatus.pending) return;

      if (battle.type == BattleType.oneVsOne) {
        // 1v1 — reject cancels the whole battle.
        await _supabase
            .from('battles')
            .update({'status': 'cancelled'}).eq('id', battleId);

        if (battle.createdBy != userId) {
          await _supabase.from('notifications').insert({
            'user_id': battle.createdBy,
            'type': 'battle_rejected',
            'title': 'Battle Declined',
            'body': 'Your opponent declined the battle',
            'data': {'battle_id': battleId, 'from_user_id': userId},
          });
        }
        return;
      }

      // Group — mark this participant rejected. If the remainder are all
      // accepted, activate.
      await _supabase
          .from('battle_participants')
          .update({'invite_status': 'rejected'})
          .eq('battle_id', battleId)
          .eq('user_id', userId);

      final refreshed = await _fetchBattle(battleId);
      if (refreshed == null) return;
      final accepted = refreshed.participants
          .where((p) =>
              p.inviteStatus == ParticipantInviteStatus.accepted)
          .toList();
      final pending = refreshed.participants
          .where((p) =>
              p.inviteStatus == ParticipantInviteStatus.pending)
          .toList();
      if (pending.isEmpty && accepted.length >= 2) {
        await _activateBattle(refreshed);
      }
    } catch (e, s) {
      AppLogger.battle.e('rejectInvite:failed',
          fields: {'battleId': battleId, 'userId': userId},
          error: e,
          stack: s);
      rethrow;
    }
  }

  /// All accepted but start_time is still in the future → move to
  /// 'scheduled'. We DO NOT touch start_time / end_time (the user picked
  /// them) and DO NOT capture baselines yet — baselines have to reflect
  /// each player's `total_steps_all_time` at the moment the window opens.
  Future<void> _scheduleBattle(BattleModel battle) async {
    AppLogger.battle.i('battleScheduled', fields: {
      'battleId': battle.battleId,
      'startsAt': battle.startTime.toIso8601String(),
    });
    await _supabase
        .from('battles')
        .update({'status': 'scheduled'}).eq('id', battle.battleId);

    await _supabase.from('notifications').insert({
      'user_id': battle.createdBy,
      'type': 'battle_started',
      'title': 'Battle Scheduled',
      'body':
          'All players are in. Battle starts at ${_humanTime(battle.startTime)}.',
      'data': {'battle_id': battle.battleId},
    });
  }

  /// Either acceptance arrived after start_time, or the scheduled sweep
  /// noticed start_time has now passed. Flip to 'active' and snapshot
  /// every accepted participant's lifetime baseline. The user-chosen
  /// start_time / end_time are NOT touched — they're the battle window.
  Future<void> _activateBattle(BattleModel battle) async {
    AppLogger.battle.i('battleActivated', fields: {
      'battleId': battle.battleId,
      'startTime': battle.startTime.toIso8601String(),
      'endTime': battle.endTime.toIso8601String(),
    });

    await _supabase
        .from('battles')
        .update({'status': 'active'}).eq('id', battle.battleId);

    for (final p in battle.participants) {
      if (p.inviteStatus != ParticipantInviteStatus.accepted) continue;
      final profile = await _supabase
          .from('profiles')
          .select('total_steps_all_time')
          .eq('id', p.userId)
          .maybeSingle();
      final baseline =
          (profile?['total_steps_all_time'] as num?)?.toInt() ?? 0;
      await _supabase
          .from('battle_participants')
          .update({
            'start_steps_baseline': baseline,
            'current_steps': 0,
          })
          .eq('battle_id', battle.battleId)
          .eq('user_id', p.userId);
    }

    // Only notify on the "kicked off" transition. If we came from
    // 'scheduled' the creator already got a "scheduled" notification, but
    // a "live now" ping is still useful so they know to open the app.
    await _supabase.from('notifications').insert({
      'user_id': battle.createdBy,
      'type': 'battle_started',
      'title': 'Battle Live',
      'body': 'Your battle just started. Step it up!',
      'data': {'battle_id': battle.battleId},
    });
  }

  /// Sweep scheduled battles whose start_time has arrived and activate
  /// them. Called on app launch / Battles tab open, similar to
  /// [cancelExpiredPendingBattles].
  Future<void> activateScheduledBattles(String userId) async {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    try {
      final rows = await _supabase
          .from('battles')
          .select('*, battle_participants(*)')
          .eq('status', 'scheduled')
          .lte('start_time', nowIso);

      int activated = 0;
      for (final raw in rows as List) {
        final battle =
            BattleModel.fromSupabaseRow(raw as Map<String, dynamic>);
        // Caller's device only fires this for battles it participates in;
        // RLS update policies cover cross-user baseline writes (see
        // 0005_co_participant_writes.sql).
        if (!battle.participants.any((p) => p.userId == userId)) continue;
        await _activateBattle(battle);
        activated++;
      }

      AppLogger.battle.d('activateScheduled:done',
          fields: {'userId': userId, 'activated': activated});
    } catch (e, s) {
      AppLogger.battle.e('activateScheduled:failed',
          fields: {'userId': userId}, error: e, stack: s);
      rethrow;
    }
  }

  String _humanTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '${t.day}/${t.month} $h:$m';
  }

  /// Creator cancels their own pending battle before anyone accepts.
  Future<void> cancelBattle(String battleId) async {
    await _supabase
        .from('battles')
        .update({'status': 'cancelled'})
        .eq('id', battleId)
        .eq('status', 'pending');
  }

  /// Delete a pending battle. Marks cancelled, clears battle_invite
  /// notifications.
  Future<void> deletePendingBattle({
    required String battleId,
    required String actorId,
  }) async {
    final battle = await _fetchBattle(battleId);
    if (battle == null) return;
    if (battle.createdBy != actorId) {
      throw StateError('Only the creator can delete a pending battle.');
    }
    if (battle.status != BattleStatus.pending) {
      throw StateError('Only pending battles can be deleted.');
    }

    await _supabase
        .from('battles')
        .update({'status': 'cancelled'}).eq('id', battleId);

    // Drop battle_invite notifications for this battle so they vanish
    // from invitees' trays. We delete rather than mark read since these
    // are now actionable only against a cancelled battle.
    await _supabase
        .from('notifications')
        .delete()
        .eq('type', 'battle_invite')
        .filter('data->>battle_id', 'eq', battleId);
  }

  /// Auto-cancel pending battles older than 24h that this user created.
  /// Called on Battles tab open.
  Future<void> cancelExpiredPendingBattles(String userId) async {
    final cutoff = DateTime.now()
        .subtract(const Duration(hours: 24))
        .toUtc()
        .toIso8601String();
    try {
      final rows = await _supabase
          .from('battles')
          .select('id')
          .eq('status', 'pending')
          .eq('created_by', userId)
          .lt('created_at', cutoff);
      int cancelled = 0;
      for (final r in rows as List) {
        final id = (r as Map<String, dynamic>)['id'] as String;
        await _supabase
            .from('battles')
            .update({'status': 'cancelled'}).eq('id', id);
        cancelled++;
      }
      AppLogger.battle.d('cancelExpiredPending',
          fields: {'userId': userId, 'cancelled': cancelled});
    } catch (e, s) {
      AppLogger.battle.e('cancelExpiredPending:failed',
          fields: {'userId': userId}, error: e, stack: s);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Auto-complete on endTime
  // ---------------------------------------------------------------------------

  Future<void> completeExpiredBattles(String userId) async {
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final rows = await _supabase
        .from('battles')
        .select('*, battle_participants(*)')
        .eq('status', 'active')
        .lt('end_time', nowIso);

    int completed = 0;
    for (final raw in rows as List) {
      final battle =
          BattleModel.fromSupabaseRow(raw as Map<String, dynamic>);
      if (!battle.participants.any((p) => p.userId == userId)) continue;

      // Pick winner: highest current_steps. Ties → no winner.
      String? winnerId;
      int topSteps = -1;
      bool tie = false;
      for (final p in battle.participants) {
        if (p.currentSteps > topSteps) {
          topSteps = p.currentSteps;
          winnerId = p.userId;
          tie = false;
        } else if (p.currentSteps == topSteps) {
          tie = true;
        }
      }
      if (tie || topSteps <= 0) winnerId = null;

      // Freeze each participant: stamp end_steps_baseline + is_winner.
      for (final p in battle.participants) {
        final profile = await _supabase
            .from('profiles')
            .select('total_steps_all_time')
            .eq('id', p.userId)
            .maybeSingle();
        final lifetime =
            (profile?['total_steps_all_time'] as num?)?.toInt() ?? 0;
        await _supabase
            .from('battle_participants')
            .update({
              'end_steps_baseline': lifetime,
              'is_winner': p.userId == winnerId,
            })
            .eq('battle_id', battle.battleId)
            .eq('user_id', p.userId);
      }

      await _supabase
          .from('battles')
          .update({'status': 'completed', 'winner_id': winnerId})
          .eq('id', battle.battleId);

      AppLogger.battle.i('battleCompleted', fields: {
        'battleId': battle.battleId,
        'winnerId': winnerId,
        'topSteps': topSteps,
        'tie': tie,
      });
      completed++;

      // Award XP + bump battle missions for the winner.
      if (winnerId != null) {
        await _xpService.awardXP(userId: winnerId, amount: battle.xpReward);
        await _propagateBattleWinToMissions(winnerId);
      }

      // Notify all participants.
      for (final p in battle.participants) {
        final isWinner = p.userId == winnerId;
        final body = winnerId == null
            ? 'Battle ended in a tie'
            : isWinner
                ? 'You won the battle! +${battle.xpReward} XP'
                : 'Battle ended — better luck next time';
        await _supabase.from('notifications').insert({
          'user_id': p.userId,
          'type': 'battle_result',
          'title': 'Battle Ended',
          'body': body,
          'data': {
            'battle_id': battle.battleId,
            'winner_id': winnerId,
          },
        });
      }
    }

    AppLogger.battle.d('completeExpired:done',
        fields: {'userId': userId, 'completed': completed});
  }

  Future<void> _propagateBattleWinToMissions(String winnerId) async {
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final weekStart = _weekStart();

    AppLogger.mission.i('propagateBattleWin:start',
        fields: {'winnerId': winnerId});

    final daily = await _missionService.getDailyMissions();
    final weekly = await _missionService.getWeeklyMissions();

    Future<void> bump(MissionModel m, String periodStart) async {
      final existing = await _supabase
          .from('user_mission_progress')
          .select('current_value, is_completed')
          .eq('user_id', winnerId)
          .eq('mission_id', m.missionId)
          .eq('period_start', periodStart)
          .maybeSingle();
      final priorValue =
          (existing?['current_value'] as num?)?.toInt() ?? 0;
      final wasCompleted = existing?['is_completed'] as bool? ?? false;
      final newValue = priorValue + 1;
      final nowCompleted = newValue >= m.targetValue;

      await _supabase.from('user_mission_progress').upsert(
        {
          'user_id': winnerId,
          'mission_id': m.missionId,
          'period_start': periodStart,
          'current_value': newValue,
          'target_value': m.targetValue,
          'is_completed': nowCompleted,
          if (nowCompleted)
            'completed_at': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'user_id,mission_id,period_start',
      );

      if (!wasCompleted && nowCompleted) {
        await _xpService.awardXP(userId: winnerId, amount: m.xpReward);
      }
    }

    for (final m in daily.where((m) => m.category == MissionCategory.battle)) {
      await bump(m, today);
    }
    for (final m in weekly.where((m) => m.category == MissionCategory.battle)) {
      await bump(m, weekStart);
    }
  }

  static String _weekStart() {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    return DateFormat('yyyy-MM-dd').format(monday);
  }

  // ---------------------------------------------------------------------------
  // Update steps (called from StepService propagation)
  // ---------------------------------------------------------------------------

  Future<void> updateParticipantSteps({
    required String battleId,
    required String userId,
    required int steps,
  }) async {
    await _supabase
        .from('battle_participants')
        .update({'current_steps': steps})
        .eq('battle_id', battleId)
        .eq('user_id', userId);
  }

  // ---------------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------------

  Future<BattleModel?> _fetchBattle(String battleId) async {
    final raw = await _supabase
        .from('battles')
        .select('*, battle_participants(*)')
        .eq('id', battleId)
        .maybeSingle();
    if (raw == null) return null;
    return BattleModel.fromSupabaseRow(raw);
  }

  Stream<BattleModel?> watchBattle(String battleId) {
    return _supabase
        .from('battles')
        .stream(primaryKey: ['id'])
        .eq('id', battleId)
        .asyncMap((rows) async {
          if (rows.isEmpty) return null;
          // We need participants embedded — re-fetch with the join for
          // a fully-hydrated model. The trigger here is the battle row
          // change; the participant rows lag slightly but the next emit
          // will reconcile.
          return _fetchBattle(battleId);
        });
  }

  Future<List<BattleModel>> getBattles({
    required String userId,
    required BattleStatus status,
  }) async {
    final rows = await _supabase
        .from('battles')
        .select('*, battle_participants(*)')
        .eq('status', status.name)
        .order('start_time', ascending: false);
    return (rows as List)
        .map((r) =>
            BattleModel.fromSupabaseRow(r as Map<String, dynamic>))
        .where((b) => b.participants.any((p) => p.userId == userId))
        .toList();
  }

  /// Stream of all battles (any status) this user is a participant in.
  /// Implemented by streaming `battle_participants` (cheap, indexed on
  /// user_id) and resolving the full battle row + nested participants on
  /// each tick. Slightly chatty but keeps the surface API the same the
  /// Firestore version exposed.
  Stream<List<BattleModel>> watchAllBattles(String userId) {
    return _supabase
        .from('battle_participants')
        .stream(primaryKey: ['battle_id', 'user_id'])
        .eq('user_id', userId)
        .asyncMap((rows) async {
          final battleIds =
              rows.map((r) => r['battle_id'] as String).toSet().toList();
          if (battleIds.isEmpty) return <BattleModel>[];
          final battlesRaw = await _supabase
              .from('battles')
              .select('*, battle_participants(*)')
              .inFilter('id', battleIds)
              .order('start_time', ascending: false);
          return (battlesRaw as List)
              .map((b) => BattleModel.fromSupabaseRow(
                  b as Map<String, dynamic>))
              .toList();
        });
  }

  Stream<List<BattleModel>> watchActiveBattles(String userId) {
    return watchAllBattles(userId)
        .map((list) => list.where((b) => b.status == BattleStatus.active).toList());
  }

  /// Stream of pending battles where the user is invited but hasn't responded.
  Stream<List<BattleModel>> watchIncomingInvites(String userId) {
    return _supabase
        .from('battle_participants')
        .stream(primaryKey: ['battle_id', 'user_id'])
        .eq('user_id', userId)
        .asyncMap((rows) async {
          final pendingIds = rows
              .where((r) => r['invite_status'] == 'pending')
              .map((r) => r['battle_id'] as String)
              .toList();
          if (pendingIds.isEmpty) return <BattleModel>[];
          final battlesRaw = await _supabase
              .from('battles')
              .select('*, battle_participants(*)')
              .eq('status', 'pending')
              .inFilter('id', pendingIds);
          return (battlesRaw as List)
              .map((b) => BattleModel.fromSupabaseRow(
                  b as Map<String, dynamic>))
              .toList();
        });
  }
}
