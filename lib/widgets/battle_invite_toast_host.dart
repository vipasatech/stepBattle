import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/notification_model.dart';
import '../providers/auth_provider.dart';
import '../providers/battle_provider.dart';
import '../providers/notification_provider.dart';
import '../services/battle_service.dart';
import '../utils/app_logger.dart';
import 'battle_invite_toast.dart';

/// Wraps the navigation shell so a slide-in toast pops down from the
/// top whenever the signed-in user receives a 1v1 or daily-series
/// battle invite while the app is in the foreground.
///
/// Complements [TeamLobbyInviteToastHost] — that one drives off the
/// `battle_participants` realtime stream and covers team battles only.
/// This host drives off the `notifications` table stream (already open
/// for the bell badge) and covers 1v1 + daily. Team invites are
/// deliberately EXCLUDED here (see `_isTargetedBattleInvite`) so a
/// team invite never fires two toasts.
///
/// Trigger:
///   1. Watches `notificationsProvider` (Supabase realtime on
///      `public.notifications` where `user_id = me`).
///   2. On first emission, seeds a "seen" set with the full backlog so
///      the user isn't blasted with a stack of toasts for invites
///      they've been sitting on across sessions.
///   3. Every subsequent emission checks for genuinely-new
///      `battle_invite` rows (not in seen-set AND `!read`) and
///      enqueues one toast per new invite (shown FIFO, one at a time).
///
/// Actions:
///   • Tick → `battleService.acceptInvite(...)`; marks the notification
///     row `read=true` and routes to `/battles` (so the user lands
///     somewhere useful). Daily-series accept returns a
///     [AcceptInviteOutcome.dailySeriesFirstJoin] which we surface as
///     a follow-up SnackBar (same message as
///     `notifications_sheet.dart`'s accept path).
///   • Cross → `battleService.rejectInvite(...)`; marks the
///     notification row read.
///   • 5-sec timeout → toast slides away silently. Notification stays
///     unread so the user can still act on it later from the bell.
///
/// Mounted in `main_shell.dart` alongside FriendRequestToastHost and
/// TeamLobbyInviteToastHost.
class BattleInviteToastHost extends ConsumerStatefulWidget {
  final Widget child;
  const BattleInviteToastHost({super.key, required this.child});

  @override
  ConsumerState<BattleInviteToastHost> createState() =>
      _BattleInviteToastHostState();
}

class _BattleInviteToastHostState
    extends ConsumerState<BattleInviteToastHost> {
  bool _initialized = false;
  final Set<String> _seenIds = {};
  final Queue<NotificationModel> _queue = Queue();
  NotificationModel? _current;

  /// Team invites carry a `team_label` in the data payload (see
  /// [BattleService.addTeamLobbyParticipants] + `fanoutTeamLobbyInvites`
  /// in `lib/services/battle_service.dart`). We skip those here since
  /// [TeamLobbyInviteToastHost] already owns them via a different
  /// trigger stream.
  bool _isTargetedBattleInvite(NotificationModel n) {
    if (n.type != NotificationType.battleInvite) return false;
    if (n.read) return false;
    if (n.data.containsKey('team_label')) return false;
    final battleId = n.data['battle_id'] ?? n.data['battleId'];
    if (battleId is! String || battleId.isEmpty) return false;
    return true;
  }

  bool _isDaily(NotificationModel n) {
    final recurring = n.data['recurring']?.toString().toLowerCase();
    return recurring == 'daily';
  }

  /// Called on every emission of the notifications stream. On first
  /// emission seeds the seen-set with the backlog (no toasts). On
  /// subsequent emissions, enqueues any newly-arrived battle_invite
  /// rows we haven't seen yet.
  void _ingest(List<NotificationModel> notifications) {
    final relevant = notifications.where(_isTargetedBattleInvite).toList();

    if (!_initialized) {
      for (final n in relevant) {
        _seenIds.add(n.id);
      }
      _initialized = true;
      AppLogger.notification.i('battleInviteToast:seed', fields: {
        'backlogCount': relevant.length,
      });
      return;
    }

    // Prune seen-ids for notifications that have fully aged out of the
    // 50-row stream window — keeps the set bounded across sessions.
    final currentIds = notifications.map((n) => n.id).toSet();
    _seenIds.removeWhere((id) => !currentIds.contains(id));

    var enqueued = 0;
    // Iterate oldest-first (stream is newest-first, so reverse) so
    // multi-invite bursts pop in the order they were created.
    for (final n in relevant.reversed) {
      if (_seenIds.contains(n.id)) continue;
      _seenIds.add(n.id);
      _queue.add(n);
      enqueued++;
      AppLogger.notification.i('battleInviteToast:enqueue', fields: {
        'notifId': n.id,
        'battleId': (n.data['battle_id'] ?? n.data['battleId'])?.toString(),
        'isDaily': _isDaily(n),
      });
    }
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
    final battleId =
        (current.data['battle_id'] ?? current.data['battleId'])?.toString();
    if (battleId == null || battleId.isEmpty) {
      setState(() => _current = null);
      _promoteNext();
      return;
    }
    AcceptInviteOutcome? outcome;
    try {
      outcome = await ref.read(battleServiceProvider).acceptInvite(
            battleId: battleId,
            userId: myUid,
          );
      await _markNotificationRead(current.id);
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
      AppLogger.battle.e('battleInviteToast:acceptFailed',
          fields: {'battleId': battleId}, error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not accept invite: $e')),
        );
      }
    }
    if (!mounted) return;
    setState(() => _current = null);
    _promoteNext();

    // Daily-series accept lands in the same shape as the
    // notifications_sheet path: SnackBar for confirmation. Regular
    // 1v1 accepts don't need extra chrome — the battle card appears
    // in Home via realtime.
    if (outcome == AcceptInviteOutcome.dailySeriesFirstJoin && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("You're in! Battle is live now."),
          duration: Duration(seconds: 4),
        ),
      );
    }
    // Nav: land on Battles tab so the user sees the freshly-active
    // battle card. Only nav on successful outcome (accept threw →
    // outcome is null and we stay put so the snackbar is visible).
    if (outcome != null && mounted) {
      context.go('/battles');
    }
  }

  /// Explicit tap on the X (decline) button on the toast.
  ///
  /// Fires `rejectInvite` server-side + marks the notification row read.
  /// This is the "user actively said no" path — distinct from
  /// [_onTimeout] which fires when the 5-sec auto-dismiss expires and
  /// must NOT reject.
  Future<void> _onDecline() async {
    final current = _current;
    if (current == null) return;
    final myUid = Supabase.instance.client.auth.currentUser?.id;
    if (myUid == null) return;
    final battleId =
        (current.data['battle_id'] ?? current.data['battleId'])?.toString();
    if (battleId == null || battleId.isEmpty) {
      setState(() => _current = null);
      _promoteNext();
      return;
    }
    try {
      await ref.read(battleServiceProvider).rejectInvite(
            battleId: battleId,
            userId: myUid,
          );
      await _markNotificationRead(current.id);
    } catch (e) {
      AppLogger.battle.e('battleInviteToast:rejectFailed',
          fields: {'battleId': battleId}, error: e);
    }
    if (!mounted) return;
    setState(() => _current = null);
    _promoteNext();
  }

  /// Auto-dismiss expired (5s of inactivity). Semantically different
  /// from [_onDecline]:
  ///   - Do NOT call `rejectInvite`. The invite remains valid.
  ///   - Do NOT mark the notification read. It stays unread in the
  ///     bell so the user can still act on it later from there.
  ///   - Just clear the toast's current slot + promote the next
  ///     queued invite so the queue keeps flowing.
  ///
  /// Bug context (fixed 1.1.6+27): prior versions used `_onDecline`
  /// as the timeout handler, which silently rejected invites the user
  /// simply didn't get to in 5 seconds. Reported 2026-08-17: sender
  /// saw "invite rejected" after invitee didn't tap.
  void _onTimeout() {
    final current = _current;
    if (current == null) return;
    AppLogger.notification.i('battleInviteToast:timeout', fields: {
      'notifId': current.id,
      'battleId': (current.data['battle_id'] ?? current.data['battleId'])
          ?.toString(),
    });
    if (!mounted) return;
    setState(() => _current = null);
    _promoteNext();
  }

  Future<void> _markNotificationRead(String notificationId) async {
    try {
      await Supabase.instance.client
          .from('notifications')
          .update({'read': true})
          .eq('id', notificationId);
    } catch (_) {
      // Best-effort — the toast dismissal shouldn't block on this.
    }
  }

  @override
  Widget build(BuildContext context) {
    // Reset state on sign-in / sign-out so the new identity re-seeds
    // its backlog and doesn't inherit the previous user's queue.
    ref.listen(authStateProvider, (prev, next) {
      final prevUid = prev?.valueOrNull?.id;
      final nextUid = next.valueOrNull?.id;
      if (prevUid != nextUid) {
        _initialized = false;
        _seenIds.clear();
        _queue.clear();
        if (mounted) setState(() => _current = null);
      }
    });

    // Drive the toast queue off the notifications realtime stream.
    // The provider is non-autoDispose (see notification_provider.dart)
    // so we share the same subscription the bell badge is using — no
    // duplicate realtime channel.
    ref.listen<AsyncValue<List<NotificationModel>>>(notificationsProvider,
        (prev, next) {
      final list = next.valueOrNull;
      if (list == null) return;
      _ingest(list);
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
              child: BattleInviteToast(
                // Key by notification id so a new invite rebuilds the
                // widget (re-runs entry animation + auto-dismiss timer)
                // rather than reusing state.
                key: ValueKey(current.id),
                title: current.title,
                body: current.body,
                isDaily: _isDaily(current),
                onAccept: _onAccept,
                onDecline: _onDecline,
                onTimeout: _onTimeout,
              ),
            ),
          ),
      ],
    );
  }
}
