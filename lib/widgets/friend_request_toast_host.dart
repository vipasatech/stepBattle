import 'dart:collection';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/friend_relationship_model.dart';
import '../models/user_model.dart';
import '../providers/friend_provider.dart';
import '../providers/notification_provider.dart';
import 'friend_request_toast.dart';

/// Wraps the navigation shell so a non-blocking friend-request toast can
/// slide in from the top whenever a new pending friend-request relationship
/// is detected for the signed-in user.
///
/// We deliberately seed [_seenIds] with the relationship IDs visible on
/// first build — those represent a pre-existing backlog the user can find
/// in the notifications tab. Toasts only fire for genuinely new arrivals
/// during the current session.
class FriendRequestToastHost extends ConsumerStatefulWidget {
  final Widget child;

  const FriendRequestToastHost({super.key, required this.child});

  @override
  ConsumerState<FriendRequestToastHost> createState() =>
      _FriendRequestToastHostState();
}

class _FriendRequestToastHostState
    extends ConsumerState<FriendRequestToastHost> {
  bool _initialized = false;
  final Set<String> _seenIds = {};
  final Queue<({FriendRelationship rel, UserModel user})> _queue = Queue();
  ({FriendRelationship rel, UserModel user})? _current;

  void _ingest(List<({FriendRelationship rel, UserModel user})> profiles) {
    if (!_initialized) {
      // First emission — backlog only. Mark as seen, no toasts.
      for (final p in profiles) {
        _seenIds.add(p.rel.relationshipId);
      }
      _initialized = true;
      return;
    }

    var enqueued = false;
    for (final p in profiles) {
      if (_seenIds.contains(p.rel.relationshipId)) continue;
      _seenIds.add(p.rel.relationshipId);
      _queue.add(p);
      enqueued = true;
    }
    if (enqueued) _promoteNext();
  }

  void _promoteNext() {
    if (_current != null) return;
    if (_queue.isEmpty) return;
    setState(() => _current = _queue.removeFirst());
  }

  Future<void> _onAccept() async {
    final current = _current;
    if (current == null) return;
    try {
      await ref
          .read(friendServiceProvider)
          .acceptRequest(current.rel.relationshipId);
      // Mark any matching notification as read so the bell badge decrements.
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid != null) {
        await _markFriendRequestNotificationRead(uid, current.rel);
      }
    } catch (_) {
      // Swallow — failure surfaces via friend.log; user can retry from the
      // notifications tab.
    }
    if (!mounted) return;
    setState(() => _current = null);
    _promoteNext();
  }

  void _onDismiss() {
    if (!mounted) return;
    // Leave the notification unread so the user can still find it in the
    // notifications tab. Local "don't reshow" tracking happens via _seenIds.
    setState(() => _current = null);
    _promoteNext();
  }

  Future<void> _markFriendRequestNotificationRead(
      String uid, FriendRelationship rel) async {
    final notifications = ref.read(notificationsProvider).valueOrNull ?? [];
    for (final n in notifications) {
      if (n.read) continue;
      // Supabase writers stamp snake_case (`relationship_id`); legacy
      // camelCase fallback covers any pre-migration rows.
      final relId = n.data['relationship_id'] ?? n.data['relationshipId'];
      if (relId == rel.relationshipId) {
        await markNotificationRead(n.id);
        break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // The stream emits its current backlog as its first value, which we use
    // to seed `_seenIds` without firing toasts (see `_ingest`).
    ref.listen<AsyncValue<List<({FriendRelationship rel, UserModel user})>>>(
      incomingRequestProfilesProvider,
      (prev, next) {
        final profiles = next.valueOrNull;
        if (profiles == null) return;
        _ingest(profiles);
      },
    );

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
              child: FriendRequestToast(
                // Key by relationshipId so a new arrival rebuilds the toast
                // (re-runs entry animation) rather than reusing state.
                key: ValueKey(current.rel.relationshipId),
                displayName: current.user.displayName,
                avatarUrl: current.user.avatarURL,
                onAccept: _onAccept,
                onDismiss: _onDismiss,
              ),
            ),
          ),
      ],
    );
  }
}
