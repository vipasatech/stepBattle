import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../config/colors.dart';
import '../models/battle_model.dart';
import '../providers/battle_provider.dart';

/// Bottom sheet shown when the creator taps a "Waiting for Opponent"
/// battle card on the Battles home tab. Surfaces the two things
/// actually useful at this stage:
///
///   1. **Share the invite** — hands the join code to the native
///      share sheet so a friend can accept.
///   2. **Delete the battle** — reuses the same confirmation dialog
///      + `deletePendingBattle` service call as
///      [pending_battles_screen.dart].
///
/// If the current user is NOT the creator, delete is hidden — only
/// the creator can cancel their own pending battle.
Future<void> showPendingBattleActionsSheet(
  BuildContext context, {
  required BattleModel battle,
  required String currentUserId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.surfaceContainerLow,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _PendingBattleActionsSheet(
      battle: battle,
      currentUserId: currentUserId,
    ),
  );
}

class _PendingBattleActionsSheet extends ConsumerStatefulWidget {
  final BattleModel battle;
  final String currentUserId;
  const _PendingBattleActionsSheet({
    required this.battle,
    required this.currentUserId,
  });

  @override
  ConsumerState<_PendingBattleActionsSheet> createState() =>
      _PendingBattleActionsSheetState();
}

class _PendingBattleActionsSheetState
    extends ConsumerState<_PendingBattleActionsSheet> {
  bool _busy = false;

  bool get _isCreator => widget.battle.createdBy == widget.currentUserId;

  Future<void> _copyCode() async {
    final code = widget.battle.joinCode;
    if (code == null || code.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Code $code copied'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _shareInvite() async {
    final code = widget.battle.joinCode;
    if (code == null || code.isEmpty) return;
    final text =
        'Join my step battle on StepBattle!\nEnter code: $code';
    try {
      await Share.share(text, subject: 'Join my step battle');
    } catch (_) {
      // Native share sheet failures are best-effort — user can retry.
    }
  }

  Future<void> _confirmAndDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainerLow,
        title: const Text('Delete pending battle?'),
        content: const Text(
            'This will cancel the invite. Invitees will no longer see it.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            style:
                FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      await ref.read(battleServiceProvider).deletePendingBattle(
            battleId: widget.battle.battleId,
            actorId: widget.currentUserId,
          );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete: $e')),
        );
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final battle = widget.battle;
    final code = battle.joinCode;

    // Short opponent label for the header. On a "Waiting for Opponent"
    // battle nobody's accepted yet, so we fall back to "Waiting…".
    final others = battle.participants
        .where((p) => p.userId != widget.currentUserId)
        .toList();
    final opponent = others.isEmpty ? 'Waiting…' : others.first.friendlyName;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '⚔️ You vs $opponent',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: AppColors.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              '${battle.durationDays}-day  ·  +${battle.stakeXp} XP on win',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (code != null && code.isNotEmpty) ...[
              const SizedBox(height: 14),
              Center(
                child: GestureDetector(
                  onTap: _copyCode,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppColors.secondary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: AppColors.secondary
                              .withValues(alpha: 0.35)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.key,
                            size: 14, color: AppColors.secondary),
                        const SizedBox(width: 8),
                        Text(
                          code,
                          style: TextStyle(
                            color: AppColors.secondary,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 2,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(Icons.content_copy,
                            size: 12, color: AppColors.secondary),
                      ],
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _busy ? null : _shareInvite,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.ios_share, size: 20),
              label: const Text('Share invite',
                  style: TextStyle(
                      fontWeight: FontWeight.w700, letterSpacing: 0.3)),
            ),
            if (_isCreator) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _busy ? null : _confirmAndDelete,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.error,
                  side: BorderSide(
                      color: AppColors.error.withValues(alpha: 0.5)),
                  minimumSize: const Size(double.infinity, 48),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                icon: _busy
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppColors.error),
                      )
                    : const Icon(Icons.delete_outline, size: 20),
                label: const Text('Delete battle',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, letterSpacing: 0.3)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
