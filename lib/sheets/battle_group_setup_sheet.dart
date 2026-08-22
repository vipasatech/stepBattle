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
import '../widgets/battle_stake_picker.dart';
import '../widgets/battle_visibility_toggle.dart';
import '../widgets/bottom_sheet_handle.dart';
import '../providers/subscription_provider.dart';
import 'add_friends_sheet.dart';
import 'upgrade_cta_sheet.dart';

/// Multi-player battle setup — invite up to N participants for a free-for-all.
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
  /// In-sheet error banner (see 1v1 sheet for rationale — snackbars
  /// render behind bottom sheets and can't be surfaced without
  /// dismissing the sheet).
  String? _submitError;
  BattleWindow? _window;

  /// Public lobby toggle — see [Battle1v1SetupSheet] for design.
  bool _isPublic = false;

  /// Per-participant XP stake. v2 economy requires ≥
  /// [AppConstants.minBattleStakeXp] (100). Pot = stake × participants
  /// (creator + accepted invitees). Winner takes the whole pot.
  int _stakeXp = AppConstants.minBattleStakeXp;

  final _battleCode = BattleService.generateBattleCode();

  bool _isInvited(String userId) =>
      _invited.any((u) => u.userId == userId);

  void _removeInvited(UserModel user) {
    setState(() => _invited.removeWhere((u) => u.userId == user.userId));
  }

  Future<void> _showJoinCodeDialog(String code,
      {required bool recurring}) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        title: Text(
          recurring ? 'Daily Battle Created' : 'Invites Sent',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isPublic
                  ? 'Listed in Discover. Anyone can also paste this code:'
                  : 'Share this code to let anyone you invited join directly:',
              style: TextStyle(color: AppColors.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: () => Clipboard.setData(ClipboardData(text: code)),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 18),
                decoration: BoxDecoration(
                  color: AppColors.glassBackground,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      code,
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 6,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Icon(Icons.content_copy,
                        size: 18, color: AppColors.primary),
                  ],
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done'),
          ),
        ],
      ),
    );
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

  /// Public-battle toggle handler. Turning ON prompts a confirmation
  /// dialog explaining the 1-hour advance rule; Cancel reverts, Continue
  /// accepts and the duration picker's minStart snaps to now+1h on the
  /// next rebuild. Turning OFF is instant.
  Future<void> _onPublicToggleChanged(bool value) async {
    if (!value) {
      setState(() => _isPublic = false);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainerHigh,
        title: const Text('Public battle'),
        content: const Text(
          'Public battles are scheduled at least 1 hour in advance, '
          'giving other players enough time to discover and join before '
          'the battle begins.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (confirmed == true) {
      setState(() => _isPublic = true);
    }
  }

  Future<void> _createBattle() async {
    // Public battles skip the invitee requirement — anyone with the
    // join code / via Discover can drop in.
    if (!_isPublic && _invited.isEmpty) return;
    final window = _window;
    if (window == null || !window.isValid) return;
    // Submit-time defense in depth for public battles. 5-min tolerance
    // matches the picker's snap buffer (+5 min above the strict floor),
    // so a normal submit never trips this check.
    if (_isPublic) {
      final floorWithTolerance =
          DateTime.now().add(const Duration(minutes: 55));
      if (window.start.isBefore(floorWithTolerance)) {
        setState(() => _submitError =
            'Public battles need to start at least 1 hour from now. '
            'Re-open the start time and pick a later slot.');
        return;
      }
    }
    setState(() {
      _creating = true;
      _submitError = null;
    });

    try {
      final me = ref.read(currentUserProvider).valueOrNull;
      if (me == null) throw StateError('Not signed in');
      final participants = [
        BattleParticipant(
          userId: me.userId,
          displayName: me.displayName.isEmpty ? 'You' : me.displayName,
          preferredName: me.preferredName,
          avatarURL: me.avatarURL,
        ),
        ..._invited.map((u) => BattleParticipant(
              userId: u.userId,
              displayName: u.displayName,
              preferredName: u.preferredName,
              avatarURL: u.avatarURL,
            )),
      ];

      final service = ref.read(battleServiceProvider);
      final visibility =
          _isPublic ? BattleVisibility.public : BattleVisibility.private;
      // Daily preset → recurring series; otherwise one-off battle.
      final result = window.recurring
          ? await service.createDailySeries(
              type: BattleType.group,
              participants: participants,
              startTime: window.start,
              endTime: window.end,
              createdBy: me.userId,
              visibility: visibility,
              stakeXp: _stakeXp,
            )
          : await service.createBattle(
              type: BattleType.group,
              participants: participants,
              startTime: window.start,
              endTime: window.end,
              createdBy: me.userId,
              visibility: visibility,
              stakeXp: _stakeXp,
            );
      if (mounted) {
        Navigator.pop(context);
        await _showJoinCodeDialog(result.joinCode, recurring: window.recurring);
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
        decoration: BoxDecoration(
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
                      Text('MULTI BATTLE',
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
                  // Public toggle sits above the duration picker: the
                  // "public → +1h floor" dialog fires BEFORE the user
                  // picks a start time so the picker can enforce the
                  // floor from the start.
                  BattleVisibilityToggle(
                    isPublic: _isPublic,
                    onChanged: _onPublicToggleChanged,
                  ),
                  const SizedBox(height: 16),

                  // Start + end + chips. When public is on, minStart
                  // forces start >= now+1h.
                  BattleDurationPicker(
                    minStart: _isPublic
                        ? DateTime.now().add(const Duration(hours: 1))
                        : null,
                    onChanged: (window) {
                      _window = window;
                    },
                  ),
                  const SizedBox(height: 20),

                  // Stake picker — every participant commits this many
                  // XP; winner takes the whole pot. Min 100 (v2 economy).
                  // Pot size scales with number of accepted seats (creator
                  // + invitees).
                  BattleStakePicker(
                    value: _stakeXp,
                    participantsCount: _invited.length + 1,
                    onChanged: (v) => setState(() => _stakeXp = v),
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
                  // In-sheet error banner — replaces the old
                  // ScaffoldMessenger snackbar (rendered behind the
                  // sheet and was invisible to the user).
                  if (_submitError != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.error.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppColors.error.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline,
                              color: AppColors.error, size: 18),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _submitError!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: AppColors.error,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            icon: Icon(Icons.close,
                                color: AppColors.error, size: 18),
                            onPressed: () =>
                                setState(() => _submitError = null),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  Consumer(builder: (context, ref, _) {
                    final decision = ref.watch(canCreateBattleProvider);
                    // Public battles don't need an invitee list — anyone
                    // with the code / from Discover can join. So the
                    // button becomes actionable as soon as we're not
                    // mid-submit. Private battles still need ≥1 invitee.
                    final rosterReady =
                        (_isPublic || _invited.isNotEmpty) && !_creating;
                    final buttonEnabled = rosterReady && decision.allowed;
                    final blockedBySubOnly =
                        rosterReady && !decision.allowed;
                    return SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: FilledButton(
                        onPressed: buttonEnabled
                            ? _createBattle
                            : blockedBySubOnly
                                ? () => showUpgradeCtaSheet(
                                      context,
                                      focusTier: decision.upgradeTo,
                                    )
                                : null,
                        style: blockedBySubOnly
                            ? FilledButton.styleFrom(
                                backgroundColor: AppColors.amber
                                    .withValues(alpha: 0.85),
                                foregroundColor: Colors.black,
                              )
                            : null,
                        child: _creating
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : Text(blockedBySubOnly
                                ? 'Upgrade to create'
                                : 'Send Battle Invites'),
                      ),
                    );
                  }),
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
            initials: user.friendlyName.isNotEmpty
                ? user.friendlyName[0].toUpperCase()
                : '?',
            borderColor: AppColors.primary,
          ),
          const SizedBox(width: 6),
          Text(user.friendlyName,
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
