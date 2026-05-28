import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/colors.dart';
import '../models/user_model.dart';
import '../providers/auth_provider.dart';
import '../providers/friend_provider.dart';
import '../widgets/avatar_circle.dart';
import '../widgets/bottom_sheet_handle.dart';

/// Behavior of the Add Friends sheet.
enum FriendsSheetMode {
  /// Pick N people to perform an action on (e.g., invite to a clan).
  /// Friend rows show a select chip; bottom CTA is enabled when selections exist.
  picker,

  /// Browse + manage friends. No selection chips, no bottom CTA.
  /// Friend rows show a kebab menu with "Remove friend".
  /// Requests tab includes both Incoming (Accept/Reject) and Sent (Cancel).
  manage,
}

/// Reusable Add Friends bottom sheet with 3 tabs:
///   Friends — accepted friends. In picker mode shows selection chips;
///             in manage mode shows a kebab with "Remove friend".
///   Search  — by @username or #UserCode; tap "Request" to send.
///   Requests — incoming pending (Accept/Reject); in manage mode also
///              shows your sent requests (Cancel).
class AddFriendsSheet extends ConsumerStatefulWidget {
  final FriendsSheetMode mode;
  final bool multiSelect;
  final String confirmLabel;
  final int initialTab;
  final void Function(List<UserModel> selected)? onConfirm;

  const AddFriendsSheet({
    super.key,
    this.mode = FriendsSheetMode.picker,
    this.multiSelect = true,
    this.confirmLabel = 'Confirm Selection',
    this.initialTab = 0,
    this.onConfirm,
  });

  /// Whether selection UI should be visible (picker mode + not Requests tab).
  bool get _allowSelect => mode == FriendsSheetMode.picker;

  @override
  ConsumerState<AddFriendsSheet> createState() => _AddFriendsSheetState();
}

class _AddFriendsSheetState extends ConsumerState<AddFriendsSheet> {
  late int _tabIndex;
  final _searchController = TextEditingController();
  final Set<String> _selectedIds = {};
  List<UserModel> _searchResults = [];
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _tabIndex = widget.initialTab.clamp(0, 2);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _toggleSelect(UserModel user) {
    setState(() {
      if (widget.multiSelect) {
        if (_selectedIds.contains(user.userId)) {
          _selectedIds.remove(user.userId);
        } else {
          _selectedIds.add(user.userId);
        }
      } else {
        _selectedIds
          ..clear()
          ..add(user.userId);
      }
    });
  }

  Future<void> _search() async {
    final q = _searchController.text.trim();
    if (q.isEmpty) return;
    setState(() => _searching = true);
    try {
      final results = await ref.read(friendServiceProvider).search(q);
      setState(() => _searchResults = results);
    } catch (_) {}
    setState(() => _searching = false);
  }

  Future<void> _sendRequest(UserModel target) async {
    final me = ref.read(currentUserProvider).valueOrNull;
    if (me == null) return;
    try {
      await ref.read(friendServiceProvider).sendRequest(
            fromUserId: me.userId,
            toUserId: target.userId,
            fromDisplayName:
                me.displayName.isEmpty ? 'Someone' : me.displayName,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Friend request sent to ${target.displayName}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send request: $e')),
        );
      }
    }
  }

  Future<void> _removeFriend(UserModel friend) async {
    final me = Supabase.instance.client.auth.currentUser;
    if (me == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainerLow,
        title: Text('Remove ${friend.displayName}?'),
        content: const Text(
            'They will no longer appear in your friends list. You can re-add them later.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ref.read(friendServiceProvider).removeFriend(
            userId: me.id,
            friendId: friend.userId,
          );
      ref.invalidate(friendsListProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${friend.displayName} removed from friends')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not remove: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final friends = ref.watch(friendsListProvider);
    final incomingCount = ref.watch(incomingRequestCountProvider);
    final currentUid = Supabase.instance.client.auth.currentUser?.id ?? '';

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A1C),
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          children: [
            const BottomSheetHandle(),

            // Title — copy adapts to mode
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  widget.mode == FriendsSheetMode.manage
                      ? 'Friends'
                      : 'Add Friends',
                  style: theme.textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 3-tab segmented control
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  children: [
                    _Tab(
                      label: 'Friends',
                      isActive: _tabIndex == 0,
                      onTap: () => setState(() => _tabIndex = 0),
                    ),
                    _Tab(
                      label: 'Search',
                      isActive: _tabIndex == 1,
                      onTap: () => setState(() => _tabIndex = 1),
                    ),
                    _Tab(
                      label: 'Requests',
                      badge: incomingCount,
                      isActive: _tabIndex == 2,
                      onTap: () => setState(() => _tabIndex = 2),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            Expanded(
              child: switch (_tabIndex) {
                0 => _FriendsListTab(
                    friends: friends.valueOrNull ?? [],
                    selectedIds: _selectedIds,
                    currentUid: currentUid,
                    allowSelect: widget._allowSelect,
                    isManageMode:
                        widget.mode == FriendsSheetMode.manage,
                    onToggle: _toggleSelect,
                    onRemove: _removeFriend,
                    scrollController: scrollController,
                  ),
                1 => _SearchTab(
                    searchController: _searchController,
                    results: _searchResults,
                    searching: _searching,
                    currentUid: currentUid,
                    onSearch: _search,
                    onSendRequest: _sendRequest,
                    scrollController: scrollController,
                    // Picker-mode params: surface the same "+ Select"
                    // selection chip the Friends tab uses, alongside the
                    // friend-request action.
                    allowSelect: widget._allowSelect,
                    selectedIds: _selectedIds,
                    onToggleSelect: _toggleSelect,
                  ),
                _ => _RequestsTab(
                    scrollController: scrollController,
                    showOutgoing:
                        widget.mode == FriendsSheetMode.manage,
                  ),
              },
            ),

            // Bottom confirm bar — picker mode, on Friends OR Search tab
            // (the Requests tab still hides it since incoming requests are
            // resolved with their own per-row Accept/Reject actions).
            if (widget._allowSelect && _tabIndex != 2)
              Container(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      const Color(0xFF1A1A1C).withValues(alpha: 0),
                      const Color(0xFF1A1A1C),
                    ],
                  ),
                ),
                child: SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    onPressed: _selectedIds.isEmpty
                        ? null
                        : () {
                            final allUsers = <UserModel>[
                              ...(friends.valueOrNull ?? <UserModel>[]),
                              ..._searchResults,
                            ];
                            final selected = allUsers
                                .where((u) => _selectedIds.contains(u.userId))
                                .toList();
                            widget.onConfirm?.call(selected);
                            Navigator.pop(context);
                          },
                    child: Text(widget.confirmLabel),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Tab button
// =============================================================================
class _Tab extends StatelessWidget {
  final String label;
  final int badge;
  final bool isActive;
  final VoidCallback onTap;

  const _Tab({
    required this.label,
    this.badge = 0,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isActive ? AppColors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: isActive
                        ? AppColors.onPrimary
                        : AppColors.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  )),
              if (badge > 0) ...[
                const SizedBox(width: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: isActive ? AppColors.onPrimary : AppColors.error,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$badge',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      color: isActive ? AppColors.primary : Colors.white,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Tab 1: Friends List
// =============================================================================
class _FriendsListTab extends StatelessWidget {
  final List<UserModel> friends;
  final Set<String> selectedIds;
  final String currentUid;
  final bool allowSelect;
  final bool isManageMode;
  final void Function(UserModel) onToggle;
  final Future<void> Function(UserModel) onRemove;
  final ScrollController scrollController;

  const _FriendsListTab({
    required this.friends,
    required this.selectedIds,
    required this.currentUid,
    required this.allowSelect,
    required this.isManageMode,
    required this.onToggle,
    required this.onRemove,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    if (friends.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('No friends yet. Use the Search tab to find people.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.onSurfaceVariant),
              textAlign: TextAlign.center),
        ),
      );
    }
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      itemCount: friends.length,
      itemBuilder: (_, i) {
        final f = friends[i];
        if (f.userId == currentUid) return const SizedBox();
        return _UserRow(
          user: f,
          selected: selectedIds.contains(f.userId),
          showSelect: allowSelect,
          onTap: allowSelect ? () => onToggle(f) : null,
          trailing: isManageMode
              ? _FriendKebab(onRemove: () => onRemove(f))
              : null,
        );
      },
    );
  }
}

class _FriendKebab extends StatelessWidget {
  final VoidCallback onRemove;
  const _FriendKebab({required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, color: AppColors.onSurfaceVariant),
      color: AppColors.surfaceContainerHigh,
      onSelected: (v) {
        if (v == 'remove') onRemove();
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'remove',
          child: Row(
            children: [
              Icon(Icons.person_remove, size: 18, color: AppColors.error),
              SizedBox(width: 10),
              Text('Remove friend',
                  style: TextStyle(color: AppColors.error)),
            ],
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Tab 2: Search
// =============================================================================
class _SearchTab extends StatelessWidget {
  final TextEditingController searchController;
  final List<UserModel> results;
  final bool searching;
  final String currentUid;
  final VoidCallback onSearch;
  final Future<void> Function(UserModel) onSendRequest;
  final ScrollController scrollController;

  /// True when the sheet is in picker mode (e.g., opened from "Select
  /// Opponent" in the battle setup). Adds a primary "+ Select" chip to
  /// each row, alongside the friend-request button — so the user can
  /// pick someone they're not yet friends with AND optionally send them
  /// a friend request from the same row.
  final bool allowSelect;
  final Set<String> selectedIds;
  final void Function(UserModel) onToggleSelect;

  const _SearchTab({
    required this.searchController,
    required this.results,
    required this.searching,
    required this.currentUid,
    required this.onSearch,
    required this.onSendRequest,
    required this.scrollController,
    this.allowSelect = false,
    this.selectedIds = const {},
    required this.onToggleSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: TextField(
            controller: searchController,
            onSubmitted: (_) => onSearch(),
            decoration: InputDecoration(
              hintText: 'Enter @username or #CODE',
              prefixIcon: const Icon(Icons.search, color: AppColors.outline),
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward, size: 20),
                onPressed: onSearch,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: searching
              ? const Center(
                  child: CircularProgressIndicator(color: AppColors.primary))
              : results.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text('Search by username or user code',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: AppColors.onSurfaceVariant)),
                      ),
                    )
                  : ListView.builder(
                      controller: scrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      itemCount: results.length,
                      itemBuilder: (_, i) {
                        final u = results[i];
                        if (u.userId == currentUid) return const SizedBox();
                        // Picker mode: small friend-request icon + big
                        // "Select" chip. Manage mode: just the full
                        // three-state friend-request button.
                        final trailing = allowSelect
                            ? _PickerSearchTrailing(
                                user: u,
                                isSelected:
                                    selectedIds.contains(u.userId),
                                onToggleSelect: () => onToggleSelect(u),
                                onSendRequest: onSendRequest,
                              )
                            : _RequestButton(
                                target: u,
                                onSend: onSendRequest,
                              );
                        return _UserRow(
                          user: u,
                          showSelect: false,
                          trailing: trailing,
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

// =============================================================================
// Dual-action search-row trailing (picker mode only)
//
// Renders a primary "+ Select" / "✓ Selected" chip and a small icon-sized
// friend-request button to its left. Both actions are independent — selecting
// for a battle doesn't auto-send a friend request, and vice versa.
// =============================================================================
class _PickerSearchTrailing extends ConsumerStatefulWidget {
  final UserModel user;
  final bool isSelected;
  final VoidCallback onToggleSelect;
  final Future<void> Function(UserModel) onSendRequest;

  const _PickerSearchTrailing({
    required this.user,
    required this.isSelected,
    required this.onToggleSelect,
    required this.onSendRequest,
  });

  @override
  ConsumerState<_PickerSearchTrailing> createState() =>
      _PickerSearchTrailingState();
}

class _PickerSearchTrailingState
    extends ConsumerState<_PickerSearchTrailing> {
  bool _sendingFriend = false;

  Future<void> _sendFriendRequest() async {
    setState(() => _sendingFriend = true);
    try {
      await widget.onSendRequest(widget.user);
    } finally {
      if (mounted) setState(() => _sendingFriend = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final friendIds = ref.watch(acceptedFriendIdsProvider);
    final outgoing =
        ref.watch(outgoingRequestsProvider).valueOrNull ?? const [];
    final isFriend = friendIds.contains(widget.user.userId);
    final hasPending =
        outgoing.any((r) => r.toUserId == widget.user.userId);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Compact friend-request indicator. Three derived states match the
        // bigger _RequestButton — kept icon-only here to leave room for
        // the primary Select chip.
        if (isFriend)
          _SmallChip(
            icon: Icons.check,
            tooltip: 'Already friends',
            background: AppColors.success.withValues(alpha: 0.15),
            foreground: AppColors.success,
            onTap: null,
          )
        else if (hasPending)
          _SmallChip(
            icon: Icons.schedule,
            tooltip: 'Request sent',
            background: AppColors.surfaceContainerHigh,
            foreground: AppColors.onSurfaceVariant,
            onTap: null,
          )
        else if (_sendingFriend)
          const SizedBox(
            width: 36,
            height: 36,
            child: Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.primary),
              ),
            ),
          )
        else
          _SmallChip(
            icon: Icons.person_add,
            tooltip: 'Send friend request',
            background: AppColors.surfaceContainerHigh,
            foreground: AppColors.primary,
            onTap: _sendFriendRequest,
          ),
        const SizedBox(width: 8),

        // Primary "Select" pill — same look as the Friends tab's chip
        // so users can tell this is the action that confirms picking
        // this person as the opponent / battle invitee.
        GestureDetector(
          onTap: widget.onToggleSelect,
          child: widget.isSelected
              ? Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.success.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: AppColors.success.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle,
                          size: 16, color: AppColors.success),
                      const SizedBox(width: 4),
                      Text('Selected',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: AppColors.success,
                            fontWeight: FontWeight.w700,
                          )),
                    ],
                  ),
                )
              : Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.primaryBrand,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.add, size: 16, color: Colors.white),
                      const SizedBox(width: 4),
                      Text('Select',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          )),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

class _SmallChip extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color background;
  final Color foreground;
  final VoidCallback? onTap;

  const _SmallChip({
    required this.icon,
    required this.tooltip,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, size: 18, color: foreground),
        ),
      ),
    );
  }
}

// =============================================================================
// Tab 3: Requests
//   Always: Incoming (Accept / Reject)
//   When showOutgoing: also Sent (Cancel) — manage mode only
// =============================================================================
class _RequestsTab extends ConsumerWidget {
  final ScrollController scrollController;
  final bool showOutgoing;

  const _RequestsTab({
    required this.scrollController,
    required this.showOutgoing,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final incoming = ref.watch(incomingRequestProfilesProvider);
    final outgoing = ref.watch(outgoingRequestProfilesProvider);

    if (incoming.isLoading || (showOutgoing && outgoing.isLoading)) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.primary));
    }
    if (incoming.hasError || (showOutgoing && outgoing.hasError)) {
      return const Center(child: Text('Could not load requests'));
    }

    final incomingList = incoming.valueOrNull ?? [];
    final outgoingList = showOutgoing ? (outgoing.valueOrNull ?? []) : const [];

    if (incomingList.isEmpty && outgoingList.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.inbox,
                  size: 48,
                  color: AppColors.onSurfaceVariant
                      .withValues(alpha: 0.4)),
              const SizedBox(height: 12),
              Text('No pending requests',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: AppColors.onSurfaceVariant),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      children: [
        if (incomingList.isNotEmpty) ...[
          _SectionLabel(label: 'INCOMING', count: incomingList.length),
          for (final item in incomingList)
            _IncomingRequestRow(
              user: item.user,
              relationshipId: item.rel.relationshipId,
            ),
        ],
        if (showOutgoing && outgoingList.isNotEmpty) ...[
          const SizedBox(height: 16),
          _SectionLabel(label: 'SENT', count: outgoingList.length),
          for (final item in outgoingList)
            _OutgoingRequestRow(
              user: item.user,
              relationshipId: item.rel.relationshipId,
            ),
        ],
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  final int count;
  const _SectionLabel({required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 10),
      child: Row(
        children: [
          Text(label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w800,
              )),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('$count',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w900,
                  fontSize: 10,
                )),
          ),
        ],
      ),
    );
  }
}

class _OutgoingRequestRow extends ConsumerStatefulWidget {
  final UserModel user;
  final String relationshipId;

  const _OutgoingRequestRow({
    required this.user,
    required this.relationshipId,
  });

  @override
  ConsumerState<_OutgoingRequestRow> createState() =>
      _OutgoingRequestRowState();
}

class _OutgoingRequestRowState extends ConsumerState<_OutgoingRequestRow> {
  bool _processing = false;

  Future<void> _cancel() async {
    setState(() => _processing = true);
    try {
      await ref
          .read(friendServiceProvider)
          .cancelRequest(widget.relationshipId);
    } catch (_) {}
    if (mounted) setState(() => _processing = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          AvatarCircle(
            radius: 22,
            imageUrl: widget.user.avatarURL,
            initials: widget.user.displayName.isNotEmpty
                ? widget.user.displayName[0].toUpperCase()
                : '?',
            borderColor: AppColors.outlineVariant,
            borderWidth: 1,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.user.displayName,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                Text('Waiting for response',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: AppColors.onSurfaceVariant)),
              ],
            ),
          ),
          if (_processing)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.primary),
            )
          else
            OutlinedButton(
              onPressed: _cancel,
              style: OutlinedButton.styleFrom(
                side: BorderSide(
                    color: AppColors.error.withValues(alpha: 0.4)),
                foregroundColor: AppColors.error,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              ),
              child: const Text('Cancel'),
            ),
        ],
      ),
    );
  }
}

class _IncomingRequestRow extends ConsumerStatefulWidget {
  final UserModel user;
  final String relationshipId;

  const _IncomingRequestRow(
      {required this.user, required this.relationshipId});

  @override
  ConsumerState<_IncomingRequestRow> createState() =>
      _IncomingRequestRowState();
}

class _IncomingRequestRowState extends ConsumerState<_IncomingRequestRow> {
  bool _processing = false;

  Future<void> _accept() async {
    setState(() => _processing = true);
    try {
      await ref.read(friendServiceProvider).acceptRequest(widget.relationshipId);
    } catch (_) {}
    if (mounted) setState(() => _processing = false);
  }

  Future<void> _reject() async {
    setState(() => _processing = true);
    try {
      await ref.read(friendServiceProvider).rejectRequest(widget.relationshipId);
    } catch (_) {}
    if (mounted) setState(() => _processing = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          AvatarCircle(
            radius: 26,
            imageUrl: widget.user.avatarURL,
            initials: widget.user.displayName.isNotEmpty
                ? widget.user.displayName[0].toUpperCase()
                : '?',
            borderColor: AppColors.primary.withValues(alpha: 0.2),
            borderWidth: 2,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.user.displayName,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                Text(widget.user.userCode,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: AppColors.onSurfaceVariant)),
              ],
            ),
          ),
          if (_processing)
            const SizedBox(
              width: 18,
              height: 18,
              child:
                  CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
            )
          else ...[
            IconButton(
              onPressed: _reject,
              icon: const Icon(Icons.close, color: AppColors.error, size: 20),
              tooltip: 'Reject',
            ),
            FilledButton.icon(
              onPressed: _accept,
              icon: const Icon(Icons.check, size: 16),
              label: const Text('Accept'),
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// =============================================================================
// Shared user row
// =============================================================================
class _UserRow extends StatelessWidget {
  final UserModel user;
  final bool selected;
  final bool showSelect;
  final VoidCallback? onTap;
  final Widget? trailing;

  const _UserRow({
    required this.user,
    this.selected = false,
    this.showSelect = true,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          AvatarCircle(
            radius: 26,
            imageUrl: user.avatarURL,
            initials: user.displayName.isNotEmpty
                ? user.displayName[0].toUpperCase()
                : '?',
            borderColor: AppColors.primary.withValues(alpha: 0.2),
            borderWidth: 2,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(user.displayName,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                Text(
                  user.userCode.isNotEmpty
                      ? '${user.userCode} · Level ${user.level}'
                      : 'Level ${user.level} · Rank #${user.rank}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (trailing != null)
            trailing!
          else if (showSelect)
            GestureDetector(
              onTap: onTap,
              child: selected
                  ? Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppColors.success.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: AppColors.success.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check_circle,
                              size: 16, color: AppColors.success),
                          const SizedBox(width: 4),
                          Text('Added',
                              style: theme.textTheme.labelSmall?.copyWith(
                                  color: AppColors.success,
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                    )
                  : Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.primaryBrand,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child:
                          const Icon(Icons.add, size: 18, color: Colors.white),
                    ),
            ),
        ],
      ),
    );
  }
}

// =============================================================================
// Three-state request button (used in the Search tab)
//
//   Friends   — already accepted; disabled, success-green
//   Sent      — outgoing pending request; disabled
//   Accept    — they sent us; one-tap accept from search
//   Request   — default; tap to send
//
// State is computed from the user's own friends array and the live
// incoming/outgoing relationship streams, so the row updates instantly when
// the recipient accepts.
// =============================================================================
class _RequestButton extends ConsumerStatefulWidget {
  final UserModel target;
  final Future<void> Function(UserModel) onSend;

  const _RequestButton({required this.target, required this.onSend});

  @override
  ConsumerState<_RequestButton> createState() => _RequestButtonState();
}

class _RequestButtonState extends ConsumerState<_RequestButton> {
  bool _processing = false;

  Future<void> _send() async {
    setState(() => _processing = true);
    try {
      await widget.onSend(widget.target);
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _acceptInbound(String relationshipId) async {
    setState(() => _processing = true);
    try {
      await ref.read(friendServiceProvider).acceptRequest(relationshipId);
    } catch (_) {}
    if (mounted) setState(() => _processing = false);
  }

  @override
  Widget build(BuildContext context) {
    final friendIds = ref.watch(acceptedFriendIdsProvider);
    final outgoing = ref.watch(outgoingRequestsProvider).valueOrNull ?? const [];
    final incoming = ref.watch(incomingRequestsProvider).valueOrNull ?? const [];

    if (_processing) {
      return const SizedBox(
        width: 36,
        height: 36,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: AppColors.primary),
          ),
        ),
      );
    }

    final isFriend = friendIds.contains(widget.target.userId);
    if (isFriend) {
      return FilledButton.icon(
        icon: const Icon(Icons.check, size: 16),
        label: const Text('Friends'),
        onPressed: null,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.success.withValues(alpha: 0.18),
          disabledBackgroundColor: AppColors.success.withValues(alpha: 0.18),
          foregroundColor: AppColors.success,
          disabledForegroundColor: AppColors.success,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      );
    }

    final inboundRel = incoming
        .where((r) => r.fromUserId == widget.target.userId)
        .firstOrNull;
    if (inboundRel != null) {
      return FilledButton.icon(
        icon: const Icon(Icons.check, size: 16),
        label: const Text('Accept'),
        onPressed: () => _acceptInbound(inboundRel.relationshipId),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      );
    }

    final hasOutgoing =
        outgoing.any((r) => r.toUserId == widget.target.userId);
    if (hasOutgoing) {
      return FilledButton.icon(
        icon: const Icon(Icons.schedule, size: 16),
        label: const Text('Sent'),
        onPressed: null,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.surfaceContainerHigh,
          disabledBackgroundColor: AppColors.surfaceContainerHigh,
          foregroundColor: AppColors.onSurfaceVariant,
          disabledForegroundColor: AppColors.onSurfaceVariant,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
      );
    }

    return FilledButton.icon(
      icon: const Icon(Icons.person_add, size: 16),
      label: const Text('Request'),
      onPressed: _send,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
    );
  }
}
