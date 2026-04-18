import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/colors.dart';
import '../models/notification_model.dart';
import '../providers/battle_provider.dart';
import '../providers/clan_provider.dart';
import '../providers/friend_provider.dart';
import '../providers/notification_provider.dart';
import '../widgets/bottom_sheet_handle.dart';

/// Unified notifications sheet — shows friend requests, battle invites,
/// clan invites, level-ups, battle results, etc.
/// Actionable items (requests/invites) are shown first.
class NotificationsSheet extends ConsumerWidget {
  const NotificationsSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final notifications = ref.watch(notificationsProvider).valueOrNull ?? [];

    // Sort: actionable first, then by createdAt
    final sorted = [...notifications]..sort((a, b) {
        if (a.isActionable != b.isActionable) {
          return a.isActionable ? -1 : 1;
        }
        return b.createdAt.compareTo(a.createdAt);
      });

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: const BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          children: [
            const BottomSheetHandle(),

            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Notifications',
                        style: theme.textTheme.headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  if (sorted.any((n) => !n.read))
                    TextButton(
                      onPressed: () {
                        final uid = FirebaseAuth.instance.currentUser?.uid;
                        if (uid != null) markAllNotificationsRead(uid);
                      },
                      child: const Text('Mark all read'),
                    ),
                ],
              ),
            ),

            // List
            Expanded(
              child: sorted.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.notifications_none,
                                size: 48,
                                color: AppColors.onSurfaceVariant
                                    .withValues(alpha: 0.4)),
                            const SizedBox(height: 12),
                            Text('No notifications yet',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                    color: AppColors.onSurfaceVariant)),
                          ],
                        ),
                      ),
                    )
                  : ListView.separated(
                      controller: scrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      itemCount: sorted.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) =>
                          _NotificationTile(notification: sorted[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotificationTile extends ConsumerWidget {
  final NotificationModel notification;

  const _NotificationTile({required this.notification});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final (icon, color) = _styleForType(notification.type);

    return InkWell(
      onTap: () {
        if (!notification.read) {
          markNotificationRead(notification.id);
        }
      },
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: notification.read
              ? AppColors.surfaceContainerLow
              : AppColors.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
          border: !notification.read
              ? Border.all(color: AppColors.primary.withValues(alpha: 0.2))
              : null,
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(notification.title,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(notification.body,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: AppColors.onSurfaceVariant)),
                  const SizedBox(height: 6),
                  Text(_timeAgo(notification.createdAt),
                      style: theme.textTheme.labelSmall?.copyWith(
                          color:
                              AppColors.onSurfaceVariant.withValues(alpha: 0.6))),
                ],
              ),
            ),
            if (notification.isActionable)
              _ActionButtons(notification: notification, ref: ref),
          ],
        ),
      ),
    );
  }

  static (IconData, Color) _styleForType(NotificationType t) => switch (t) {
        NotificationType.friendRequest => (Icons.person_add, AppColors.primary),
        NotificationType.friendAccepted =>
          (Icons.check_circle, AppColors.success),
        NotificationType.battleInvite => (Icons.bolt, AppColors.amber),
        NotificationType.battleStarted => (Icons.play_circle, AppColors.success),
        NotificationType.battleRejected => (Icons.close, AppColors.error),
        NotificationType.battleResult =>
          (Icons.emoji_events, AppColors.tertiary),
        NotificationType.clanInvite => (Icons.shield, AppColors.primary),
        NotificationType.levelUp =>
          (Icons.trending_up, AppColors.tertiary),
        NotificationType.missionReset =>
          (Icons.refresh, AppColors.onSurfaceVariant),
        NotificationType.other =>
          (Icons.notifications, AppColors.onSurfaceVariant),
      };

  static String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}';
  }
}

class _ActionButtons extends StatefulWidget {
  final NotificationModel notification;
  final WidgetRef ref;

  const _ActionButtons({required this.notification, required this.ref});

  @override
  State<_ActionButtons> createState() => _ActionButtonsState();
}

class _ActionButtonsState extends State<_ActionButtons> {
  bool _busy = false;

  Future<void> _accept() async {
    setState(() => _busy = true);
    try {
      final n = widget.notification;
      final uid = FirebaseAuth.instance.currentUser?.uid;

      if (n.type == NotificationType.friendRequest) {
        final relId = n.data['relationshipId'] as String?;
        if (relId != null) {
          await widget.ref.read(friendServiceProvider).acceptRequest(relId);
        }
      } else if (n.type == NotificationType.battleInvite) {
        final battleId = n.data['battleId'] as String?;
        if (battleId != null && uid != null) {
          await widget.ref
              .read(battleServiceProvider)
              .acceptInvite(battleId: battleId, userId: uid);
        }
      } else if (n.type == NotificationType.clanInvite) {
        final clanId = n.data['clanId'] as String?;
        if (clanId != null && uid != null) {
          await widget.ref
              .read(clanServiceProvider)
              .acceptClanInvite(clanId: clanId, userId: uid);
        }
      }
      await markNotificationRead(n.id);
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _reject() async {
    setState(() => _busy = true);
    try {
      final n = widget.notification;
      final uid = FirebaseAuth.instance.currentUser?.uid;

      if (n.type == NotificationType.friendRequest) {
        final relId = n.data['relationshipId'] as String?;
        if (relId != null) {
          await widget.ref.read(friendServiceProvider).rejectRequest(relId);
        }
      } else if (n.type == NotificationType.battleInvite) {
        final battleId = n.data['battleId'] as String?;
        if (battleId != null && uid != null) {
          await widget.ref
              .read(battleServiceProvider)
              .rejectInvite(battleId: battleId, userId: uid);
        }
      } else if (n.type == NotificationType.clanInvite) {
        final clanId = n.data['clanId'] as String?;
        if (clanId != null && uid != null) {
          await widget.ref
              .read(clanServiceProvider)
              .rejectClanInvite(clanId: clanId, userId: uid);
        }
      }
      await markNotificationRead(n.id);
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
            strokeWidth: 2, color: AppColors.primary),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.check_circle,
              color: AppColors.success, size: 26),
          onPressed: _accept,
          tooltip: 'Accept',
          constraints: const BoxConstraints(),
          padding: EdgeInsets.zero,
        ),
        const SizedBox(height: 4),
        IconButton(
          icon: const Icon(Icons.cancel,
              color: AppColors.error, size: 26),
          onPressed: _reject,
          tooltip: 'Reject',
          constraints: const BoxConstraints(),
          padding: EdgeInsets.zero,
        ),
      ],
    );
  }
}
