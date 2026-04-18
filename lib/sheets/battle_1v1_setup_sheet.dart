import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/colors.dart';
import '../models/battle_model.dart';
import '../models/user_model.dart';
import '../providers/battle_provider.dart';
import '../providers/friend_provider.dart';
import '../services/battle_service.dart';
import '../widgets/avatar_circle.dart';
import '../widgets/bottom_sheet_handle.dart';

/// 1v1 battle setup — opponent can be ANYONE (friend or stranger via search).
/// Creates a pending battle invite; battle only starts when opponent accepts.
class Battle1v1SetupSheet extends ConsumerStatefulWidget {
  const Battle1v1SetupSheet({super.key});

  @override
  ConsumerState<Battle1v1SetupSheet> createState() =>
      _Battle1v1SetupSheetState();
}

class _Battle1v1SetupSheetState extends ConsumerState<Battle1v1SetupSheet> {
  final _searchController = TextEditingController();
  UserModel? _selectedOpponent;
  List<UserModel> _searchResults = [];
  bool _searching = false;
  bool _creating = false;

  final _battleCode = BattleService.generateBattleCode();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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
    if (_selectedOpponent == null) return;
    setState(() => _creating = true);

    try {
      final me = FirebaseAuth.instance.currentUser!;
      await ref.read(battleServiceProvider).createBattle(
        type: BattleType.oneVsOne,
        participants: [
          BattleParticipant(
            userId: me.uid,
            displayName: me.displayName ?? 'You',
            avatarURL: me.photoURL,
          ),
          BattleParticipant(
            userId: _selectedOpponent!.userId,
            displayName: _selectedOpponent!.displayName,
            avatarURL: _selectedOpponent!.avatarURL,
          ),
        ],
        durationDays: 1,
        createdBy: me.uid,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Battle invite sent! Waiting for opponent...')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e')),
        );
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

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
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

            // Title + battle code
            Center(
              child: Text('1 vs 1',
                  style: theme.textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 4),
            Center(
              child: GestureDetector(
                onTap: () => Clipboard.setData(ClipboardData(text: _battleCode)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Battle ID: #$_battleCode',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.secondary,
                          letterSpacing: 2,
                        )),
                    const SizedBox(width: 4),
                    Icon(Icons.content_copy, size: 12, color: AppColors.secondary),
                  ],
                ),
              ),
            ),

            // Scrollable body
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                children: [
                  const SizedBox(height: 20),

                  // YOU vs OPPONENT card
                  Row(
                    children: [
                      Expanded(
                        child: _PlayerCard(
                          initials: 'YOU',
                          name: 'You',
                          isReady: true,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text('VS',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w900,
                              fontStyle: FontStyle.italic,
                            )),
                      ),
                      Expanded(
                        child: _PlayerCard(
                          initials: _selectedOpponent == null
                              ? null
                              : (_selectedOpponent!.displayName.isNotEmpty
                                  ? _selectedOpponent!.displayName[0]
                                      .toUpperCase()
                                  : '?'),
                          imageUrl: _selectedOpponent?.avatarURL,
                          name: _selectedOpponent?.displayName ??
                              '+ Select Opponent',
                          isPlaceholder: _selectedOpponent == null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Inline search
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
                      child: CircularProgressIndicator(color: AppColors.primary),
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
                              isSelected: _selectedOpponent?.userId == u.userId,
                              onTap: () =>
                                  setState(() => _selectedOpponent = u),
                            )),
                    const SizedBox(height: 20),
                  ],

                  // Suggested Rivals = real friends
                  Text('SUGGESTED RIVALS (FRIENDS)',
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
                              size: 18, color: AppColors.onSurfaceVariant),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'No friends yet. Use search to find anyone by username or code.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: AppColors.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    ...friends.take(5).map((u) => _UserResultRow(
                          user: u,
                          isSelected: _selectedOpponent?.userId == u.userId,
                          onTap: () => setState(() => _selectedOpponent = u),
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
                      onPressed: _selectedOpponent != null && !_creating
                          ? _createBattle
                          : null,
                      child: _creating
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Text('Send Battle Invite'),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Battle starts when opponent accepts',
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
// Player card (YOU / opponent)
// =============================================================================
class _PlayerCard extends StatelessWidget {
  final String? initials;
  final String? imageUrl;
  final String name;
  final bool isReady;
  final bool isPlaceholder;

  const _PlayerCard({
    this.initials,
    this.imageUrl,
    required this.name,
    this.isReady = false,
    this.isPlaceholder = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isPlaceholder
            ? AppColors.surfaceContainerLow
            : AppColors.glassBackground,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isPlaceholder
              ? AppColors.outlineVariant.withValues(alpha: 0.3)
              : AppColors.primary.withValues(alpha: 0.2),
          width: isPlaceholder ? 2 : 1,
          strokeAlign: BorderSide.strokeAlignInside,
        ),
      ),
      child: Column(
        children: [
          if (isPlaceholder)
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.outlineVariant.withValues(alpha: 0.3),
                  width: 2,
                  strokeAlign: BorderSide.strokeAlignInside,
                ),
              ),
              child: const Icon(Icons.person_add,
                  color: AppColors.onSurfaceVariant, size: 26),
            )
          else
            AvatarCircle(
              radius: 28,
              imageUrl: imageUrl,
              initials: initials,
              borderColor: AppColors.primary,
            ),
          const SizedBox(height: 8),
          Text(
            name,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: isPlaceholder
                  ? AppColors.onSurfaceVariant
                  : AppColors.onSurface,
            ),
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
          if (isReady) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('Ready',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: AppColors.onPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 9,
                  )),
            ),
          ],
        ],
      ),
    );
  }
}

// =============================================================================
// Search / friend result row with select action
// =============================================================================
class _UserResultRow extends StatelessWidget {
  final UserModel user;
  final bool isSelected;
  final VoidCallback onTap;

  const _UserResultRow({
    required this.user,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.primaryBrand.withValues(alpha: 0.15)
                : AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border: isSelected
                ? Border.all(color: AppColors.primary.withValues(alpha: 0.4))
                : null,
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
                  color: isSelected ? AppColors.success : AppColors.primaryBrand,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  isSelected ? Icons.check : Icons.add,
                  color: Colors.white,
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
