import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/colors.dart';
import '../config/constants.dart';
import '../models/battle_model.dart';
import '../providers/battle_provider.dart';
import '../services/battle_service.dart';
import '../widgets/avatar_circle.dart';
import '../widgets/bottom_sheet_handle.dart';

/// Group battle setup — add up to 10 participants, then create.
class BattleGroupSetupSheet extends ConsumerStatefulWidget {
  const BattleGroupSetupSheet({super.key});

  @override
  ConsumerState<BattleGroupSetupSheet> createState() =>
      _BattleGroupSetupSheetState();
}

class _BattleGroupSetupSheetState
    extends ConsumerState<BattleGroupSetupSheet> {
  final _searchController = TextEditingController();
  final List<_FriendSlot> _addedFriends = [];
  bool _creating = false;

  final _battleCode = BattleService.generateBattleCode();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _createBattle() async {
    if (_addedFriends.isEmpty) return;
    setState(() => _creating = true);

    try {
      final me = FirebaseAuth.instance.currentUser!;
      final participants = [
        BattleParticipant(
          userId: me.uid,
          displayName: me.displayName ?? 'You',
          avatarURL: me.photoURL,
        ),
        ..._addedFriends.map((f) => BattleParticipant(
              userId: f.id,
              displayName: f.name,
            )),
      ];

      await ref.read(battleServiceProvider).createBattle(
            type: BattleType.group,
            participants: participants,
            durationDays: 1,
            createdBy: me.uid,
          );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  void _addFriend(String id, String name, String initials) {
    if (_addedFriends.length >= AppConstants.maxGroupBattleParticipants - 1) {
      return;
    }
    if (_addedFriends.any((f) => f.id == id)) return;
    setState(() => _addedFriends.add(_FriendSlot(id: id, name: name, initials: initials)));
  }

  void _removeFriend(String id) {
    setState(() => _addedFriends.removeWhere((f) => f.id == id));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
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
                  Icon(Icons.settings, color: AppColors.primary),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Scrollable content
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                children: [
                  // Participants section
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: AppColors.primary.withValues(alpha: 0.2)),
                      boxShadow: [
                        BoxShadow(
                            color: AppColors.primary.withValues(alpha: 0.05),
                            blurRadius: 20),
                      ],
                    ),
                    child: Column(
                      children: [
                        // You (host, locked)
                        _ParticipantRow(
                          initials: 'YOU',
                          name: 'You',
                          subtitle: 'Host',
                          trailing: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: AppColors.success.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color:
                                      AppColors.success.withValues(alpha: 0.2)),
                            ),
                            child: Text('Ready',
                                style: theme.textTheme.labelSmall?.copyWith(
                                    color: AppColors.success,
                                    fontWeight: FontWeight.w900)),
                          ),
                        ),
                        const SizedBox(height: 12),

                        // Added friends
                        ..._addedFriends.map((f) => Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: _ParticipantRow(
                                initials: f.initials,
                                name: f.name,
                                subtitle: 'Invited',
                                trailing: GestureDetector(
                                  onTap: () => _removeFriend(f.id),
                                  child: const Icon(Icons.close,
                                      color: AppColors.error, size: 18),
                                ),
                              ),
                            )),

                        // Empty slots
                        if (_addedFriends.length <
                            AppConstants.maxGroupBattleParticipants - 1) ...[
                          _EmptySlot(onTap: () {
                            // TODO: Open Add Friends sheet multi-select
                          }),
                          const SizedBox(height: 8),
                          _EmptySlot(onTap: () {}),
                        ],

                        const SizedBox(height: 8),
                        Text(
                          'ADD UP TO ${AppConstants.maxGroupBattleParticipants} PARTICIPANTS',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: AppColors.outline,
                            letterSpacing: 2,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Search
                  TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Search by name or username',
                      prefixIcon:
                          const Icon(Icons.search, color: AppColors.outline),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Suggested friends
                  Text('Suggested Friends',
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                          letterSpacing: 2)),
                  const SizedBox(height: 12),

                  ..._buildSuggested(theme),
                ],
              ),
            ),

            // Bottom actions
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
                    height: 50,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        // TODO: System share sheet with battle code
                      },
                      icon: const Icon(Icons.share, size: 18),
                      label: const Text('Invite Friends'),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppColors.primary),
                        foregroundColor: AppColors.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: FilledButton(
                      onPressed: _addedFriends.isNotEmpty && !_creating
                          ? _createBattle
                          : null,
                      style: FilledButton.styleFrom(
                        disabledBackgroundColor:
                            AppColors.surfaceContainerHighest,
                        disabledForegroundColor: AppColors.onSurfaceVariant,
                      ),
                      child: _creating
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Text('Create Battle'),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Battle starts when all participants accept',
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildSuggested(ThemeData theme) {
    final suggestions = [
      ('Marcus_Bolt', 'MB', 'Rank #42 · 12.4k Avg Steps', AppColors.primary),
      ('Sarah_Sprint', 'SS', 'Rank #12 · 15.1k Avg Steps', AppColors.tertiary),
      ('Leo.Steps', 'LS', 'Rank #89 · 10.8k Avg Steps', AppColors.secondary),
    ];

    return suggestions.map((s) {
      final isAdded = _addedFriends.any((f) => f.name == s.$1);
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isAdded
                ? AppColors.surfaceContainer
                : AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              AvatarCircle(radius: 22, initials: s.$2, borderColor: s.$4),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.$1,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    Text(s.$3, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              GestureDetector(
                onTap: isAdded
                    ? null
                    : () => _addFriend('placeholder_${s.$1}', s.$1, s.$2),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: isAdded ? AppColors.success : AppColors.primaryBrand,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    isAdded ? Icons.check : Icons.add,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }).toList();
  }
}

class _ParticipantRow extends StatelessWidget {
  final String initials;
  final String name;
  final String subtitle;
  final Widget trailing;

  const _ParticipantRow({
    required this.initials,
    required this.name,
    required this.subtitle,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
        border:
            Border.all(color: AppColors.primary.withValues(alpha: 0.1)),
      ),
      child: Row(
        children: [
          AvatarCircle(
              radius: 22, initials: initials, borderColor: AppColors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                Text(subtitle,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: AppColors.secondary)),
              ],
            ),
          ),
          trailing,
        ],
      ),
    );
  }
}

class _EmptySlot extends StatelessWidget {
  final VoidCallback onTap;
  const _EmptySlot({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: AppColors.outlineVariant.withValues(alpha: 0.3),
            width: 2,
            strokeAlign: BorderSide.strokeAlignInside,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.surfaceContainerLow,
                border: Border.all(
                    color: AppColors.outlineVariant.withValues(alpha: 0.2)),
              ),
              child: const Icon(Icons.person_add,
                  color: AppColors.onSurfaceVariant, size: 20),
            ),
            const SizedBox(width: 12),
            Text('+ Add Friend',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: AppColors.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _FriendSlot {
  final String id;
  final String name;
  final String initials;
  const _FriendSlot(
      {required this.id, required this.name, required this.initials});
}
