import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/colors.dart';
import '../config/constants.dart';
import '../models/battle_model.dart';
import '../models/user_model.dart';
import '../providers/battle_provider.dart';
import '../providers/friend_provider.dart';
import '../services/battle_service.dart';
import '../widgets/avatar_circle.dart';
import '../widgets/battle_duration_picker.dart';
import '../widgets/bottom_sheet_handle.dart';

/// Group battle setup — invite up to 10 participants (friends OR strangers).
/// Creates a pending battle invite; battle starts when all accept.
class BattleGroupSetupSheet extends ConsumerStatefulWidget {
  const BattleGroupSetupSheet({super.key});

  @override
  ConsumerState<BattleGroupSetupSheet> createState() =>
      _BattleGroupSetupSheetState();
}

class _BattleGroupSetupSheetState
    extends ConsumerState<BattleGroupSetupSheet> {
  final _searchController = TextEditingController();
  final List<UserModel> _invited = [];
  List<UserModel> _searchResults = [];
  bool _searching = false;
  bool _creating = false;
  DateTime? _endTime;

  final _battleCode = BattleService.generateBattleCode();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool _isInvited(String userId) =>
      _invited.any((u) => u.userId == userId);

  void _toggleInvite(UserModel user) {
    setState(() {
      if (_isInvited(user.userId)) {
        _invited.removeWhere((u) => u.userId == user.userId);
      } else {
        if (_invited.length <
            AppConstants.maxGroupBattleParticipants - 1) {
          _invited.add(user);
        }
      }
    });
  }

  Future<void> _search() async {
    final q = _searchController.text.trim();
    if (q.isEmpty) {
      setState(() => _searchResults = []);
      return;
    }
    setState(() => _searching = true);
    try {
      final results = await ref.read(friendServiceProvider).search(q);
      setState(() => _searchResults = results);
    } catch (_) {}
    setState(() => _searching = false);
  }

  Future<void> _createBattle() async {
    if (_invited.isEmpty) return;
    final endTime = _endTime;
    if (endTime == null) return;
    setState(() => _creating = true);

    try {
      final me = FirebaseAuth.instance.currentUser!;
      final participants = [
        BattleParticipant(
          userId: me.uid,
          displayName: me.displayName ?? 'You',
          avatarURL: me.photoURL,
        ),
        ..._invited.map((u) => BattleParticipant(
              userId: u.userId,
              displayName: u.displayName,
              avatarURL: u.avatarURL,
            )),
      ];

      await ref.read(battleServiceProvider).createBattle(
            type: BattleType.group,
            participants: participants,
            endTime: endTime,
            createdBy: me.uid,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Invites sent! Battle starts when all accept.')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final friends = ref.watch(friendsListProvider).valueOrNull ?? [];
    final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final slotsLeft =
        AppConstants.maxGroupBattleParticipants - 1 - _invited.length;

    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
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
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('GROUP BATTLE',
                          style: theme.textTheme.headlineSmall?.copyWith(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w700)),
                      GestureDetector(
                        onTap: () => Clipboard.setData(
                            ClipboardData(text: _battleCode)),
                        child: Row(
                          children: [
                            Text('Battle ID: #$_battleCode',
                                style: theme.textTheme.labelSmall?.copyWith(
                                    color: AppColors.secondary,
                                    letterSpacing: 1)),
                            const SizedBox(width: 4),
                            Icon(Icons.content_copy,
                                size: 12, color: AppColors.secondary),
                          ],
                        ),
                      ),
                    ],
                  ),
                  Text(
                    '${_invited.length + 1} / ${AppConstants.maxGroupBattleParticipants}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                children: [
                  // Duration picker
                  BattleDurationPicker(
                    onChanged: (dt) {
                      _endTime = dt;
                    },
                  ),
                  const SizedBox(height: 20),

                  // Invited participants chips
                  if (_invited.isNotEmpty) ...[
                    Text('INVITED',
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: AppColors.onSurfaceVariant,
                            letterSpacing: 2)),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _invited
                          .map((u) => _InvitedChip(
                                user: u,
                                onRemove: () => _toggleInvite(u),
                              ))
                          .toList(),
                    ),
                    const SizedBox(height: 20),
                  ],

                  // Search
                  TextField(
                    controller: _searchController,
                    onSubmitted: (_) => _search(),
                    onChanged: (v) {
                      if (v.isEmpty) setState(() => _searchResults = []);
                    },
                    decoration: InputDecoration(
                      hintText: 'Search by name or #CODE',
                      prefixIcon:
                          const Icon(Icons.search, color: AppColors.outline),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.arrow_forward, size: 20),
                        onPressed: _search,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Search results
                  if (_searching)
                    const Center(
                        child: Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(
                          color: AppColors.primary),
                    ))
                  else if (_searchResults.isNotEmpty) ...[
                    Text('SEARCH RESULTS',
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: AppColors.onSurfaceVariant,
                            letterSpacing: 2)),
                    const SizedBox(height: 10),
                    ..._searchResults
                        .where((u) => u.userId != currentUid)
                        .map((u) => _UserResultRow(
                              user: u,
                              isInvited: _isInvited(u.userId),
                              canAdd: slotsLeft > 0 || _isInvited(u.userId),
                              onTap: () => _toggleInvite(u),
                            )),
                    const SizedBox(height: 20),
                  ],

                  // Suggested friends
                  Text('SUGGESTED FRIENDS',
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                          letterSpacing: 2)),
                  const SizedBox(height: 10),

                  if (friends.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline,
                              size: 18,
                              color: AppColors.onSurfaceVariant),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'No friends yet. Use search to invite anyone by username or code.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: AppColors.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    ...friends.map((u) => _UserResultRow(
                          user: u,
                          isInvited: _isInvited(u.userId),
                          canAdd: slotsLeft > 0 || _isInvited(u.userId),
                          onTap: () => _toggleInvite(u),
                        )),

                  const SizedBox(height: 20),
                ],
              ),
            ),

            // Bottom CTA
            Container(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    AppColors.surfaceContainer.withValues(alpha: 0),
                    AppColors.surfaceContainer,
                  ],
                ),
              ),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: FilledButton(
                      onPressed:
                          _invited.isNotEmpty && !_creating ? _createBattle : null,
                      child: _creating
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Text('Send Battle Invites'),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Battle starts when all participants accept',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Invited chip
// =============================================================================
class _InvitedChip extends StatelessWidget {
  final UserModel user;
  final VoidCallback onRemove;

  const _InvitedChip({required this.user, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.primaryBrand.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AvatarCircle(
            radius: 12,
            imageUrl: user.avatarURL,
            initials: user.displayName.isNotEmpty
                ? user.displayName[0].toUpperCase()
                : '?',
            borderColor: AppColors.primary,
          ),
          const SizedBox(width: 6),
          Text(user.displayName,
              style: theme.textTheme.labelSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onRemove,
            child: const Icon(Icons.close,
                size: 14, color: AppColors.error),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Search / friend row
// =============================================================================
class _UserResultRow extends StatelessWidget {
  final UserModel user;
  final bool isInvited;
  final bool canAdd;
  final VoidCallback onTap;

  const _UserResultRow({
    required this.user,
    required this.isInvited,
    required this.canAdd,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: canAdd ? onTap : null,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isInvited
                ? AppColors.primaryBrand.withValues(alpha: 0.1)
                : AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              AvatarCircle(
                radius: 22,
                imageUrl: user.avatarURL,
                initials: user.displayName.isNotEmpty
                    ? user.displayName[0].toUpperCase()
                    : '?',
                borderColor: AppColors.primary.withValues(alpha: 0.2),
              ),
              const SizedBox(width: 12),
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
                          : 'Level ${user.level}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: isInvited
                      ? AppColors.success
                      : (canAdd
                          ? AppColors.primaryBrand
                          : AppColors.surfaceContainerHigh),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  isInvited ? Icons.check : Icons.add,
                  color: canAdd ? Colors.white : AppColors.onSurfaceVariant,
                  size: 20,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
