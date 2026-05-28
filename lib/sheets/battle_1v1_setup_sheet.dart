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

  final _battleCode = BattleService.generateBattleCode();

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
    if (_selectedOpponent == null) return;
    final window = _window;
    if (window == null || !window.isValid) return;
    setState(() => _creating = true);

    try {
      final me = ref.read(currentUserProvider).valueOrNull;
      if (me == null) throw StateError('Not signed in');
      await ref.read(battleServiceProvider).createBattle(
        type: BattleType.oneVsOne,
        participants: [
          BattleParticipant(
            userId: me.userId,
            displayName: me.displayName.isEmpty ? 'You' : me.displayName,
            avatarURL: me.avatarURL,
          ),
          BattleParticipant(
            userId: _selectedOpponent!.userId,
            displayName: _selectedOpponent!.displayName,
            avatarURL: _selectedOpponent!.avatarURL,
          ),
        ],
        startTime: window.start,
        endTime: window.end,
        createdBy: me.userId,
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
