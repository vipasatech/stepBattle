import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/colors.dart';
import '../models/notification_model.dart';
import '../providers/battle_provider.dart';
import '../providers/clan_provider.dart';
import '../providers/friend_provider.dart';
import '../providers/notification_provider.dart';
import '../services/battle_service.dart' show AcceptInviteOutcome;
import '../widgets/bottom_sheet_handle.dart';

/// Full-screen notifications surface. Reached from the bell icon in
/// the Home app-bar. Design follows the mockup the user shared:
///
///   ┌────────────────────────────────────────┐
///   │  ‹  Notifications              🔍     │  ← header
///   │  ┌───── search field ──────┐            │
///   │  [All] [Battles] [Friends]...  Mark all │  ← filter chips + action
///   │                                          │
///   │  TODAY                                   │  ← date group header
///   │  ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┐          │
///   │    🎯  Battle invite from Ravi         │  ← card
///   │        Wants to race you for 5,000 …    │
///   │        [Accept]  [Decline]              │  ← inline actions
///   │  └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┘  ● 5m   │
///   │                                          │
///   │  YESTERDAY                               │
///   │  ...                                     │
///   └────────────────────────────────────────┘
///
/// Filter chips let the user narrow the list by category (All /
/// Battles / Friends / Clan / Missions / Other). A client-side search
/// field further narrows by title/body substring. Both are pure
/// in-memory filters over the live stream from Supabase — no extra
/// round-trip on each change.
class NotificationsSheet extends ConsumerStatefulWidget {
  const NotificationsSheet({super.key});

  @override
  ConsumerState<NotificationsSheet> createState() =>
      _NotificationsSheetState();
}

class _NotificationsSheetState extends ConsumerState<NotificationsSheet> {
  final _searchController = TextEditingController();
  String _query = '';
  _Filter _filter = _Filter.all;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final all = ref.watch(notificationsProvider).valueOrNull ?? [];
    final filtered = _apply(all);
    final unreadCount = all.where((n) => !n.read).length;

    return DraggableScrollableSheet(
      // Near-full-height on open — the design is a full page, not a
      // half-sheet.
      initialChildSize: 0.95,
      minChildSize: 0.6,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          children: [
            const BottomSheetHandle(),

            // Header row: back button + centred title.
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  Expanded(
                    child: Center(
                      child: Text(
                        'Notifications',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                  // Right-side spacer that balances the leading arrow.
                  const SizedBox(width: 48),
                ],
              ),
            ),

            // Search field.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: _SearchField(
                controller: _searchController,
                onChanged: (v) => setState(() => _query = v.trim()),
              ),
            ),

            // Filter chips — same horizontally-scrollable outlined-pill
            // style the Leaderboard uses for scope tabs (Friends /
            // District / State / Country / World). The active chip is
            // brand-primary outline + text on transparent background;
            // inactive chips use a muted outline + onSurfaceVariant text.
            SizedBox(
              height: 42,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: _Filter.values.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final f = _Filter.values[i];
                  return Center(
                    child: _FilterChip(
                      label: f.label,
                      selected: f == _filter,
                      onTap: () => setState(() => _filter = f),
                    ),
                  );
                },
              ),
            ),
            // "Mark all as read" sits on its own row below the chips so
            // it doesn't compete with the chip scroll space. Hidden when
            // there's nothing unread.
            if (unreadCount > 0)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () async {
                      final uid =
                          Supabase.instance.client.auth.currentUser?.id;
                      if (uid != null) {
                        await markAllNotificationsRead(uid);
                      }
                    },
                    child: const Text(
                      'Mark all as read',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),

            // The list itself (or empty state).
            Expanded(
              child: filtered.isEmpty
                  ? const _EmptyState()
                  : _NotificationList(
                      groups: _groupByDate(filtered),
                      scrollController: scrollController,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Filter + search pipeline. Notifications are already sorted
  /// newest-first by the provider stream, so we only reduce here.
  List<NotificationModel> _apply(List<NotificationModel> all) {
    Iterable<NotificationModel> it = all;
    if (_filter != _Filter.all) {
      it = it.where((n) => _filter.matches(n.type));
    }
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      it = it.where((n) =>
          n.title.toLowerCase().contains(q) ||
          n.body.toLowerCase().contains(q));
    }
    return it.toList(growable: false);
  }

  /// Bucket notifications into date-labelled groups matching the
  /// mockup: "TODAY" / "YESTERDAY" / weekday name (last 6 days) /
  /// full date for anything older.
  List<_DateGroup> _groupByDate(List<NotificationModel> list) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final groups = <String, List<NotificationModel>>{};
    final order = <String>[];

    String labelFor(DateTime dt) {
      final d = DateTime(dt.year, dt.month, dt.day);
      final diff = today.difference(d).inDays;
      if (diff == 0) return 'Today';
      if (diff == 1) return 'Yesterday';
      if (diff > 1 && diff < 7) return _weekday(d.weekday);
      return _longDate(d);
    }

    for (final n in list) {
      final label = labelFor(n.createdAt.toLocal());
      if (!groups.containsKey(label)) {
        groups[label] = [];
        order.add(label);
      }
      groups[label]!.add(n);
    }
    return [
      for (final label in order)
        _DateGroup(label: label, items: groups[label]!),
    ];
  }

  static String _weekday(int w) => const [
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday',
      ][w - 1];

  static String _longDate(DateTime d) {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${_weekday(d.weekday)}, ${months[d.month - 1]} ${d.day}, ${d.year}';
  }
}

// =============================================================================
// Filter definitions
// =============================================================================

/// Top-of-list filter categories. Order matters — this is the tab
/// order shown to the user.
enum _Filter { all, battles, friends, clan, missions, other }

extension _FilterX on _Filter {
  String get label => switch (this) {
        _Filter.all => 'All',
        _Filter.battles => 'Battles',
        _Filter.friends => 'Friends',
        _Filter.clan => 'Clan',
        _Filter.missions => 'Missions',
        _Filter.other => 'Other',
      };

  bool matches(NotificationType t) => switch (this) {
        _Filter.all => true,
        // Daily-series lifecycle notifications bucket under Battles so
        // users looking there for "why did my daily stop?" find them.
        _Filter.battles => t == NotificationType.battleInvite ||
            t == NotificationType.battleStarted ||
            t == NotificationType.battleRejected ||
            t == NotificationType.battleResult ||
            t == NotificationType.dailySeriesDropped ||
            t == NotificationType.dailySeriesEnded,
        _Filter.friends => t == NotificationType.friendRequest ||
            t == NotificationType.friendAccepted,
        _Filter.clan => t == NotificationType.clanInvite,
        _Filter.missions => t == NotificationType.missionReset,
        _Filter.other =>
          t == NotificationType.levelUp || t == NotificationType.other,
      };
}

// =============================================================================
// Search field
// =============================================================================

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  const _SearchField({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      style: Theme.of(context).textTheme.bodyMedium,
      decoration: InputDecoration(
        hintText: 'Search notifications',
        prefixIcon: const Icon(Icons.search, size: 20),
        isDense: true,
        filled: true,
        fillColor: AppColors.surfaceContainerHigh,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide:
              BorderSide(color: AppColors.primary.withValues(alpha: 0.4)),
        ),
      ),
    );
  }
}

// =============================================================================
// Filter chip
// =============================================================================

/// Outlined-pill filter chip. Style matches the leaderboard's scope tabs
/// (`Friends / District / State / Country / World`) — brand-primary
/// outline + text when active, muted outline + `onSurfaceVariant` text
/// when inactive, transparent background either way.
class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: selected
                ? AppColors.primary
                : AppColors.outlineVariant.withValues(alpha: 0.55),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: 'Manrope',
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: selected
                ? AppColors.primary
                : AppColors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Empty state
// =============================================================================

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.notifications_none_rounded,
                size: 56,
                color: AppColors.primary.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              "Looks like there's nothing here",
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: AppColors.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Battle invites, friend requests, and clan updates will show up here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Grouped list
// =============================================================================

class _DateGroup {
  final String label;
  final List<NotificationModel> items;
  _DateGroup({required this.label, required this.items});
}

class _NotificationList extends StatelessWidget {
  final List<_DateGroup> groups;
  final ScrollController scrollController;
  const _NotificationList({
    required this.groups,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      itemCount: _totalRows(),
      itemBuilder: (_, i) => _rowAt(i),
    );
  }

  int _totalRows() {
    var n = 0;
    for (final g in groups) {
      n += 1 + g.items.length; // header + items
    }
    return n;
  }

  Widget _rowAt(int index) {
    var remaining = index;
    for (final g in groups) {
      if (remaining == 0) return _GroupHeader(label: g.label);
      remaining -= 1;
      if (remaining < g.items.length) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _NotificationCard(notification: g.items[remaining]),
        );
      }
      remaining -= g.items.length;
    }
    return const SizedBox.shrink();
  }
}

class _GroupHeader extends StatelessWidget {
  final String label;
  const _GroupHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 0, 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: AppColors.onSurfaceVariant,
          fontFamily: 'Manrope',
          fontWeight: FontWeight.w800,
          fontSize: 11,
          letterSpacing: 1.4,
        ),
      ),
    );
  }
}

// =============================================================================
// Notification card
// =============================================================================

class _NotificationCard extends ConsumerWidget {
  final NotificationModel notification;
  const _NotificationCard({required this.notification});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final (icon, colour) = _styleForType(notification.type);
    final isUnread = !notification.read;

    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () {
        if (isUnread) {
          markNotificationRead(notification.id);
        }
      },
      child: Ink(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top row: icon · body text · time + unread dot.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: colour.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: colour, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        notification.title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: AppColors.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        notification.body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (isUnread)
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: AppColors.primary,
                          shape: BoxShape.circle,
                        ),
                      )
                    else
                      const SizedBox(height: 8),
                    const SizedBox(height: 6),
                    Text(
                      _timeAgo(notification.createdAt),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.onSurfaceVariant
                            .withValues(alpha: 0.7),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            // Inline Accept / Decline for actionable notifications
            // (battle invite, friend request, clan invite).
            if (notification.isActionable) ...[
              const SizedBox(height: 12),
              _InviteActions(notification: notification),
            ],
          ],
        ),
      ),
    );
  }

  static (IconData, Color) _styleForType(NotificationType t) => switch (t) {
        NotificationType.friendRequest =>
          (Icons.person_add_alt_1, AppColors.primary),
        NotificationType.friendAccepted =>
          (Icons.check_circle_outline, AppColors.success),
        NotificationType.battleInvite =>
          (Icons.bolt_rounded, AppColors.amber),
        NotificationType.battleStarted =>
          (Icons.play_circle_outline, AppColors.success),
        NotificationType.battleRejected =>
          (Icons.close_rounded, AppColors.error),
        NotificationType.battleResult =>
          (Icons.emoji_events_outlined, AppColors.tertiary),
        // Series lifecycle: distinct icons so users immediately see the
        // difference between "you got dropped" (calendar-strike) and
        // "series ended for everyone" (stop-circle).
        NotificationType.dailySeriesDropped =>
          (Icons.event_busy_outlined, AppColors.error),
        NotificationType.dailySeriesEnded =>
          (Icons.stop_circle_outlined, AppColors.onSurfaceVariant),
        NotificationType.clanInvite =>
          (Icons.shield_outlined, AppColors.primary),
        NotificationType.levelUp =>
          (Icons.trending_up_rounded, AppColors.tertiary),
        NotificationType.missionReset =>
          (Icons.refresh_rounded, AppColors.onSurfaceVariant),
        NotificationType.other =>
          (Icons.notifications_none, AppColors.onSurfaceVariant),
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

// =============================================================================
// Invite actions — the inline Accept / Decline buttons
// =============================================================================

class _InviteActions extends ConsumerStatefulWidget {
  final NotificationModel notification;
  const _InviteActions({required this.notification});

  @override
  ConsumerState<_InviteActions> createState() => _InviteActionsState();
}

class _InviteActionsState extends ConsumerState<_InviteActions> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      await markNotificationRead(widget.notification.id);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Action failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _accept() => _run(() async {
        final n = widget.notification;
        final uid = Supabase.instance.client.auth.currentUser?.id;
        if (uid == null) return;
        if (n.type == NotificationType.friendRequest) {
          final relId = (n.data['relationship_id'] ??
              n.data['relationshipId']) as String?;
          if (relId != null) {
            await ref.read(friendServiceProvider).acceptRequest(relId);
          }
        } else if (n.type == NotificationType.battleInvite) {
          final battleId =
              (n.data['battle_id'] ?? n.data['battleId']) as String?;
          if (battleId != null) {
            final isTeam = n.data.containsKey('team_label');
            final outcome = await ref
                .read(battleServiceProvider)
                .acceptInvite(battleId: battleId, userId: uid);
            // Daily-series invitees now compete from the moment of accept
            // (Migration 0057, superseding 0056's "skip day 1" pattern).
            // Their Home battle list will show the battle immediately as
            // Live. The SnackBar is a light celebratory confirmation so
            // the accept action has a visible acknowledgement — the
            // Home update itself is realtime-driven and near-instant.
            if (outcome == AcceptInviteOutcome.dailySeriesFirstJoin &&
                mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text("You're in! Battle is live now."),
                  duration: Duration(seconds: 4),
                ),
              );
            }
            // Nav after accept — mirrors TeamLobbyInviteToastHost /
            // BattleInviteToastHost behavior so the accept path is the
            // same regardless of where the user tapped Accept. Close
            // the notifications sheet first so the destination is what
            // the user sees, not the sheet on top of it.
            if (mounted) {
              Navigator.of(context).maybePop();
            }
            if (mounted) {
              if (isTeam) {
                context.push('/team-lobby/$battleId');
              } else {
                context.go('/battles');
              }
            }
          }
        } else if (n.type == NotificationType.clanInvite) {
          final clanId =
              (n.data['clan_id'] ?? n.data['clanId']) as String?;
          if (clanId != null) {
            await ref
                .read(clanServiceProvider)
                .acceptClanInvite(clanId: clanId, userId: uid);
          }
        }
      });

  Future<void> _decline() => _run(() async {
        final n = widget.notification;
        final uid = Supabase.instance.client.auth.currentUser?.id;
        if (uid == null) return;
        if (n.type == NotificationType.friendRequest) {
          final relId = (n.data['relationship_id'] ??
              n.data['relationshipId']) as String?;
          if (relId != null) {
            await ref.read(friendServiceProvider).rejectRequest(relId);
          }
        } else if (n.type == NotificationType.battleInvite) {
          final battleId =
              (n.data['battle_id'] ?? n.data['battleId']) as String?;
          if (battleId != null) {
            await ref
                .read(battleServiceProvider)
                .rejectInvite(battleId: battleId, userId: uid);
          }
        } else if (n.type == NotificationType.clanInvite) {
          final clanId =
              (n.data['clan_id'] ?? n.data['clanId']) as String?;
          if (clanId != null) {
            await ref
                .read(clanServiceProvider)
                .rejectClanInvite(clanId: clanId, userId: uid);
          }
        }
      });

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.primary,
            ),
          ),
        ),
      );
    }
    // The button label text was invisible because the app's global
    // `filledButtonTheme` / `outlinedButtonTheme` sets vertical
    // padding to 16 dp; combined with a 14 dp font that's a 46 dp
    // intrinsic content height. Constraining the surrounding
    // SizedBox to 38 dp squeezed the text off-screen. Explicit
    // per-button padding + `tapTargetSize: shrinkWrap` locks the
    // button to a size the SizedBox can actually contain, and the
    // explicit `foregroundColor` on the text style guarantees the
    // label paints in the right ink even if a downstream ambient
    // DefaultTextStyle changes.
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 38,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                minimumSize: const Size.fromHeight(38),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              onPressed: _accept,
              child: const Text(
                'Accept',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: SizedBox(
            height: 38,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.onSurface,
                side: BorderSide(
                  color: AppColors.onSurface.withValues(alpha: 0.15),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                minimumSize: const Size.fromHeight(38),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              onPressed: _decline,
              child: Text(
                'Decline',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: AppColors.onSurface,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
