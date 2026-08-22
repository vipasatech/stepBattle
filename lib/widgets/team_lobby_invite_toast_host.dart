import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/battle_model.dart';
import '../providers/auth_provider.dart';
import '../providers/battle_provider.dart';
import '../services/battle_service.dart';
import '../utils/app_logger.dart';
import 'team_lobby_invite_toast.dart';

/// Wraps the navigation shell so a slide-in team-lobby invite card
/// pops down from the top whenever the signed-in user gets pulled
/// into a pending team battle.
///
/// Watches [scheduledBattlesProvider] (all `status = pending` rows the
/// current user is party to). On first emission it seeds the "already
/// seen" set with the backlog so the app doesn't flash a stack of
/// toasts for invites the user has already been sitting on. Every
/// subsequent emission checks for genuinely-new team-battle invites
/// where the current user's participant row is `pending`, and enqueues
/// a toast per new one (shown one at a time, FIFO).
///
/// Actions:
///   • Tick → `battleService.acceptInvite(...)`; toast slides out and
///     the accept side-effect (stake charge, "you're in Team A" etc.)
///     is realtime-driven from the participants row change.
///   • Cross → `battleService.rejectInvite(...)`; toast slides out.
///   • 5-sec timeout → toast slides out silently, leaves the invite
///     pending so the user can still respond from the Battles tab or
///     the notification centre.
///
/// Mirrors [FriendRequestToastHost] structurally on purpose — a
/// fitness app that surfaces two conceptually-similar "someone wants
/// you to join" moments should keep the mental model tight.
class TeamLobbyInviteToastHost extends ConsumerStatefulWidget {
  final Widget child;
  const TeamLobbyInviteToastHost({super.key, required this.child});

  @override
  ConsumerState<TeamLobbyInviteToastHost> createState() =>
      _TeamLobbyInviteToastHostState();
}

class _TeamLobbyInviteToastHostState
    extends ConsumerState<TeamLobbyInviteToastHost> {
  bool _initialized = false;
  // Tracks the last-seen invite_status per battle. Using a full
  // Map<battleId, status> instead of a plain seen-set lets us detect
  // the "rejected → pending" transition that happens when the creator
  // re-invites someone who previously said no — the plain set would
  // treat the battle as "already seen" and swallow the re-invite
  // silently.
  final Map<String, ParticipantInviteStatus> _lastStatus = {};
  final Queue<BattleModel> _queue = Queue();
  BattleModel? _current;

  /// Called on every emission of the ALL-battles stream. Enqueues a
  /// toast whenever the current user's participant row for a team
  /// battle transitions INTO `pending` from anything else (missing,
  /// accepted, or rejected). Same-status ticks are ignored so
  /// notification-count refreshes / other unrelated realtime churn
  /// don't re-fire the toast.
  void _ingest(List<BattleModel> allBattles, String myUid) {
    // Build the current view: for each team battle I'm a participant
    // in (and didn't create), record my current invite_status.
    final currentByBattle = <String, ({BattleModel battle, ParticipantInviteStatus status})>{};
    for (final b in allBattles) {
      if (b.type != BattleType.team) continue;
      if (b.createdBy == myUid) continue;
      final me = b.participantFor(myUid);
      if (me == null) continue;
      currentByBattle[b.battleId] = (battle: b, status: me.inviteStatus);
    }

    if (!_initialized) {
      // First emission is the backlog. Seed the status map without
      // toasting so a fresh app-open doesn't blast a wall of pending
      // invites the user could already act on from the notifications
      // tab.
      for (final entry in currentByBattle.entries) {
        _lastStatus[entry.key] = entry.value.status;
      }
      _initialized = true;
      AppLogger.notification.i('teamLobbyToast:seed', fields: {
        'backlogCount': currentByBattle.length,
      });
      return;
    }

    var enqueued = 0;
    for (final entry in currentByBattle.entries) {
      final battleId = entry.key;
      final now = entry.value.status;
      final prev = _lastStatus[battleId];
      final becamePending = now == ParticipantInviteStatus.pending &&
          prev != ParticipantInviteStatus.pending;
      _lastStatus[battleId] = now;
      if (!becamePending) continue;
      _queue.add(entry.value.battle);
      enqueued++;
      AppLogger.notification.i('teamLobbyToast:enqueue', fields: {
        'battleId': battleId,
        'prevStatus': prev?.name ?? 'null',
        'nowStatus': now.name,
      });
    }
    // Prune status entries for battles that have completely left the
    // stream (cancelled, refunded, or otherwise gone) so the map
    // doesn't grow unbounded across sessions.
    _lastStatus.removeWhere((id, _) => !currentByBattle.containsKey(id));
    // Log every tick so testers can see the stream is alive — the
    // "sometimes not firing" report will be easier to diagnose with
    // per-tick visibility.
    AppLogger.notification.d('teamLobbyToast:tick', fields: {
      'relevantCount': currentByBattle.length,
      'enqueued': enqueued,
      'queueLen': _queue.length,
      'currentShown': _current?.battleId,
    });
    if (enqueued > 0) _promoteNext();
  }

  void _promoteNext() {
    if (_current != null) return;
    if (_queue.isEmpty) return;
    setState(() => _current = _queue.removeFirst());
  }

  Future<void> _onAccept() async {
    final current = _current;
    if (current == null) return;
    final myUid = Supabase.instance.client.auth.currentUser?.id;
    if (myUid == null) return;
    var accepted = false;
    try {
      await ref.read(battleServiceProvider).acceptInvite(
            battleId: current.battleId,
            userId: myUid,
          );
      await _markInviteNotificationRead(myUid, current.battleId);
      accepted = true;
    } on InsufficientXpException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Not enough XP to join this stake. Top up and try again from the Battles tab.'),
          ),
        );
      }
    } catch (e) {
      AppLogger.battle.e('teamLobbyToast:acceptFailed',
          fields: {'battleId': current.battleId}, error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not accept invite: $e')),
        );
      }
    }
    if (!mounted) return;
    setState(() => _current = null);
    _promoteNext();
    // Navigate to the team lobby page so the joiner lands right in
    // the shared roster + can double-tap into a team. Only on a real
    // accept — insufficient-XP / other failures stay on the current
    // screen so the snackbar above is visible.
    if (accepted && mounted) {
      context.push('/team-lobby/${current.battleId}');
    }
  }

  /// Explicit tap on the X (decline) button on the toast.
  ///
  /// Fires `rejectInvite` server-side + marks the notification row read.
  /// Distinct from [_onTimeout] which fires when the 5s auto-dismiss
  /// expires and must NOT reject.
  Future<void> _onDecline() async {
    final current = _current;
    if (current == null) return;
    final myUid = Supabase.instance.client.auth.currentUser?.id;
    if (myUid == null) return;
    try {
      await ref.read(battleServiceProvider).rejectInvite(
            battleId: current.battleId,
            userId: myUid,
          );
      await _markInviteNotificationRead(myUid, current.battleId);
    } catch (e) {
      AppLogger.battle.e('teamLobbyToast:rejectFailed',
          fields: {'battleId': current.battleId}, error: e);
      // Non-blocking — reject failing usually means it was already
      // resolved (creator cancelled etc.); no need to bother the user.
    }
    if (!mounted) return;
    setState(() => _current = null);
    _promoteNext();
  }

  /// Auto-dismiss expired (5s of inactivity).
  ///
  /// Semantically NOT the same as [_onDecline]: we do NOT call
  /// `rejectInvite` and do NOT mark the notification as read — the
  /// invite stays valid so the user can still act on it later from
  /// the Battles tab or the notification centre. Just clears the
  /// current toast slot + promotes the next queued invite.
  ///
  /// Bug context (fixed 1.1.6+27): the toast widget used to hand
  /// timeout back through `onDecline`, which caused this host to
  /// call `rejectInvite` after 5s of inactivity — silently killing
  /// invites the user simply hadn't got to.
  void _onTimeout() {
    final current = _current;
    if (current == null) return;
    AppLogger.notification.i('teamLobbyToast:timeout', fields: {
      'battleId': current.battleId,
    });
    if (!mounted) return;
    setState(() => _current = null);
    _promoteNext();
  }

  /// Mark any team-lobby-invite notification row for this battle as
  /// read, so the bell badge decrements after the user acts on the
  /// slide-in. Best-effort — a failure here is silent.
  Future<void> _markInviteNotificationRead(
      String uid, String battleId) async {
    final supabase = Supabase.instance.client;
    try {
      await supabase
          .from('notifications')
          .update({'read': true})
          .eq('user_id', uid)
          .eq('read', false)
          .contains('data', {'battle_id': battleId});
    } catch (_) {
      // Non-critical — dismissal doesn't block on read-state persist.
    }
  }

  @override
  Widget build(BuildContext context) {
    // Listen to auth so we reset the seen-set on sign-in / sign-out
    // (backlog seeding needs to re-happen for the new identity).
    ref.listen(authStateProvider, (prev, next) {
      final prevUid = prev?.valueOrNull?.id;
      final nextUid = next.valueOrNull?.id;
      if (prevUid != nextUid) {
        _initialized = false;
        _lastStatus.clear();
        _queue.clear();
        if (mounted) setState(() => _current = null);
      }
    });

    // Drive the toast queue off pending battles.
    ref.listen<List<BattleModel>>(scheduledBattlesProvider, (prev, next) {
      final myUid = Supabase.instance.client.auth.currentUser?.id;
      if (myUid == null) return;
      _ingest(next, myUid);
    });

    final current = _current;
    return Stack(
      children: [
        widget.child,
        if (current != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Builder(builder: (_) {
                final myUid =
                    Supabase.instance.client.auth.currentUser?.id;
                final creator = myUid == null
                    ? null
                    : current.participants
                        .where((p) => p.userId == current.createdBy)
                        .firstOrNull;
                final teamCount = current.teamCount ??
                    current.teamLabels.length.clamp(2, 4);
                // Show the stake up-front — invitees decide with the
                // number visible so they don't accept blind. Stake is
                // locked before invites go out (see confirmStake in
                // team_lobby_page), so this reflects the exact XP
                // they'll pay on accept.
                final stakeLabel = current.stakeXp > 0
                    ? 'Stake ${current.stakeXp} XP'
                    : 'Free play';
                final subtitle = '$teamCount teams · $stakeLabel';
                return TeamLobbyInviteToast(
                  // Key by battleId so a new arrival rebuilds the
                  // widget (re-runs entry animation + auto-dismiss
                  // timer) rather than reusing state.
                  key: ValueKey(current.battleId),
                  creatorName: creator?.friendlyName ?? 'Someone',
                  creatorAvatarUrl: creator?.avatarURL,
                  subtitle: subtitle,
                  onAccept: _onAccept,
                  onDecline: _onDecline,
                  onTimeout: _onTimeout,
                );
              }),
            ),
          ),
      ],
    );
  }
}
