import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/colors.dart';
import '../models/battle_model.dart';
import '../models/user_model.dart';
import '../providers/auth_provider.dart';
import '../providers/battle_provider.dart';
import '../services/battle_service.dart';
import '../widgets/avatar_circle.dart';
import '../widgets/battle_duration_picker.dart';
import '../widgets/battle_visibility_toggle.dart';
import '../widgets/bottom_sheet_handle.dart';
import 'add_friends_sheet.dart';

/// 1v1 battle setup.
///
/// UX layout (top → bottom):
///   • Title + battle code
///   • YOU vs OPPONENT card — tap "+ Select Opponent" to open the
///     [AddFriendsSheet] in picker mode (single-select)
///   • Start time + End time pickers with duration chips (see
///     [BattleDurationPicker])
///   • CTA: "Send Battle Invite"
class Battle1v1SetupSheet extends ConsumerStatefulWidget {
  const Battle1v1SetupSheet({super.key});

  @override
  ConsumerState<Battle1v1SetupSheet> createState() =>
      _Battle1v1SetupSheetState();
}

class _Battle1v1SetupSheetState extends ConsumerState<Battle1v1SetupSheet> {
  UserModel? _selectedOpponent;
  bool _creating = false;
  BattleWindow? _window;

  /// When true, the battle goes into the public Discover feed and anyone with
  /// the join code (or the Discover tap) can join. Off by default — invite-only.
  bool _isPublic = false;

  /// Per-participant XP stake. Min 100 (set by migration 0016 economy
  /// rules); 0 means "free play, no stake". Pot = stake Ã— 2 in 1v1; the
  /// winner gets the whole pot.
  int _stakeXp = 100;

  final _battleCode = BattleService.generateBattleCode();

  Future<void> _showJoinCodeDialog(String code,
      {required bool recurring}) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        title: Text(
          recurring ? 'Daily Battle Created' : 'Battle Invite Sent',
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

  Future<void> _pickOpponent() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AddFriendsSheet(
        mode: FriendsSheetMode.picker,
        multiSelect: false,
        confirmLabel: 'Select Opponent',
        // AddFriendsSheet returns the picked list via onConfirm; in
        // single-select mode it contains exactly one user.
        onConfirm: (selected) {
          if (selected.isEmpty) return;
          setState(() => _selectedOpponent = selected.first);
        },
      ),
    );
  }

  Future<void> _createBattle() async {
    // For PUBLIC battles, no specific opponent is required — anyone with
    // the join code or via Discover can drop in. For PRIVATE battles
    // we still need a chosen opponent at create time.
    if (!_isPublic && _selectedOpponent == null) return;
    final window = _window;
    if (window == null || !window.isValid) return;
    setState(() => _creating = true);

    try {
      final me = ref.read(currentUserProvider).valueOrNull;
      if (me == null) throw StateError('Not signed in');
      final participants = <BattleParticipant>[
        BattleParticipant(
          userId: me.userId,
          displayName: me.displayName.isEmpty ? 'You' : me.displayName,
          preferredName: me.preferredName,
          avatarURL: me.avatarURL,
        ),
        if (_selectedOpponent != null)
          BattleParticipant(
            userId: _selectedOpponent!.userId,
            displayName: _selectedOpponent!.displayName,
            preferredName: _selectedOpponent!.preferredName,
            avatarURL: _selectedOpponent!.avatarURL,
          ),
      ];
      // Daily preset → recurring series (one accept covers every future day).
      // Anything else → one-off battle, original flow.
      final service = ref.read(battleServiceProvider);
      final visibility =
          _isPublic ? BattleVisibility.public : BattleVisibility.private;
      final result = window.recurring
          ? await service.createDailySeries(
              type: BattleType.oneVsOne,
              participants: participants,
              startTime: window.start,
              endTime: window.end,
              createdBy: me.userId,
              visibility: visibility,
            )
          : await service.createBattle(
              type: BattleType.oneVsOne,
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

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
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

            // Title + battle code
            Center(
              child: Text('1 vs 1',
                  style: theme.textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 4),
            Center(
              child: GestureDetector(
                onTap: () =>
                    Clipboard.setData(ClipboardData(text: _battleCode)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Battle ID: #$_battleCode',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.secondary,
                          letterSpacing: 2,
                        )),
                    const SizedBox(width: 4),
                    Icon(Icons.content_copy,
                        size: 12, color: AppColors.secondary),
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

                  // YOU vs OPPONENT card. Right side is tappable to open
                  // the friend picker sheet.
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
                        child: GestureDetector(
                          onTap: _pickOpponent,
                          child: _PlayerCard(
                            initials: _selectedOpponent == null
                                ? null
                                : (_selectedOpponent!.friendlyName.isNotEmpty
                                    ? _selectedOpponent!.friendlyName[0]
                                        .toUpperCase()
                                    : '?'),
                            imageUrl: _selectedOpponent?.avatarURL,
                            name: _selectedOpponent?.friendlyName ??
                                '+ Select Opponent',
                            isPlaceholder: _selectedOpponent == null,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Start + end time + duration chips.
                  BattleDurationPicker(
                    onChanged: (window) {
                      // Avoid rebuild loops; just cache the value.
                      _window = window;
                    },
                  ),

                  const SizedBox(height: 16),

                  BattleVisibilityToggle(
                    isPublic: _isPublic,
                    onChanged: (v) => setState(() => _isPublic = v),
                  ),

                  const SizedBox(height: 20),

                  // Stake picker — both sides commit this many XP; winner
                  // takes the whole pot. Min 100, no max (XP economy
                  // rules from migration 0016).
                  _StakePicker(
                    value: _stakeXp,
                    onChanged: (v) => setState(() => _stakeXp = v),
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
                      // Enabled when:
                      //   • Not already submitting
                      //   • EITHER an opponent has been picked (private)
                      //     OR the public-battle toggle is on (no opp needed)
                      onPressed: !_creating &&
                              (_selectedOpponent != null || _isPublic)
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
                    'Battle starts at the chosen Start Time once opponent accepts',
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
              child: Icon(Icons.person_add,
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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

/// Stake picker — presets + Â±50 stepper. Floor 100 (post-0016 minimum),
/// no upper bound. The chosen amount is deducted from BOTH the creator
/// (at create time) and each invitee (at accept time); the winner takes
/// the full pot.
class _StakePicker extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;
  const _StakePicker({required this.value, required this.onChanged});

  static const _presets = [100, 250, 500, 1000];
  static const _floor = 100;
  static const _step = 50;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pot = value * 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('STAKE',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.onSurfaceVariant,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w800,
                )),
            const Spacer(),
            Text('Pot ${_fmt(pot)} XP',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w800,
                )),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final p in _presets) ...[
              Expanded(
                child: GestureDetector(
                  onTap: () => onChanged(p),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: p == value
                          ? AppColors.primary.withValues(alpha: 0.18)
                          : AppColors.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: p == value
                            ? AppColors.primary
                            : AppColors.outlineVariant,
                      ),
                    ),
                    child: Center(
                      child: Text(_fmt(p),
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: p == value
                                ? AppColors.primary
                                : AppColors.onSurface,
                          )),
                    ),
                  ),
                ),
              ),
              if (p != _presets.last) const SizedBox(width: 6),
            ],
          ],
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton.outlined(
              onPressed: value > _floor
                  ? () => onChanged((value - _step).clamp(_floor, 1 << 30))
                  : null,
              icon: const Icon(Icons.remove),
            ),
            const SizedBox(width: 16),
            Text(
              '${_fmt(value)} XP',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(width: 16),
            IconButton.outlined(
              onPressed: () => onChanged(value + _step),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ],
    );
  }

  static String _fmt(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}
