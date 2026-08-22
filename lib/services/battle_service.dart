import 'dart:math';

import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/constants.dart';
import '../models/battle_model.dart';
import '../utils/app_logger.dart';
import '../utils/stream_debounce.dart';
import 'observability_service.dart';
// XPService + MissionService imports removed in 1.1.6+29 alongside
// completeExpiredBattles / _propagateBattleWinToMissions — those
// were the only consumers on this file. Server-side settle_stake_battle
// owns the credit path now; mission bumping for stake wins is
// tracked as a follow-up migration (see the block comment on
// completeExpiredBattles below).

/// Outcome of an `acceptInvite` call — lets the caller adjust its UX
/// based on what actually happened. The only branch that needs a
/// distinct message is daily-series, so callers can surface a light
/// "You're in!" confirmation alongside the realtime Home update.
enum AcceptInviteOutcome {
  /// Regular 1v1 / group / team accept — the invitee is competing in
  /// this battle (either immediately or via snap-to-active).
  regular,

  /// Daily-series accept via `accept_daily_series_invite` RPC (migration
  /// 0057). Both users now compete from the moment of accept until end
  /// of the invitee's local today; the invitee's `battle_participants`
  /// row is UPDATED (not deleted as in 0056) with baseline captured at
  /// accept-time so they only get credit for post-accept steps. Home
  /// list updates via realtime; caller optionally shows a SnackBar for
  /// action acknowledgement.
  dailySeriesFirstJoin,
}

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

  BattleService({SupabaseClient? supabase})
      : _supabase = supabase ?? Supabase.instance.client;

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
    // v2 economy — free-play battles are no longer allowed. Every
    // battle MUST have a stake ≥ `minBattleStakeXp` (100) so the
    // pot-based payout is always in play.
    if (stakeXp < AppConstants.minBattleStakeXp) {
      throw ArgumentError(
          'Minimum stake is ${AppConstants.minBattleStakeXp} XP.');
    }
    final joinCode = _generateJoinCode();

    try {
      // 1. Insert the battle row with the user-chosen window.
      //    `xp_reward` is the LEGACY per-side prize; kept at 0 for
      //    every battle now that stake mode is mandatory. `stake_xp`
      //    is the sole source of truth for payout — migration 0017's
      //    settle_stake_battle() splits the pot to the winner.
      final battleRow = await _supabase
          .from('battles')
          .insert({
            'type': type == BattleType.oneVsOne ? '1v1' : 'group',
            'status': 'pending',
            'start_time': startTime.toUtc().toIso8601String(),
            'end_time': endTime.toUtc().toIso8601String(),
            'xp_reward': 0,
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
            .from('profiles_public')
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
          'preferred_name': p.preferredName,
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
      // Product analytics — deliberately excludes user-identifying fields
      // (createdBy is opaque; joinCode is a short random string). Type +
      // participant count + stake drive the funnel/retention dashboards.
      ObservabilityService.trackEvent('battle_create', properties: {
        'type': type.name,
        'participant_count': participants.length,
        'stake_xp': stakeXp,
        'visibility': visibility.name,
        'duration_hours':
            endTime.difference(startTime).inHours,
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
  // Recurring Daily series — migration 0014 (base) + 0046 (per-user local
  // windows) + 0047 (helper reroute).
  //
  // A Daily battle is a recurring series: one `battle_series` row + one
  // `battles` row per day, linked via `series_id`. Each participant scores
  // on THEIR local calendar day (via `profiles.tz_offset_minutes`); the
  // server-side `settle_daily_battle` RPC settles when the SLOWEST
  // participant's local 23:59 has passed, distributes the pot, drops
  // anyone who can't afford tomorrow's stake, and spawns tomorrow's
  // instance for the still-active roster. Series ends when active
  // participants drops below 2. Creator can also stop via [stopSeries].
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
    int stakeXp = AppConstants.minBattleStakeXp,
    BattleVisibility visibility = BattleVisibility.private,
  }) async {
    if (!endTime.isAfter(startTime)) {
      throw ArgumentError('endTime must be after startTime');
    }
    // Recurring series follow the same v2 stake floor as one-off
    // battles — every daily instance must pay through the pot.
    if (stakeXp < AppConstants.minBattleStakeXp) {
      throw ArgumentError(
          'Minimum stake is ${AppConstants.minBattleStakeXp} XP.');
    }
    final tzOffsetMin = DateTime.now().timeZoneOffset.inMinutes;
    final joinCode = _generateJoinCode();

    // Creator's local calendar date — the day the creator is competing on
    // for day-1 of this series. Per Q1=B, invitees SKIP day 1 (they only
    // enter from their own local tomorrow after accepting), so only the
    // creator gets a competing_date on the day-1 battle_participants row.
    final creatorLocalToday =
        DateFormat('yyyy-MM-dd').format(DateTime.now());

    try {
      // 1. Series row — now carries stake_xp so the settlement cron
      //    knows how much to charge each accepted participant per spawn.
      final seriesRow = await _supabase.from('battle_series').insert({
        'type': type == BattleType.oneVsOne ? '1v1' : 'group',
        'status': 'active',
        'created_by': createdBy,
        'tz_offset_minutes': tzOffsetMin,
        'xp_reward': 0,
        'stake_xp': stakeXp,
      }).select('id').single();
      final seriesId = seriesRow['id'] as String;

      // Snapshot each participant's currently-selected battle avatar
      // (migration 0019 pattern) so tomorrow-spawned instances render
      // the runner the invitee actually chose — not the hardcoded
      // avatar_01 default that the earlier version wrote to every
      // series_participants row. Best-effort; missing rows fall back
      // to avatar_01.
      final avatarById = <String, String>{};
      try {
        final rows = await _supabase
            .from('profiles_public')
            .select('id, battle_avatar_id')
            .inFilter('id', participants.map((p) => p.userId).toList());
        for (final r in rows as List) {
          final m = r as Map<String, dynamic>;
          avatarById[m['id'] as String] =
              (m['battle_avatar_id'] as String?) ?? 'avatar_01';
        }
      } catch (e) {
        // Non-fatal — a transient profiles read shouldn't block series
        // creation. Every row falls back to avatar_01 below.
        AppLogger.battle.w('createDailySeries:avatar_snapshot_failed',
            fields: {'err': e.toString()});
      }

      // 2. Roster template — includes creator (status='active',
      //    accepted_at now) plus every invitee (status='pending_invite').
      //    On accept, invitee flips to 'active' and joins from their own
      //    local tomorrow via the settle_daily_battle spawn path.
      final nowUtcIso = DateTime.now().toUtc().toIso8601String();
      final seriesParticipantRows = participants.map((p) {
        final isCreator = p.userId == createdBy;
        return {
          'series_id': seriesId,
          'user_id': p.userId,
          'display_name': p.displayName,
          'preferred_name': p.preferredName,
          'avatar_url': p.avatarURL,
          'battle_avatar_id': avatarById[p.userId] ?? 'avatar_01',
          'status': isCreator ? 'active' : 'pending_invite',
          'accepted_at': isCreator ? nowUtcIso : null,
        };
      }).toList();
      await _supabase
          .from('battle_series_participants')
          .insert(seriesParticipantRows);

      // 3. First instance. status='pending' — the battle waits until at
      //    least one invitee accepts, matching non-daily createBattle
      //    behaviour. The prior code marked this 'active' immediately,
      //    which surfaced "You vs <invitee>" as a live battle on the
      //    creator's Home tab (with auto-nav to the arena via
      //    battleActivationDetector) BEFORE the invitee had ever seen
      //    the invite — confusing UX. Now the flow mirrors non-daily
      //    1v1: creator sees a pending invite until acceptance flips
      //    the status to 'active' in [acceptInvite]'s daily branch.
      final battleRow = await _supabase
          .from('battles')
          .insert({
            'type': type == BattleType.oneVsOne ? '1v1' : 'group',
            'status': 'pending',
            'start_time': startTime.toUtc().toIso8601String(),
            'end_time': endTime.toUtc().toIso8601String(),
            'xp_reward': 0,
            'stake_xp': stakeXp,
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

      // 4. Per-instance participant rows.
      //    - Creator: invite_status='accepted', competing_date set → they
      //      play today and are scored via settle_daily_battle.
      //    - Invitees: invite_status='pending', competing_date NULL →
      //      surface in Incoming Invites, but excluded from today's
      //      scoring. On accept, their pending row is deleted and they
      //      join from tomorrow via the spawn path.
      final participantRows = participants.map((p) {
        final isCreator = p.userId == createdBy;
        return {
          'battle_id': battleId,
          'user_id': p.userId,
          'display_name': p.displayName,
          'preferred_name': p.preferredName,
          'avatar_url': p.avatarURL,
          'current_steps': 0,
          'is_winner': false,
          'invite_status': isCreator ? 'accepted' : 'pending',
          'competing_date': isCreator ? creatorLocalToday : null,
        };
      }).toList();
      await _supabase.from('battle_participants').insert(participantRows);

      // 5. Charge the creator's day-1 stake immediately. Same rationale
      //    as createBattle — they're auto-accepted, they're committed.
      //    Bug fix: previously createDailySeries never charged them.
      if (stakeXp > 0) {
        await _chargeStake(
          battleId: battleId,
          userId: createdBy,
          stake: stakeXp,
        );
      }

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

  Future<AcceptInviteOutcome> acceptInvite({
    required String battleId,
    required String userId,
  }) async {
    AppLogger.battle.i('acceptInvite',
        fields: {'battleId': battleId, 'userId': userId});
    try {
      // Daily-series branch: both users compete from the moment of
      // accept until end of the invitee's local today. All writes
      // (series roster → active, invitee row → accepted with baseline,
      // battle → active, realtime touch on creator's row) go through
      // ONE SECURITY DEFINER RPC — see migration 0057.
      //
      // History:
      //   • 1.1.6+19 and earlier — 3 raw PostgREST writes, two silently
      //     failed under RLS (battle_series_participants creator-only
      //     policy, no `battles` table subscription for realtime).
      //     Series died silently on day 2.
      //   • 1.1.6+20 (Migration 0056) — server RPC bypassing RLS, but
      //     kept the "late-joiner skips day 1" pattern by DELETING the
      //     invitee's participant row. Symptoms: invitee saw no
      //     battle in Home, creator's card said "You vs Opponent",
      //     creator "won" solo at midnight.
      //   • 1.1.6+22 (Migration 0057) — RPC UPDATEs the invitee row
      //     instead of deleting it. Both users visible and competing
      //     from now. Baseline captured at accept-time so it's fair.
      final preBattle = await _fetchBattle(battleId);
      final isDailySeries = preBattle?.seriesId != null;
      if (isDailySeries) {
        await _supabase.rpc(
          'accept_daily_series_invite',
          params: {'p_battle_id': battleId},
        );
        AppLogger.battle.i('acceptInvite:dailySeriesActivated',
            fields: {'battleId': battleId, 'accepterUid': userId});
        return AcceptInviteOutcome.dailySeriesFirstJoin;
      }

      // Stake deduction (migration 0016): if the battle has a non-zero
      // stake_xp and this participant hasn't yet paid, charge it via
      // credit_user_xp. Done BEFORE marking accepted so a failure here
      // (insufficient XP) keeps the participant in pending status.
      final stakeInfo = await _fetchBattleStakeOnly(battleId);
      final stake = stakeInfo?.stakeXp ?? 0;
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
      if (battle == null) return AcceptInviteOutcome.regular;
      if (battle.status != BattleStatus.pending) return AcceptInviteOutcome.regular;

      // Team battles activate only when the creator hits Start — accept just
      // makes you eligible, you can still switch teams while pending.
      if (battle.type == BattleType.team) return AcceptInviteOutcome.regular;

      // 1v1 activates the moment the opponent (or, for public, any joiner)
      // accepts — regardless of the creator's chosen start_time. Per product
      // spec: 1v1 always snap-to-now on acceptance (see Migration 0040
      // discussion). Falls through to the shared snap-and-activate path
      // below.
      final allAccepted = battle.participants.every(
          (p) => p.inviteStatus == ParticipantInviteStatus.accepted);
      if (battle.type == BattleType.oneVsOne) {
        if (!allAccepted) return AcceptInviteOutcome.regular;
        await _snapAndActivate(battle);
        return AcceptInviteOutcome.regular;
      }

      // Group: wait for everyone to accept. When they all have, the
      // decision to start now vs honour the scheduled slot depends on
      // whether the creator picked a future start time (>1h out) — the
      // "scheduled" mode from Migration 0040. Scheduled group battles
      // wait; immediate group battles snap-to-now on all-accept.
      if (!allAccepted) return AcceptInviteOutcome.regular;
      if (battle.isScheduled) {
        // Respect the scheduled slot. If start_time is still in the future
        // schedule it; otherwise activate immediately (edge case: last
        // accept lands after the scheduled start).
        if (battle.startTime.isAfter(DateTime.now())) {
          await _scheduleBattle(battle);
        } else {
          await _activateBattle(battle);
        }
      } else {
        await _snapAndActivate(battle);
      }
      return AcceptInviteOutcome.regular;
    } catch (e, s) {
      AppLogger.battle.e('acceptInvite:failed',
          fields: {'battleId': battleId, 'userId': userId},
          error: e,
          stack: s);
      rethrow;
    }
  }

  /// Reconcile the current user's `battle_participants.battle_avatar_id`
  /// with their live `profiles.battle_avatar_id`, for THIS battle only.
  /// Runs on arena open so a user who picks a new runner (Runner 10)
  /// AFTER the battle was created sees their choice in the arena
  /// instead of the value snapshotted at battle-creation time.
  ///
  /// Only writes when the two differ. RLS restricts UPDATE on
  /// `battle_participants` to the row where `user_id = auth.uid()`,
  /// so this only ever mutates the caller's own row; opponents'
  /// snapshots stay locked to preserve match-identity stability.
  Future<void> refreshOwnBattleAvatar({
    required String battleId,
    required String userId,
  }) async {
    try {
      final profileRow = await _supabase
          .from('profiles_public')
          .select('battle_avatar_id')
          .eq('id', userId)
          .maybeSingle();
      final currentAvatarId =
          (profileRow?['battle_avatar_id'] as String?) ?? 'avatar_01';

      final participantRow = await _supabase
          .from('battle_participants')
          .select('battle_avatar_id')
          .eq('battle_id', battleId)
          .eq('user_id', userId)
          .maybeSingle();
      final snapshottedAvatarId =
          (participantRow?['battle_avatar_id'] as String?) ?? 'avatar_01';

      if (currentAvatarId == snapshottedAvatarId) return;

      await _supabase
          .from('battle_participants')
          .update({'battle_avatar_id': currentAvatarId})
          .eq('battle_id', battleId)
          .eq('user_id', userId);

      AppLogger.battle.i('refreshOwnBattleAvatar:updated', fields: {
        'battleId': battleId,
        'userId': userId,
        'from': snapshottedAvatarId,
        'to': currentAvatarId,
      });
    } catch (e, s) {
      // Non-fatal — the arena will still render whatever the
      // participant row currently has (the default or old snapshot).
      AppLogger.battle.w('refreshOwnBattleAvatar:failed',
          fields: {'battleId': battleId, 'err': e.toString()});
      // s used only to satisfy the analyzer when the log doesn't
      // attach it — this failure is expected to be transient network.
      // ignore: unused_local_variable
      final _ = s;
    }
  }

  Future<void> rejectInvite({
    required String battleId,
    required String userId,
  }) async {
    AppLogger.battle.i('rejectInvite',
        fields: {'battleId': battleId, 'userId': userId});
    try {
      // Server-side SECURITY DEFINER RPC (migration 0043) owns the
      // whole flow: flips the caller's participant row to rejected,
      // and for 1v1 also cancels the battle, refunds all paid stakes
      // via credit_user_xp, and inserts the creator's notification.
      //
      // Previously we did all of this from the client — the refund
      // step called `refund_battle_stakes` which is creator-only,
      // so an invitee's reject threw and got swallowed silently.
      await _supabase.rpc('reject_battle_invite', params: {
        'p_battle_id': battleId,
        'p_user_id': userId,
      });

      // Group / team activation check: if after this reject the only
      // remaining participants are all accepted (≥2), flip to active.
      // The RPC intentionally leaves this to the client so the
      // activation path stays in one place with baseline capture.
      final battle = await _fetchBattle(battleId);
      if (battle == null) return;
      if (battle.type == BattleType.oneVsOne) return;
      if (battle.status != BattleStatus.pending) return;
      final accepted = battle.participants
          .where((p) =>
              p.inviteStatus == ParticipantInviteStatus.accepted)
          .toList();
      final pending = battle.participants
          .where((p) =>
              p.inviteStatus == ParticipantInviteStatus.pending)
          .toList();
      if (pending.isEmpty && accepted.length >= 2) {
        await _activateBattle(battle);
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

    // Same non-fatal treatment as _activateBattle — the accepter's
    // session writes a row addressed to someone else; prod RLS on
    // notifications can reject with 42501 depending on policy state.
    // Failure here should NOT unwind the scheduling transition above.
    try {
      await _supabase.from('notifications').insert({
        'user_id': battle.createdBy,
        'type': 'battle_started',
        'title': 'Battle Scheduled',
        'body':
            'All players are in. Battle starts at ${_humanTime(battle.startTime)}.',
        'data': {'battle_id': battle.battleId},
      });
    } catch (e) {
      AppLogger.battle.w('scheduleBattle:notifyFailed', fields: {
        'battleId': battle.battleId,
        'err': e.toString(),
      });
    }
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
          .from('profiles_public')
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
    //
    // Non-fatal: acceptInvite drives us here from the accepter's session,
    // so the insert writes with `user_id = battle.createdBy` (someone
    // else). Prod hit RLS 42501 on this row in 1.1.3 — swallowing the
    // failure keeps stake/participant/status changes intact; the creator
    // still sees the battle go live via the realtime `battles` stream.
    // The proper server-side fix lives in migration 0052 (staged in
    // PENDING_MIGRATIONS.md) — `notify_battle_activated` RPC.
    try {
      await _supabase.from('notifications').insert({
        'user_id': battle.createdBy,
        'type': 'battle_started',
        'title': 'Battle Live',
        'body': 'Your battle just started. Step it up!',
        'data': {'battle_id': battle.battleId},
      });
    } catch (e) {
      AppLogger.battle.w('activateBattle:notifyFailed', fields: {
        'battleId': battle.battleId,
        'err': e.toString(),
      });
    }
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
  //
  // REMOVED in 1.1.6+29 — this used to be a client-side "helper" that
  // finalised any active-past-end-time battle by writing status
  // 'active' → 'completed' + winner_id + is_winner directly. That was
  // a bug: process_battle_lifecycle (the server cron) picks battles
  // by WHERE status='active', and once the client flipped it to
  // 'completed' the cron never called settle_stake_battle for it.
  // Result: both participants' stakes were debited (correct) but the
  // pot never landed on the winner's xp_ledger. See the SQL evidence
  // trail on battle #40F7 (2026-08-18) — status=completed,
  // winner_id=Laxmi, is_winner=true, yet zero battle_win row in the
  // ledger and total_xp unchanged since the stake debit.
  //
  // The fix is to let the cron own completion end-to-end. The Battles
  // and Arena screens no longer call this method. Battle cards show
  // an 'Ending…' pill (StatusType.ending) for the ~60 s between
  // end_time hitting and the cron settling — see battle_card.dart.
  //
  // If the mission bumping that used to happen here is missed for a
  // stake winner, follow up by moving _propagateBattleWinToMissions
  // into settle_stake_battle server-side (its own migration). Not
  // fixing that here to keep this change surgically about the pot
  // loss.
  //
  // Callers previously: battles_screen.dart:57, battle_ground_screen.dart:372
  // Both were removed alongside this function.
  // ---------------------------------------------------------------------------

  /// No-op kept for source compatibility. The original client-side
  /// completion path was removed in 1.1.6+29 — see the block comment
  /// above. Callers (battles_screen.dart, battle_ground_screen.dart)
  /// were also removed; if a future caller reappears, lint will flag
  /// them via [Deprecated] and this trace log will surface in
  /// Diagnostics.
  @Deprecated('Removed in 1.1.6+29 — server cron owns battle completion.')
  Future<void> completeExpiredBattles(String userId) async {
    AppLogger.battle.t('completeExpired:skipped', fields: {
      'userId': userId,
      'note': 'client no longer completes battles — cron owns it',
    });
  }

  // NOTE (1.1.6+29): the `_propagateBattleWinToMissions` helper that
  // used to bump `battle`-category user_mission_progress on a client-
  // side stake-battle completion was removed alongside
  // completeExpiredBattles. Battle-win mission propagation for stake
  // battles needs to move server-side into settle_stake_battle
  // (parallel to how streak/daily-mission credits are handled by
  // _credit_xp_admin + advance_daily_progress). Tracking as a
  // follow-up migration; not fixing here to keep this change
  // surgically about the pot-loss root cause.

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
    // Stream `battle_participants` (all rows for this battle) instead
    // of the `battles` row. Rationale:
    //   • The `battles` row rarely changes mid-lobby — status flips
    //     from pending → active always coincide with participant
    //     writes (baseline snapshot, current_steps=0), so streaming
    //     participants catches the same transitions.
    //   • The old approach streamed `battles.id = X`, which never
    //     fires when a NEW participant is inserted or when another
    //     player's `invite_status` flips accepted. Result: the
    //     team-lobby creator's UI never noticed joiners because their
    //     own participant row hadn't changed.
    //   • Filtering the stream by battle_id (not user_id) picks up
    //     any user's join / accept / leave for this specific battle.
    //
    // Trailing-debounce collapses `current_steps` bursts (4 players
    // syncing on the same 60s tick) into a single JOIN refetch.
    const debounceWindow = Duration(milliseconds: 500);
    final rawStream = _supabase
        .from('battle_participants')
        .stream(primaryKey: ['battle_id', 'user_id'])
        .eq('battle_id', battleId);
    return debounceTrailing(rawStream, debounceWindow).asyncMap((_) async {
      // Full re-fetch with battles + battle_teams join so the model
      // is fully hydrated (participant array + metadata).
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
    String? creatorPreferredName,
    String? creatorAvatarUrl,
  }) async {
    // v2 economy — team battles will also be pot-based once the
    // Clan tab ships (currently gated behind "Coming Soon"). We seed
    // xp_reward=0 so the payout goes entirely through the pot when
    // the flow reactivates.
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
            'xp_reward': 0,
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
        'preferred_name': creatorPreferredName,
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
    required List<({String userId, String displayName, String? preferredName, String? avatarUrl, String teamLabel})>
        entries,
  }) async {
    if (entries.isEmpty) return;
    // Fetch existing rows so we can distinguish new-invite (insert),
    // re-invite-after-reject (update status → pending), already-pending
    // (idempotent — resend notification), and already-accepted (skip;
    // they're in the lobby already).
    //
    // The old insert-only path threw `duplicate key` on any second
    // invite attempt for the same user because the participant PK is
    // (battle_id, user_id).
    final userIds = entries.map((e) => e.userId).toList();
    final existingRows = await _supabase
        .from('battle_participants')
        .select('user_id, invite_status')
        .eq('battle_id', battleId)
        .inFilter('user_id', userIds);
    final byId = <String, String>{
      for (final r in existingRows as List)
        r['user_id'] as String: (r['invite_status'] as String? ?? 'pending'),
    };

    final toInsert = <Map<String, dynamic>>[];
    final toUpdate = <
        ({String userId, String teamLabel})>[];
    final toNotify = <({String userId, String teamLabel})>[];

    for (final e in entries) {
      final existing = byId[e.userId];
      if (existing == null) {
        toInsert.add({
          'battle_id': battleId,
          'user_id': e.userId,
          'display_name': e.displayName,
          'preferred_name': e.preferredName,
          'avatar_url': e.avatarUrl,
          'current_steps': 0,
          'is_winner': false,
          'invite_status': 'pending',
          'team_label': e.teamLabel,
        });
        toNotify.add((userId: e.userId, teamLabel: e.teamLabel));
      } else if (existing == 'accepted') {
        // Already in the lobby — nothing to do.
        continue;
      } else if (existing == 'rejected') {
        // Re-invite after a prior reject / auto-drop — flip back to
        // pending and reset team_label to the caller-chosen slot.
        toUpdate.add((userId: e.userId, teamLabel: e.teamLabel));
        toNotify.add((userId: e.userId, teamLabel: e.teamLabel));
      } else {
        // Still pending. No DB write, but resend a notification so
        // they can act on it if they missed the first one.
        toNotify.add((userId: e.userId, teamLabel: e.teamLabel));
      }
    }

    if (toInsert.isNotEmpty) {
      await _supabase.from('battle_participants').insert(toInsert);
    }
    for (final u in toUpdate) {
      await _supabase
          .from('battle_participants')
          .update({
            'invite_status': 'pending',
            'team_label': u.teamLabel,
          })
          .eq('battle_id', battleId)
          .eq('user_id', u.userId);
    }

    // Fire notifications inline so the invitee's slide-in toast pops
    // for every invite attempt (not just the first). Was previously
    // batched inside `fanoutTeamLobbyInvites` which the new team-
    // lobby-page flow doesn't call.
    if (toNotify.isNotEmpty) {
      final battle = await _fetchBattle(battleId);
      final creator = battle?.participants.firstWhere(
        (p) => p.userId == battle.createdBy,
        orElse: () => battle.participants.first,
      );
      final teamCount = battle?.teamCount ?? battle?.teamLabels.length ?? 2;
      final creatorName = creator?.displayName ?? 'Someone';
      final rows = toNotify
          .map((n) => {
                'user_id': n.userId,
                'type': 'battle_invite',
                'title': 'Team Battle Invite',
                'body':
                    '$creatorName added you to a $teamCount-team step battle',
                'data': {
                  'battle_id': battleId,
                  'from_user_id': battle?.createdBy,
                  'team_label': n.teamLabel,
                },
              })
          .toList();
      await _supabase.from('notifications').insert(rows);
    }

    AppLogger.battle.i('addTeamLobbyParticipants', fields: {
      'battleId': battleId,
      'requested': entries.length,
      'inserted': toInsert.length,
      'reinvited': toUpdate.length,
      'notified': toNotify.length,
    });
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

  /// Creator hits Start Now on a pending Group or Team battle: drop any
  /// still-pending invitees, rewrite the window to `[now, now +
  /// originalDuration]`, and activate. Works for both Group and Team
  /// battles under the 24h lifecycle (Migration 0040); the parent cron
  /// `process_pending_battle_expiry` performs the same steps at the
  /// deadline for any battle the creator never manually starts.
  Future<void> startBattleNow({
    required String battleId,
    required String actorId,
  }) async {
    final battle = await _fetchBattle(battleId);
    if (battle == null) throw StateError('Battle not found');
    if (battle.createdBy != actorId) {
      throw StateError('Only the creator can start this battle.');
    }
    if (battle.type == BattleType.oneVsOne) {
      // 1v1s activate automatically the moment the opponent accepts —
      // there's nothing manual for the creator to trigger here.
      throw StateError('Start Now doesn\'t apply to 1v1 battles.');
    }
    if (battle.status != BattleStatus.pending) {
      throw StateError('Battle is no longer in lobby state.');
    }
    final accepted = battle.participants
        .where((p) => p.inviteStatus == ParticipantInviteStatus.accepted)
        .toList();
    // Creator counts as accepted, so ≥2 means at least ONE non-creator has
    // joined. Group needs ≥2 total; Team needs ≥2 members spread across ≥2
    // teams (otherwise it's not a team battle, it's a lopsided lobby).
    final nonCreator = accepted.where((p) => p.userId != actorId).length;
    if (nonCreator < 1) {
      throw StateError('Need at least 1 accepted player to start.');
    }
    if (battle.type == BattleType.team) {
      final teamsWithMembers = <String>{
        for (final p in accepted)
          if (p.teamLabel != null) p.teamLabel!,
      };
      if (teamsWithMembers.length < 2) {
        throw StateError('Need at least 2 teams with players to start.');
      }
    }

    // Drop anyone still pending. They never paid a stake so no refund.
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
      // Clear the pending deadline — the battle is about to become active.
      // Migration 0040 makes this column nullable for exactly this case.
      'pending_expires_at': null,
    }).eq('id', battleId);

    final refreshed = await _fetchBattle(battleId);
    if (refreshed == null) return;
    await _activateBattle(refreshed);

    AppLogger.battle.i('startBattleNow', fields: {
      'battleId': battleId,
      'actorId': actorId,
      'type': battle.type.name,
      'accepted': accepted.length,
      'durationMin': duration.inMinutes,
    });
  }

  /// Deprecated alias — use [startBattleNow]. Kept so any lingering caller
  /// keeps compiling while call sites migrate to the type-agnostic name.
  Future<void> startTeamBattle({
    required String battleId,
    required String actorId,
  }) =>
      startBattleNow(battleId: battleId, actorId: actorId);

  /// Self-serve team switch while the battle is pending. Anyone in the battle
  /// can move themselves; the creator can move anyone (via the [targetUserId]
  /// param — defaults to [actorId]).
  Future<void> switchTeam({
    required String battleId,
    required String actorId,
    required String teamLabel,
    String? targetUserId,
  }) async {
    // Client-side sanity — cheap. The old version did a full
    // _fetchBattle round-trip here for defense in depth; RLS already
    // enforces status/authority server-side, so this dropped one
    // network round-trip and made the swap feel noticeably snappier.
    if (teamLabel != 'A' && teamLabel != 'B' && teamLabel != 'C' &&
        teamLabel != 'D') {
      throw ArgumentError('Invalid team label: $teamLabel');
    }
    final target = targetUserId ?? actorId;
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

  /// Creator locks in the stake for a team lobby. Sets `stake_xp` on
  /// the battle row + charges the creator's own stake via `_chargeStake`
  /// (same path the acceptor flow uses). After this succeeds:
  ///   • The stake field is treated as LOCKED by the lobby UI —
  ///     already-in players can't get an unexpected stake change under
  ///     them.
  ///   • The `Invite players` affordance appears on the page.
  ///
  /// Throws `InsufficientXpException` if the creator can't cover the
  /// stake themselves. Idempotent — a second call with the same stake
  /// no-ops (stake_paid flag on the creator's participant row is the
  /// dedup guard).
  Future<void> confirmStake({
    required String battleId,
    required String actorId,
    required int stakeXp,
  }) async {
    if (stakeXp < AppConstants.minBattleStakeXp) {
      throw ArgumentError(
          'Minimum stake is ${AppConstants.minBattleStakeXp} XP.');
    }
    AppLogger.battle.i('confirmStake:start',
        fields: {'battleId': battleId, 'stakeXp': stakeXp});
    await _supabase
        .from('battles')
        .update({'stake_xp': stakeXp}).eq('id', battleId);
    await _chargeStake(
      battleId: battleId,
      userId: actorId,
      stake: stakeXp,
    );
    AppLogger.battle.i('confirmStake:done',
        fields: {'battleId': battleId, 'stakeXp': stakeXp});
  }

  /// Non-creator "I want out" for a pending team lobby (Batch 4 spec).
  /// Refunds the leaver's stake via the `refund_participant_stake` RPC
  /// (Migration 0042) and flips their `invite_status` to `rejected` so
  /// the roster shrinks in real time for everyone else. Idempotent —
  /// the RPC no-ops when `stake_paid = false`.
  ///
  /// Only the leaver themselves can invoke — the RPC's `auth.uid() =
  /// p_user_id` check enforces this. The creator uses
  /// [removeParticipantAsCreator] to kick a specific user, or
  /// [cancelBattle] to end the whole lobby.
  Future<void> leaveTeamBattle({
    required String battleId,
    required String userId,
  }) async {
    AppLogger.battle
        .i('leaveTeamBattle', fields: {'battleId': battleId, 'userId': userId});
    await _supabase.rpc('refund_participant_stake', params: {
      'p_battle_id': battleId,
      'p_user_id': userId,
    });
  }

  /// Creator's "kick this participant out" for a pending team lobby.
  /// Migration 0058's `creator_remove_participant` RPC does the refund +
  /// `invite_status='rejected'` drop-out atomically, and inserts a
  /// "You were removed" notification for the kicked user.
  ///
  /// The equivalent client path used to be [leaveTeamBattle] with the
  /// target's uid, but that RPC has a `auth.uid() = p_user_id` check
  /// (self-only) — creators calling it for another user hit
  /// `not_authorized: caller must match participant`.
  Future<void> removeParticipantAsCreator({
    required String battleId,
    required String targetUserId,
  }) async {
    AppLogger.battle.i('removeParticipantAsCreator',
        fields: {'battleId': battleId, 'targetUserId': targetUserId});
    await _supabase.rpc('creator_remove_participant', params: {
      'p_battle_id': battleId,
      'p_target_user_id': targetUserId,
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
    String? preferredName,
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

    // Snapshot the joiner's currently-selected battle avatar so the
    // arena renders their chosen runner instead of the default. The
    // creator's `createBattle` path already does this for invitees;
    // `joinByCode` used to omit the field entirely, which left the
    // participant row's `battle_avatar_id` NULL and the arena
    // fallback painted `avatar_01` for every code-joined user.
    // Reads `profiles_public` because RLS on `profiles` is now
    // self-only (migration 0036).
    String? joinerAvatarId;
    try {
      final row = await _supabase
          .from('profiles_public')
          .select('battle_avatar_id')
          .eq('id', userId)
          .maybeSingle();
      joinerAvatarId = row?['battle_avatar_id'] as String?;
    } catch (e) {
      // Non-fatal — fall through to the default. Logged so a
      // recurring failure is visible even though it doesn't block
      // the join.
      AppLogger.battle.w('joinByCode:avatarSnapshotFailed',
          fields: {'userId': userId, 'err': e.toString()});
    }

    final row = {
      'battle_id': battle.battleId,
      'user_id': userId,
      'display_name': displayName,
      'preferred_name': preferredName,
      'avatar_url': avatarUrl,
      'current_steps': 0,
      'is_winner': false,
      // Code possession = consent to play. Auto-accept.
      'invite_status': 'accepted',
      'battle_avatar_id': joinerAvatarId ?? 'avatar_01',
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
    // Discover only surfaces battles that are still joinable (pending —
    // the creator picked a start ≥ now+1h, so joiners have a real
    // window to drop in). Active battles disappear from Discover the
    // moment they flip status.
    final rows = await _supabase
        .from('battles')
        .select('*, battle_participants(*), battle_teams(*)')
        .eq('visibility', 'public')
        .eq('status', 'pending')
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

  /// Snap the battle's start_time to NOW and activate. Used by
  /// [acceptInvite] for 1v1 (always) and Group in immediate mode (all-
  /// accepted). If end_time already passed by the time we get here, the
  /// battle is cancelled and stakes refunded rather than started into a
  /// window with no runway.
  Future<void> _snapAndActivate(BattleModel battle) async {
    final now = DateTime.now();
    if (battle.endTime.isBefore(now)) {
      // Cancel + refund — same recovery path as the old
      // "acceptInvite:privateEndExpired" branch.
      AppLogger.battle.w('snapAndActivate:endExpired',
          fields: {'battleId': battle.battleId});
      await refundAllStakes(battle.battleId);
      await _supabase
          .from('battles')
          .update({'status': 'cancelled', 'pending_expires_at': null})
          .eq('id', battle.battleId);
      return;
    }
    await _supabase.from('battles').update({
      'start_time': now.toUtc().toIso8601String(),
      'pending_expires_at': null,
    }).eq('id', battle.battleId);
    final refreshed = await _fetchBattle(battle.battleId);
    if (refreshed != null) {
      await _activateBattle(refreshed);
    }
    AppLogger.battle.i('snapAndActivate:done', fields: {
      'battleId': battle.battleId,
      'snappedStart': now.toIso8601String(),
      'endTime': battle.endTime.toIso8601String(),
    });
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
  ///
  /// Routed through the `refund_battle_stakes` SECURITY DEFINER RPC
  /// (migration 0034). Previously this method looped `credit_user_xp`
  /// with `p_user_id` = the OTHER participants' uids — a hole that
  /// let any authenticated user credit XP to any other user by
  /// claiming a "refund" reason. The RPC now enforces server-side that
  /// only the battle creator can trigger a refund and that the amount
  /// equals `battles.stake_xp`.
  Future<void> refundAllStakes(String battleId) async {
    await _supabase.rpc('refund_battle_stakes', params: {
      'p_battle_id': battleId,
    });
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
