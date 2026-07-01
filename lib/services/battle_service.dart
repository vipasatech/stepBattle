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
  /// Returns the created battle ID + the shareable join code (6 chars).
  Future<({String battleId, String joinCode})> createBattle({
    required BattleType type,
    required List<BattleParticipant> participants,
    required DateTime startTime,
    required DateTime endTime,
    required String createdBy,
    BattleVisibility visibility = BattleVisibility.private,
    int stakeXp = 0,
  }) async {
    final now = DateTime.now();
    if (!endTime.isAfter(startTime)) {
      throw ArgumentError('endTime must be after startTime');
    }
    if (startTime.isBefore(now.subtract(const Duration(minutes: 1)))) {
      // Tolerate small clock skew; reject anything meaningfully in the past.
      throw ArgumentError('startTime cannot be in the past');
    }
    if (stakeXp < 0) {
      throw ArgumentError('stakeXp must be ≥ 0');
    }
    // Stake-based battles must clear the 100-XP minimum (XP economy rule
    // in migration 0016). Non-stake battles (free play) still allowed.
    if (stakeXp > 0 && stakeXp < 100) {
      throw ArgumentError('Minimum stake is 100 XP.');
    }
    final joinCode = _generateJoinCode();

    try {
      // 1. Insert the battle row with the user-chosen window.
      //    xp_reward is the LEGACY per-side prize; we keep writing it for
      //    backwards compatibility with the old payout path but the new
      //    `stake_xp` column drives migration 0017's settle_stake_battle.
      final battleRow = await _supabase
          .from('battles')
          .insert({
            'type': type == BattleType.oneVsOne ? '1v1' : 'group',
            'status': 'pending',
            'start_time': startTime.toUtc().toIso8601String(),
            'end_time': endTime.toUtc().toIso8601String(),
            'xp_reward': stakeXp > 0
                ? 0
                : (type == BattleType.oneVsOne
                    ? AppConstants.xpWin1v1
                    : AppConstants.xpWinGroup),
            'stake_xp': stakeXp,
            'created_by': createdBy,
            'visibility': visibility == BattleVisibility.public
                ? 'public'
                : 'private',
            'join_code': joinCode,
          })
          .select('id')
          .single();
      final battleId = battleRow['id'] as String;

      // 2. Snapshot each participant's currently-selected battle avatar
      //    (migration 0019) so a later picker change doesn't retroactively
      //    swap the runner on this battle. One round-trip pulls every
      //    user's avatar id; missing rows fall back to 'avatar_01'.
      final avatarById = <String, String>{};
      try {
        final rows = await _supabase
            .from('profiles')
            .select('id, battle_avatar_id')
            .inFilter('id', participants.map((p) => p.userId).toList());
        for (final r in rows as List) {
          final m = r as Map<String, dynamic>;
          avatarById[m['id'] as String] =
              (m['battle_avatar_id'] as String?) ?? 'avatar_01';
        }
      } catch (e) {
        // Non-fatal — battle still creates with default avatars. Log and
        // continue so a transient profiles read doesn't block the user.
        AppLogger.battle.w('createBattle:avatar_snapshot_failed',
            fields: {'err': e.toString()});
      }

      // 3. Insert participants — creator auto-accepted, others pending.
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
          'battle_avatar_id': avatarById[p.userId] ?? 'avatar_01',
        };
      }).toList();
      await _supabase.from('battle_participants').insert(participantRows);

      // 3. Charge the creator's stake immediately. They're auto-accepted
      //    so they're committed the moment the battle exists — and we
      //    want the pot to grow predictably as each invitee accepts.
      if (stakeXp > 0) {
        await _chargeStake(
          battleId: battleId,
          userId: createdBy,
          stake: stakeXp,
        );
      }

      AppLogger.battle.i('createBattle', fields: {
        'battleId': battleId,
        'type': type.name,
        'createdBy': createdBy,
        'participantCount': participants.length,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime.toIso8601String(),
        'stakeXp': stakeXp,
        'visibility': visibility.name,
        'joinCode': joinCode,
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

      return (battleId: battleId, joinCode: joinCode);
    } catch (e, s) {
      AppLogger.battle
          .e('createBattle:failed', error: e, stack: s);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Recurring Daily series — migration 0014
  //
  // A Daily battle is a recurring series: one `battle_series` row + one
  // `battles` row for today, linked via `series_id`. When today's battle
  // completes, the server cron (migration 0008) spawns tomorrow's instance
  // from `battle_series_participants` until the creator calls [stopSeries].
  // ---------------------------------------------------------------------------

  /// Create a recurring **Daily** battle series + its first instance for
  /// today. Returns the new instance's battle id (same shape as
  /// [createBattle] so the caller can navigate to it).
  ///
  /// The first instance behaves identically to a regular battle (the picker
  /// already snaps start = now / end = today 23:59:59 local). The recurring
  /// behavior kicks in only AFTER the first instance completes — at which
  /// point the cron clones the roster forward day-over-day.
  Future<({String battleId, String joinCode})> createDailySeries({
    required BattleType type,
    required List<BattleParticipant> participants,
    required DateTime startTime,
    required DateTime endTime,
    required String createdBy,
    BattleVisibility visibility = BattleVisibility.private,
  }) async {
    if (!endTime.isAfter(startTime)) {
      throw ArgumentError('endTime must be after startTime');
    }
    final xp = type == BattleType.oneVsOne
        ? AppConstants.xpWin1v1
        : AppConstants.xpWinGroup;
    final tzOffsetMin = DateTime.now().timeZoneOffset.inMinutes;
    final joinCode = _generateJoinCode();

    try {
      // 1. Insert the series row.
      final seriesRow = await _supabase.from('battle_series').insert({
        'type': type == BattleType.oneVsOne ? '1v1' : 'group',
        'status': 'active',
        'created_by': createdBy,
        'tz_offset_minutes': tzOffsetMin,
        'xp_reward': xp,
      }).select('id').single();
      final seriesId = seriesRow['id'] as String;

      // 2. Cache the roster so the cron can replay it daily without needing
      //    fresh invites.
      final seriesParticipantRows = participants.map((p) => {
            'series_id': seriesId,
            'user_id': p.userId,
            'display_name': p.displayName,
            'avatar_url': p.avatarURL,
          }).toList();
      await _supabase
          .from('battle_series_participants')
          .insert(seriesParticipantRows);

      // 3. First instance — same row shape as a regular pending battle,
      //    with series_id wired.
      final battleRow = await _supabase
          .from('battles')
          .insert({
            'type': type == BattleType.oneVsOne ? '1v1' : 'group',
            'status': 'pending',
            'start_time': startTime.toUtc().toIso8601String(),
            'end_time': endTime.toUtc().toIso8601String(),
            'xp_reward': xp,
            'created_by': createdBy,
            'series_id': seriesId,
            'visibility': visibility == BattleVisibility.public
                ? 'public'
                : 'private',
            'join_code': joinCode,
          })
          .select('id')
          .single();
      final battleId = battleRow['id'] as String;

      // 4. Per-participant rows for the first instance. Creator is auto-
      //    accepted; everyone else is pending until they tap accept (their
      //    acceptance covers ALL future instances of this series).
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

      AppLogger.battle.i('createDailySeries', fields: {
        'seriesId': seriesId,
        'firstBattleId': battleId,
        'type': type.name,
        'createdBy': createdBy,
        'participantCount': participants.length,
        'tzOffsetMin': tzOffsetMin,
        'visibility': visibility.name,
        'joinCode': joinCode,
      });

      // 5. Notify invitees — copy template from createBattle, just flagged
      //    as a Daily series so they know it's recurring.
      final creator = participants.firstWhere((p) => p.userId == createdBy);
      for (final p in participants) {
        if (p.userId == createdBy) continue;
        await _supabase.from('notifications').insert({
          'user_id': p.userId,
          'type': 'battle_invite',
          'title': 'Daily Battle Invite',
          'body':
              '${creator.displayName} challenged you to a daily step battle (every day until stopped)',
          'data': {
            'battle_id': battleId,
            'series_id': seriesId,
            'from_user_id': createdBy,
            'recurring': 'daily',
          },
        });
      }

      return (battleId: battleId, joinCode: joinCode);
    } catch (e, s) {
      AppLogger.battle
          .e('createDailySeries:failed', error: e, stack: s);
      rethrow;
    }
  }

  /// Stop a Daily series — current/scheduled instance still runs to
  /// completion, but no future instances get spawned by the cron. RLS
  /// (`battle_series_update_creator`) restricts this to the series creator.
  Future<void> stopSeries(String seriesId) async {
    try {
      await _supabase.from('battle_series').update({
        'status': 'stopped',
        'stopped_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', seriesId);
      AppLogger.battle
          .i('stopSeries', fields: {'seriesId': seriesId});
    } catch (e, s) {
      AppLogger.battle.e('stopSeries:failed',
          fields: {'seriesId': seriesId}, error: e, stack: s);
      rethrow;
    }
  }

  /// Returns the series's status (`active` / `stopped`) or null when the
  /// row doesn't exist. Used by the battle card to decide whether to render
  /// the "Stop recurring" action.
  Future<String?> getSeriesStatus(String seriesId) async {
    try {
      final row = await _supabase
          .from('battle_series')
          .select('status')
          .eq('id', seriesId)
          .maybeSingle();
      return row?['status'] as String?;
    } catch (_) {
      return null;
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
      // Stake deduction (migration 0016): if the battle has a non-zero
      // stake_xp and this participant hasn't yet paid, charge it via
      // credit_user_xp. Done BEFORE marking accepted so a failure here
      // (insufficient XP) keeps the participant in pending status.
      final preBattle = await _fetchBattleStakeOnly(battleId);
      final stake = preBattle?.stakeXp ?? 0;
      if (stake > 0) {
        await _chargeStake(
          battleId: battleId,
          userId: userId,
          stake: stake,
        );
      }

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

      // Team battles activate only when the creator hits Start — accept just
      // makes you eligible, you can still switch teams while pending.
      if (battle.type == BattleType.team) return;

      final allAccepted = battle.participants.every(
          (p) => p.inviteStatus == ParticipantInviteStatus.accepted);
      if (!allAccepted) return;

      // PRIVATE battles: the creator-chosen start_time is overridden by
      // the moment of full acceptance. End time stays absolute (per
      // user spec) — so accepting late just shortens the battle window,
      // it doesn't extend it.
      //
      // PUBLIC battles: keep the creator's chosen start_time exactly so
      // anyone discovering the battle in /battles/discover sees the
      // same scheduled window regardless of who joins when.
      if (battle.visibility == BattleVisibility.private) {
        final now = DateTime.now();
        if (battle.endTime.isAfter(now)) {
          // Snap start_time to NOW and activate immediately.
          await _supabase.from('battles').update({
            'start_time': now.toUtc().toIso8601String(),
          }).eq('id', battleId);
          // Re-fetch so _activateBattle sees the new start_time.
          final refreshed = await _fetchBattle(battleId);
          if (refreshed != null) {
            await _activateBattle(refreshed);
          }
          AppLogger.battle.i('acceptInvite:privateAcceptStart', fields: {
            'battleId': battleId,
            'snappedStart': now.toIso8601String(),
            'endTime': battle.endTime.toIso8601String(),
          });
          return;
        }
        // End_time has already passed by the time invite was accepted —
        // cancel the battle and refund stakes so the user isn't left
        // with a phantom battle they "joined" too late.
        AppLogger.battle.w('acceptInvite:privateEndExpired',
            fields: {'battleId': battleId});
        await refundAllStakes(battleId);
        await _supabase
            .from('battles')
            .update({'status': 'cancelled'}).eq('id', battleId);
        return;
      }

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
        // 1v1 — reject cancels the whole battle. Refund any paid stakes
        // (in a 1v1 typically only the creator has paid by this point;
        // the invitee hasn't accepted so no stake from them).
        await refundAllStakes(battleId);
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
          .select('*, battle_participants(*), battle_teams(*)')
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
  /// Any participants who already paid their stake get refunded.
  Future<void> cancelBattle(String battleId) async {
    await refundAllStakes(battleId);
    await _supabase
        .from('battles')
        .update({'status': 'cancelled'})
        .eq('id', battleId)
        .eq('status', 'pending');
  }

  /// Delete a pending battle. Marks cancelled, refunds any paid stakes,
  /// and clears battle_invite notifications.
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

    await refundAllStakes(battleId);
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
        .select('*, battle_participants(*), battle_teams(*)')
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
        .select('*, battle_participants(*), battle_teams(*)')
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
        .select('*, battle_participants(*), battle_teams(*)')
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
              .select('*, battle_participants(*), battle_teams(*)')
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

  // ---------------------------------------------------------------------------
  // Team battles — migration 0015
  //
  // A team battle is a lobby-first format: creator picks duration + visibility
  // + initial teams, invitees accept and can hop between teams while the
  // battle is `pending`, then the creator clicks Start to lock the roster,
  // drop pending invitees, and activate. Scoring sums each team's
  // `current_steps`; the winning team's members each get `xp_reward × team_size`
  // XP (settled by the cron in `process_battle_lifecycle`).
  // ---------------------------------------------------------------------------

  /// Create an empty team-battle **lobby** in pending state.
  ///
  /// Draft-first: the row hits Supabase the moment the team setup sheet opens
  /// so the `join_code` is immediately shareable + the creator can rename
  /// teams / add players / etc. and have those edits land on the server.
  /// If the creator dismisses the sheet without tapping **Create**, the sheet
  /// calls [deleteDraftBattle] to hard-delete the row. If they DO tap Create
  /// we call [fanoutTeamLobbyInvites] to ping invitees and the row stays.
  Future<({String battleId, String joinCode})> createTeamLobby({
    required String createdBy,
    required String creatorDisplayName,
    String? creatorAvatarUrl,
  }) async {
    final xp = AppConstants.xpWinClanBattle;
    final joinCode = _generateJoinCode();
    // Placeholder window — overwritten by setBattleWindow as soon as the
    // duration picker fires its first onChanged.
    final now = DateTime.now();
    final placeholderEnd = now.add(const Duration(days: 1));

    try {
      final battleRow = await _supabase
          .from('battles')
          .insert({
            'type': 'team',
            'status': 'pending',
            'start_time': now.toUtc().toIso8601String(),
            'end_time': placeholderEnd.toUtc().toIso8601String(),
            'xp_reward': xp,
            'created_by': createdBy,
            'team_count': 2,
            'visibility': 'private',
            'join_code': joinCode,
          })
          .select('id')
          .single();
      final battleId = battleRow['id'] as String;

      await _supabase.from('battle_participants').insert({
        'battle_id': battleId,
        'user_id': createdBy,
        'display_name': creatorDisplayName,
        'avatar_url': creatorAvatarUrl,
        'current_steps': 0,
        'is_winner': false,
        'invite_status': 'accepted',
        'team_label': 'A',
      });

      await _supabase.from('battle_teams').insert([
        {'battle_id': battleId, 'team_label': 'A', 'team_name': null},
        {'battle_id': battleId, 'team_label': 'B', 'team_name': null},
      ]);

      AppLogger.battle.i('createTeamLobby', fields: {
        'battleId': battleId,
        'createdBy': createdBy,
        'joinCode': joinCode,
      });

      return (battleId: battleId, joinCode: joinCode);
    } catch (e, s) {
      AppLogger.battle.e('createTeamLobby:failed', error: e, stack: s);
      rethrow;
    }
  }

  /// Hard-delete a draft battle (sheet dismissed without Create). Relies on
  /// ON DELETE CASCADE on battle_participants and battle_teams to clean up
  /// the child rows. Fire-and-forget from the sheet's dispose() path.
  Future<void> deleteDraftBattle(String battleId) async {
    try {
      await _supabase.from('battles').delete().eq('id', battleId);
      AppLogger.battle.i('deleteDraftBattle',
          fields: {'battleId': battleId});
    } catch (e, s) {
      AppLogger.battle.e('deleteDraftBattle:failed',
          fields: {'battleId': battleId}, error: e, stack: s);
      // Swallow — we're called from dispose; can't surface anything useful
      // and the 24h cancelExpiredPendingBattles sweep will handle it.
    }
  }

  Future<void> setBattleTeamCount({
    required String battleId,
    required int count,
  }) async {
    if (count < 2 || count > 4) {
      throw ArgumentError('teamCount must be 2–4');
    }
    final liveLabels = List.generate(
      count,
      (i) => String.fromCharCode('A'.codeUnitAt(0) + i),
    );
    const allLabels = ['A', 'B', 'C', 'D'];

    await _supabase
        .from('battles')
        .update({'team_count': count}).eq('id', battleId);

    for (final old in allLabels) {
      if (liveLabels.contains(old)) continue;
      await _supabase
          .from('battle_participants')
          .update({'team_label': 'A'})
          .eq('battle_id', battleId)
          .eq('team_label', old);
      await _supabase
          .from('battle_teams')
          .delete()
          .eq('battle_id', battleId)
          .eq('team_label', old);
    }

    final newRows = liveLabels
        .map((l) => {
              'battle_id': battleId,
              'team_label': l,
              'team_name': null,
            })
        .toList();
    await _supabase.from('battle_teams').upsert(
          newRows,
          onConflict: 'battle_id,team_label',
          ignoreDuplicates: true,
        );
  }

  Future<void> setBattleVisibility({
    required String battleId,
    required BattleVisibility visibility,
  }) async {
    await _supabase.from('battles').update({
      'visibility':
          visibility == BattleVisibility.public ? 'public' : 'private',
    }).eq('id', battleId);
  }

  Future<void> setBattleWindow({
    required String battleId,
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    if (!endTime.isAfter(startTime)) {
      throw ArgumentError('endTime must be after startTime');
    }
    await _supabase.from('battles').update({
      'start_time': startTime.toUtc().toIso8601String(),
      'end_time': endTime.toUtc().toIso8601String(),
    }).eq('id', battleId);
  }

  Future<void> addTeamLobbyParticipants({
    required String battleId,
    required List<({String userId, String displayName, String? avatarUrl, String teamLabel})>
        entries,
  }) async {
    if (entries.isEmpty) return;
    final rows = entries
        .map((e) => {
              'battle_id': battleId,
              'user_id': e.userId,
              'display_name': e.displayName,
              'avatar_url': e.avatarUrl,
              'current_steps': 0,
              'is_winner': false,
              'invite_status': 'pending',
              'team_label': e.teamLabel,
            })
        .toList();
    await _supabase.from('battle_participants').insert(rows);
  }

  Future<void> removeTeamLobbyParticipant({
    required String battleId,
    required String userId,
  }) async {
    await _supabase
        .from('battle_participants')
        .delete()
        .eq('battle_id', battleId)
        .eq('user_id', userId);
  }

  /// Sends the "you've been added" notification to every pending invitee in
  /// the lobby. Called when the creator taps **Create** in the sheet.
  Future<void> fanoutTeamLobbyInvites({required String battleId}) async {
    final battle = await _fetchBattle(battleId);
    if (battle == null) return;
    if (battle.type != BattleType.team) return;
    final creator = battle.participants.firstWhere(
      (p) => p.userId == battle.createdBy,
      orElse: () => battle.participants.first,
    );
    final teamCount = battle.teamCount ?? battle.teamLabels.length;
    for (final p in battle.participants) {
      if (p.userId == battle.createdBy) continue;
      if (p.inviteStatus != ParticipantInviteStatus.pending) continue;
      await _supabase.from('notifications').insert({
        'user_id': p.userId,
        'type': 'battle_invite',
        'title': 'Team Battle Invite',
        'body':
            '${creator.displayName} added you to a $teamCount-team step battle',
        'data': {
          'battle_id': battleId,
          'from_user_id': battle.createdBy,
          'team_label': p.teamLabel,
        },
      });
    }
    AppLogger.battle.i('fanoutTeamLobbyInvites', fields: {
      'battleId': battleId,
      'recipients': battle.participants
          .where((p) =>
              p.userId != battle.createdBy &&
              p.inviteStatus == ParticipantInviteStatus.pending)
          .length,
    });
  }

  /// Creator hits Start: drop pending invitees, lock the roster, activate.
  /// The new window is `[now, now + (originalEnd - originalStart)]` so the
  /// duration the creator picked at creation is preserved verbatim even if
  /// they waited a while to start.
  Future<void> startTeamBattle({
    required String battleId,
    required String actorId,
  }) async {
    final battle = await _fetchBattle(battleId);
    if (battle == null) throw StateError('Battle not found');
    if (battle.createdBy != actorId) {
      throw StateError('Only the creator can start a team battle.');
    }
    if (battle.type != BattleType.team) {
      throw StateError('startTeamBattle only applies to team battles.');
    }
    if (battle.status != BattleStatus.pending) {
      throw StateError('Battle is no longer in lobby state.');
    }
    final accepted = battle.participants
        .where((p) => p.inviteStatus == ParticipantInviteStatus.accepted)
        .toList();
    if (accepted.length < 2) {
      throw StateError('Need at least 2 accepted players to start.');
    }
    // Need at least 2 teams with at least 1 accepted member each.
    final teamsWithMembers = <String>{
      for (final p in accepted)
        if (p.teamLabel != null) p.teamLabel!,
    };
    if (teamsWithMembers.length < 2) {
      throw StateError('Need at least 2 teams with players to start.');
    }

    // Drop anyone still pending.
    await _supabase
        .from('battle_participants')
        .update({'invite_status': 'rejected'})
        .eq('battle_id', battleId)
        .eq('invite_status', 'pending');

    // Rewrite window so the user-picked duration runs from this moment.
    final duration = battle.endTime.difference(battle.startTime);
    final newStart = DateTime.now();
    final newEnd = newStart.add(duration);
    await _supabase.from('battles').update({
      'start_time': newStart.toUtc().toIso8601String(),
      'end_time': newEnd.toUtc().toIso8601String(),
    }).eq('id', battleId);

    // Re-fetch with new times then activate via shared path.
    final refreshed = await _fetchBattle(battleId);
    if (refreshed == null) return;
    await _activateBattle(refreshed);

    AppLogger.battle.i('startTeamBattle', fields: {
      'battleId': battleId,
      'actorId': actorId,
      'accepted': accepted.length,
      'durationMin': duration.inMinutes,
    });
  }

  /// Self-serve team switch while the battle is pending. Anyone in the battle
  /// can move themselves; the creator can move anyone (via the [targetUserId]
  /// param — defaults to [actorId]).
  Future<void> switchTeam({
    required String battleId,
    required String actorId,
    required String teamLabel,
    String? targetUserId,
  }) async {
    final battle = await _fetchBattle(battleId);
    if (battle == null) throw StateError('Battle not found');
    if (battle.status != BattleStatus.pending) {
      throw StateError('Can only switch teams before the battle starts.');
    }
    final target = targetUserId ?? actorId;
    if (target != actorId && battle.createdBy != actorId) {
      throw StateError('Only the creator can move other players.');
    }
    if (!battle.teamLabels.contains(teamLabel) &&
        teamLabel != 'A' &&
        teamLabel != 'B' &&
        teamLabel != 'C' &&
        teamLabel != 'D') {
      throw ArgumentError('Invalid team label: $teamLabel');
    }
    await _supabase
        .from('battle_participants')
        .update({'team_label': teamLabel})
        .eq('battle_id', battleId)
        .eq('user_id', target);

    AppLogger.battle.i('switchTeam', fields: {
      'battleId': battleId,
      'actorId': actorId,
      'targetUserId': target,
      'teamLabel': teamLabel,
    });
  }

  /// Rename a team. Creator-only (enforced server-side by RLS on
  /// `battle_teams`).
  Future<void> renameTeam({
    required String battleId,
    required String teamLabel,
    required String newName,
  }) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed.length > 40) {
      throw ArgumentError('Team name must be 1–40 characters.');
    }
    await _supabase.from('battle_teams').upsert(
      {
        'battle_id': battleId,
        'team_label': teamLabel,
        'team_name': trimmed,
      },
      onConflict: 'battle_id,team_label',
    );
  }

  /// Join a battle via its 6-char shareable code (Q15). Works for both public
  /// and private battles — possessing the code is the consent token (Q14).
  ///
  /// For team battles, places the new participant on the smallest team so the
  /// lobby stays balanced; they can call [switchTeam] afterward if they want.
  Future<String> joinByCode({
    required String code,
    required String userId,
    required String displayName,
    String? avatarUrl,
  }) async {
    final normalized = code.trim().toUpperCase();
    if (normalized.length != 6) {
      throw ArgumentError('Join code must be 6 characters.');
    }
    final raw = await _supabase
        .from('battles')
        .select('*, battle_participants(*), battle_teams(*)')
        .eq('join_code', normalized)
        .maybeSingle();
    if (raw == null) throw StateError('No battle found for that code.');
    final battle = BattleModel.fromSupabaseRow(raw);

    if (battle.status == BattleStatus.completed ||
        battle.status == BattleStatus.cancelled) {
      throw StateError('That battle is already over.');
    }
    if (battle.status == BattleStatus.active) {
      throw StateError('That battle is in progress — late joins are off.');
    }

    final existing = battle.participantFor(userId);
    if (existing != null &&
        existing.inviteStatus != ParticipantInviteStatus.rejected) {
      return battle.battleId; // already in (idempotent)
    }

    // Capacity check (Q2: 10 max for multi-player / team, 2 for 1v1).
    final acceptedOrPending = battle.participants
        .where((p) => p.inviteStatus != ParticipantInviteStatus.rejected)
        .length;
    final cap = battle.type == BattleType.oneVsOne ? 2 : 10;
    if (acceptedOrPending >= cap) {
      throw StateError('Battle is full.');
    }

    String? teamLabel;
    if (battle.type == BattleType.team) {
      // Drop into the smallest team for balance.
      final counts = <String, int>{};
      for (final l in battle.teamLabels) {
        counts[l] = 0;
      }
      for (final p in battle.participants) {
        if (p.teamLabel == null) continue;
        if (p.inviteStatus == ParticipantInviteStatus.rejected) continue;
        counts[p.teamLabel!] = (counts[p.teamLabel!] ?? 0) + 1;
      }
      teamLabel = counts.entries
          .reduce((a, b) => a.value <= b.value ? a : b)
          .key;
    }

    final row = {
      'battle_id': battle.battleId,
      'user_id': userId,
      'display_name': displayName,
      'avatar_url': avatarUrl,
      'current_steps': 0,
      'is_winner': false,
      // Code possession = consent to play. Auto-accept.
      'invite_status': 'accepted',
      if (teamLabel != null) 'team_label': teamLabel,
    };
    if (existing == null) {
      await _supabase.from('battle_participants').insert(row);
    } else {
      // Re-joining after a prior reject — flip back to accepted in place.
      await _supabase
          .from('battle_participants')
          .update(row)
          .eq('battle_id', battle.battleId)
          .eq('user_id', userId);
    }

    AppLogger.battle.i('joinByCode', fields: {
      'battleId': battle.battleId,
      'userId': userId,
      'type': battle.type.name,
      'teamLabel': teamLabel,
    });
    return battle.battleId;
  }

  /// Public lobby list for the Discover tab (Q10). Returns pending public
  /// battles plus a 24h-window of active public battles flagged "Full" so
  /// users see what just kicked off (Q12). Excludes battles the user is
  /// already in.
  Future<List<BattleModel>> getPublicBattles({required String userId}) async {
    final cutoff = DateTime.now()
        .subtract(const Duration(hours: 24))
        .toUtc()
        .toIso8601String();
    final rows = await _supabase
        .from('battles')
        .select('*, battle_participants(*), battle_teams(*)')
        .eq('visibility', 'public')
        .inFilter('status', ['pending', 'active'])
        .gte('created_at', cutoff)
        .order('created_at', ascending: false);
    return (rows as List)
        .map((r) =>
            BattleModel.fromSupabaseRow(r as Map<String, dynamic>))
        .where((b) => !b.participants.any((p) => p.userId == userId))
        .toList();
  }

  /// 6-char join code from a 30-character, ambiguity-free alphabet (no
  /// 0/O/I/1). Collision probability at realistic scale is vanishing; on
  /// the rare clash the unique-constraint INSERT will throw and the caller
  /// can retry by calling create again.
  static String _generateJoinCode() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = Random();
    return String.fromCharCodes(
      Iterable.generate(6,
          (_) => alphabet.codeUnitAt(rng.nextInt(alphabet.length))),
    );
  }

  /// Public wrapper around the internal fetch — used by sheets/screens that
  /// want a one-shot read of a battle after creating/joining it (e.g. to
  /// surface the join code or render the lobby).
  Future<BattleModel?> getBattle(String battleId) => _fetchBattle(battleId);

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
              .select('*, battle_participants(*), battle_teams(*)')
              .eq('status', 'pending')
              .inFilter('id', pendingIds);
          return (battlesRaw as List)
              .map((b) => BattleModel.fromSupabaseRow(
                  b as Map<String, dynamic>))
              .toList();
        });
  }

  // ---------------------------------------------------------------------------
  // Stake helpers (migration 0016 / 0017)
  // ---------------------------------------------------------------------------

  /// Light fetch that only pulls `stake_xp` — used inside [acceptInvite] so
  /// we don't drag the full participant tree just to read the stake.
  Future<_StakeInfo?> _fetchBattleStakeOnly(String battleId) async {
    final row = await _supabase
        .from('battles')
        .select('stake_xp')
        .eq('id', battleId)
        .maybeSingle();
    if (row == null) return null;
    return _StakeInfo(stakeXp: (row['stake_xp'] as num?)?.toInt() ?? 0);
  }

  /// Deducts the per-participant stake via the `credit_user_xp` SECURITY
  /// DEFINER function and flags `stake_paid = true` so a re-accept doesn't
  /// double-charge. Throws if the user has insufficient XP balance.
  Future<void> _chargeStake({
    required String battleId,
    required String userId,
    required int stake,
  }) async {
    // Read the user's current balance to fail fast with a clean error
    // message; the SECURITY DEFINER function would clamp at zero
    // otherwise, leaving the user thinking they joined while the pot
    // didn't actually grow.
    final profile = await _supabase
        .from('profiles')
        .select('total_xp')
        .eq('id', userId)
        .maybeSingle();
    final balance = (profile?['total_xp'] as num?)?.toInt() ?? 0;
    if (balance < stake) {
      throw const InsufficientXpException();
    }

    // Skip if already paid (re-accept after a retry / accidental tap).
    final part = await _supabase
        .from('battle_participants')
        .select('stake_paid')
        .eq('battle_id', battleId)
        .eq('user_id', userId)
        .maybeSingle();
    if (part?['stake_paid'] == true) return;

    await _supabase.rpc('credit_user_xp', params: {
      'p_user_id': userId,
      'p_delta': -stake,
      'p_reason': 'battle_stake',
      'p_context': {'battle_id': battleId},
    });
    await _supabase
        .from('battle_participants')
        .update({'stake_paid': true})
        .eq('battle_id', battleId)
        .eq('user_id', userId);
  }

  /// Refund every paid-up participant. Called when a pending battle is
  /// cancelled by the creator OR rejected in a way that ends the battle
  /// (1v1 reject, last invitee dropping). Idempotent via stake_paid flag.
  Future<void> refundAllStakes(String battleId) async {
    final rows = await _supabase
        .from('battle_participants')
        .select('user_id, stake_paid')
        .eq('battle_id', battleId)
        .eq('stake_paid', true);

    final battle = await _fetchBattleStakeOnly(battleId);
    final stake = battle?.stakeXp ?? 0;
    if (stake <= 0) return;

    for (final r in rows as List) {
      final uid = (r as Map)['user_id'] as String;
      await _supabase.rpc('credit_user_xp', params: {
        'p_user_id': uid,
        'p_delta': stake,
        'p_reason': 'battle_refund',
        'p_context': {'battle_id': battleId},
      });
      await _supabase
          .from('battle_participants')
          .update({'stake_paid': false})
          .eq('battle_id', battleId)
          .eq('user_id', uid);
    }
  }
}

class _StakeInfo {
  final int stakeXp;
  const _StakeInfo({required this.stakeXp});
}

/// Thrown by [BattleService.acceptInvite] (and similar stake-entry paths)
/// when the user's `profiles.total_xp` balance is below the battle's
/// `stake_xp`. UI catches this and surfaces a "Not enough XP — buy more"
/// prompt instead of a generic error.
class InsufficientXpException implements Exception {
  const InsufficientXpException();
  @override
  String toString() => 'Not enough XP. Buy XP to join.';
}
