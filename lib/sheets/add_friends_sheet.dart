import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/colors.dart';
import '../models/user_model.dart';
import '../providers/friend_provider.dart';
import '../widgets/avatar_circle.dart';
import '../widgets/bottom_sheet_handle.dart';

/// Reusable Add Friends bottom sheet — used from Battles, Clan, Profile.
/// [mode]: single (1v1 battle) or multi (group/clan).
/// [onConfirm]: callback with selected user(s).
class AddFriendsSheet extends ConsumerStatefulWidget {
  final bool multiSelect;
  final String confirmLabel;
  final void Function(List<UserModel> selected)? onConfirm;

  const AddFriendsSheet({
    super.key,
    this.multiSelect = true,
    this.confirmLabel = 'Confirm Selection',
    this.onConfirm,
  });

  @override
  ConsumerState<AddFriendsSheet> createState() => _AddFriendsSheetState();
}

class _AddFriendsSheetState extends ConsumerState<AddFriendsSheet> {
  int _tabIndex = 0; // 0 = Friends List, 1 = Search/User ID
  final _searchController = TextEditingController();
  final Set<String> _selectedIds = {};
  List<UserModel> _searchResults = [];
  bool _searching = false;

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
      final results =
          await ref.read(friendServiceProvider).searchByUsername(q);
      setState(() => _searchResults = results);
    } catch (_) {}
    setState(() => _searching = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final friends = ref.watch(friendsListProvider);
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
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

            // Tab toggle
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
                      label: 'Friends List',
                      isActive: _tabIndex == 0,
                      onTap: () => setState(() => _tabIndex = 0),
                    ),
                    _Tab(
                      label: 'Search / User ID',
                      isActive: _tabIndex == 1,
                      onTap: () => setState(() => _tabIndex = 1),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Search bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: TextField(
                controller: _searchController,
                onSubmitted: (_) => _tabIndex == 1 ? _search() : null,
                decoration: InputDecoration(
                  hintText: _tabIndex == 0
                      ? 'Search your friends...'
                      : 'Enter @username or User ID (e.g. #U4X92)',
                  prefixIcon:
                      const Icon(Icons.search, color: AppColors.outline),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // List
            Expanded(
              child: _tabIndex == 0
                  ? _FriendsList(
                      friends: friends.valueOrNull ?? [],
                      selectedIds: _selectedIds,
                      currentUid: currentUid,
                      onToggle: _toggleSelect,
                      scrollController: scrollController,
                    )
                  : _SearchList(
                      results: _searchResults,
                      searching: _searching,
                      selectedIds: _selectedIds,
                      currentUid: currentUid,
                      onToggle: _toggleSelect,
                      scrollController: scrollController,
                    ),
            ),

            // Bottom confirm
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
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton(
                      onPressed: _selectedIds.isEmpty
                          ? null
                          : () {
                              // Resolve selected IDs to UserModel objects
                              final allUsers = [
                                ...(friends.valueOrNull ?? []),
                                ..._searchResults,
                              ];
                              final selected = allUsers
                                  .where(
                                      (u) => _selectedIds.contains(u.userId))
                                  .toList();
                              widget.onConfirm?.call(selected);
                              Navigator.pop(context);
                            },
                      child: Text(widget.confirmLabel),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text("They'll receive an invite notification",
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                          letterSpacing: 1)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _Tab(
      {required this.label, required this.isActive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isActive ? AppColors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Center(
            child: Text(label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color:
                          isActive ? AppColors.onPrimary : AppColors.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    )),
          ),
        ),
      ),
    );
  }
}

class _FriendsList extends StatelessWidget {
  final List<UserModel> friends;
  final Set<String> selectedIds;
  final String currentUid;
  final void Function(UserModel) onToggle;
  final ScrollController scrollController;

  const _FriendsList({
    required this.friends,
    required this.selectedIds,
    required this.currentUid,
    required this.onToggle,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    if (friends.isEmpty) {
      return Center(
        child: Text('No friends yet. Use the Search tab to find people.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppColors.onSurfaceVariant),
            textAlign: TextAlign.center),
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
          isSelected: selectedIds.contains(f.userId),
          onTap: () => onToggle(f),
        );
      },
    );
  }
}

class _SearchList extends StatelessWidget {
  final List<UserModel> results;
  final bool searching;
  final Set<String> selectedIds;
  final String currentUid;
  final void Function(UserModel) onToggle;
  final ScrollController scrollController;

  const _SearchList({
    required this.results,
    required this.searching,
    required this.selectedIds,
    required this.currentUid,
    required this.onToggle,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    if (searching) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.primary));
    }
    if (results.isEmpty) {
      return Center(
        child: Text('Search for users above',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppColors.onSurfaceVariant)),
      );
    }
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      itemCount: results.length,
      itemBuilder: (_, i) {
        final u = results[i];
        if (u.userId == currentUid) return const SizedBox();
        return _UserRow(
          user: u,
          isSelected: selectedIds.contains(u.userId),
          onTap: () => onToggle(u),
        );
      },
    );
  }
}

class _UserRow extends StatelessWidget {
  final UserModel user;
  final bool isSelected;
  final VoidCallback onTap;

  const _UserRow({
    required this.user,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
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
                  'Level ${user.level} \u00b7 Rank #${user.rank}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.onSurfaceVariant),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: onTap,
            child: isSelected
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
                    child: const Icon(Icons.add,
                        size: 18, color: Colors.white),
                  ),
          ),
        ],
      ),
    );
  }
}
