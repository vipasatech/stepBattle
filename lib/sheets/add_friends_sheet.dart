import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/colors.dart';
import '../models/user_model.dart';
import '../providers/friend_provider.dart';
import '../widgets/avatar_circle.dart';
import '../widgets/bottom_sheet_handle.dart';

/// Reusable Add Friends bottom sheet with 3 tabs:
///   Friends List — accepted friends (multi/single select mode)
///   Search — by @username or #UserCode
///   Requests — incoming pending requests with Accept/Reject
class AddFriendsSheet extends ConsumerStatefulWidget {
  final bool multiSelect;
  final bool allowSelect;
  final String confirmLabel;
  final int initialTab;
  final void Function(List<UserModel> selected)? onConfirm;

  const AddFriendsSheet({
    super.key,
    this.multiSelect = true,
    this.allowSelect = true,
    this.confirmLabel = 'Confirm Selection',
    this.initialTab = 0,
    this.onConfirm,
  });

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
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return;
    try {
      await ref.read(friendServiceProvider).sendRequest(
            fromUserId: me.uid,
            toUserId: target.userId,
            fromDisplayName: me.displayName ?? 'Someone',
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final friends = ref.watch(friendsListProvider);
    final incomingCount = ref.watch(incomingRequestCountProvider);
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';

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

            // Title
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Add Friends',
                    style: theme.textTheme.headlineMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
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
                    allowSelect: widget.allowSelect,
                    onToggle: _toggleSelect,
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
                  ),
                _ => _RequestsTab(scrollController: scrollController),
              },
            ),

            // Bottom confirm bar (only for selection mode on Friends tab)
            if (widget.allowSelect && _tabIndex == 0)
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
  final void Function(UserModel) onToggle;
  final ScrollController scrollController;

  const _FriendsListTab({
    required this.friends,
    required this.selectedIds,
    required this.currentUid,
    required this.allowSelect,
    required this.onToggle,
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
        );
      },
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

  const _SearchTab({
    required this.searchController,
    required this.results,
    required this.searching,
    required this.currentUid,
    required this.onSearch,
    required this.onSendRequest,
    required this.scrollController,
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
                        return _UserRow(
                          user: u,
                          showSelect: false,
                          trailing: FilledButton.icon(
                            icon: const Icon(Icons.person_add, size: 16),
                            label: const Text('Request'),
                            onPressed: () => onSendRequest(u),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

// =============================================================================
// Tab 3: Incoming Requests (Accept / Reject)
// =============================================================================
class _RequestsTab extends ConsumerWidget {
  final ScrollController scrollController;

  const _RequestsTab({required this.scrollController});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final requests = ref.watch(incomingRequestProfilesProvider);

    return requests.when(
      loading: () => const Center(
          child: CircularProgressIndicator(color: AppColors.primary)),
      error: (_, __) => const Center(child: Text('Could not load requests')),
      data: (list) {
        if (list.isEmpty) {
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
        return ListView.builder(
          controller: scrollController,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          itemCount: list.length,
          itemBuilder: (_, i) {
            final item = list[i];
            return _RequestRow(
              user: item.user,
              relationshipId: item.rel.relationshipId,
            );
          },
        );
      },
    );
  }
}

class _RequestRow extends ConsumerStatefulWidget {
  final UserModel user;
  final String relationshipId;

  const _RequestRow({required this.user, required this.relationshipId});

  @override
  ConsumerState<_RequestRow> createState() => _RequestRowState();
}

class _RequestRowState extends ConsumerState<_RequestRow> {
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
