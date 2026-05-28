import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/colors.dart';
import '../config/constants.dart';
import '../models/battle_model.dart';
import '../models/user_model.dart';
import '../providers/auth_provider.dart';
import '../providers/battle_provider.dart';
import '../services/battle_service.dart';
import '../widgets/avatar_circle.dart';
import '../widgets/battle_duration_picker.dart';
import '../widgets/bottom_sheet_handle.dart';
import 'add_friends_sheet.dart';

/// Group battle setup — invite up to N participants.
///
/// Mirror of [Battle1v1SetupSheet]:
///   • "+ Add players" opens [AddFriendsSheet] in multi-select picker mode
///   • Inline search field removed
///   • Start time + end time pickers + duration chips replace the
///     end-only picker
class BattleGroupSetupSheet extends ConsumerStatefulWidget {
  const BattleGroupSetupSheet({super.key});

  @override
  ConsumerState<BattleGroupSetupSheet> createState() =>
      _BattleGroupSetupSheetState();
}

class _BattleGroupSetupSheetState
    extends ConsumerState<BattleGroupSetupSheet> {
  final List<UserModel> _invited = [];
  bool _creating = false;
  BattleWindow? _window;

  final _battleCode = BattleService.generateBattleCode();

  bool _isInvited(String userId) =>
      _invited.any((u) => u.userId == userId);

  void _removeInvited(UserModel user) {
    setState(() => _invited.removeWhere((u) => u.userId == user.userId));
  }

  Future<void> _pickInvitees() async {
    final slotsLeft =
        AppConstants.maxGroupBattleParticipants - 1 - _invited.length;
    if (slotsLeft <= 0) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddFriendsSheet(
        mode: FriendsSheetMode.picker,
        confirmLabel: 'Add to Battle',
        onConfirm: (selected) {
          setState(() {
            for (final u in selected) {
              if (_isInvited(u.userId)) continue;
              if (_invited.length >=
                  AppConstants.maxGroupBattleParticipants - 1) {
                break;
              }
              _invited.add(u);
            }
          });
        },
      ),
    );
  }

  Future<void> _createBattle() async {
    if (_invited.isEmpty) return;
    final window = _window;
    if (window == null || !window.isValid) return;
    setState(() => _creating = true);

    try {
      final me = ref.read(currentUserProvider).valueOrNull;
      if (me == null) throw StateError('Not signed in');
      final participants = [
        BattleParticipant(
          userId: me.userId,
          displayName: me.displayName.isEmpty ? 'You' : me.displayName,
          avatarURL: me.avatarURL,
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
            startTime: window.start,
            endTime: window.end,
            createdBy: me.userId,
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
                  // Start + end + chips
                  BattleDurationPicker(
                    onChanged: (window) {
                      _window = window;
                    },
                  ),
                  const SizedBox(height: 24),

                  // PLAYERS section
                  Row(
                    children: [
                      Expanded(
                        child: Text('PLAYERS',
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: AppColors.onSurfaceVariant,
                                letterSpacing: 2)),
                      ),
                      TextButton.icon(
                        onPressed: slotsLeft > 0 ? _pickInvitees : null,
                        icon: const Icon(Icons.person_add, size: 18),
                        label: Text(
                            slotsLeft > 0 ? 'Add players' : 'Max reached'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  if (_invited.isEmpty)
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
                              'Tap "Add players" to invite friends to the battle.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: AppColors.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _invited
                          .map((u) => _InvitedChip(
                                user: u,
                                onRemove: () => _removeInvited(u),
                              ))
                          .toList(),
                    ),

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
                      onPressed: _invited.isNotEmpty && !_creating
                          ? _createBattle
                          : null,
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
                    'Battle starts at the chosen Start Time once all accept',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.onSurfaceVariant,
                    ),
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
            child:
                const Icon(Icons.close, size: 14, color: AppColors.error),
          ),
        ],
      ),
    );
  }
}
