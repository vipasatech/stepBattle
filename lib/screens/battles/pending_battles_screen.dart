import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../config/colors.dart';
import '../../models/battle_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/battle_provider.dart';
import '../../widgets/avatar_circle.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/glass_card.dart';

/// Full-screen list of pending battles the user is involved in.
/// The creator can delete any pending battle they started.
class PendingBattlesScreen extends ConsumerWidget {
  const PendingBattlesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(scheduledBattlesProvider);
    final uid = ref.watch(authStateProvider).valueOrNull?.uid ?? '';

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: Text(
          'Pending Battles',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: AppColors.onSurface,
                fontWeight: FontWeight.w700,
              ),
        ),
      ),
      body: pending.isEmpty
          ? const EmptyState(
              icon: Icons.hourglass_empty,
              title: 'No pending battles',
              subtitle:
                  'Battles you create or are invited to will appear here while waiting for a response.',
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
              itemCount: pending.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (_, i) =>
                  _PendingRow(battle: pending[i], currentUserId: uid),
            ),
    );
  }
}

class _PendingRow extends ConsumerStatefulWidget {
  final BattleModel battle;
  final String currentUserId;

  const _PendingRow({required this.battle, required this.currentUserId});

  @override
  ConsumerState<_PendingRow> createState() => _PendingRowState();
}

class _PendingRowState extends ConsumerState<_PendingRow> {
  bool _busy = false;

  bool get _isCreator => widget.battle.createdBy == widget.currentUserId;

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
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
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

    final others = battle.participants
        .where((p) => p.userId != widget.currentUserId)
        .toList();
    final otherLabel = others.isEmpty
        ? 'Opponent'
        : others.length == 1
            ? others.first.displayName
            : '${others.first.displayName} +${others.length - 1}';
    final firstOther = others.isNotEmpty ? others.first : null;

    final waitingCount = battle.invitedUserIds
        .where((id) => !battle.acceptedUserIds.contains(id))
        .length;
    final typeLabel = battle.type == BattleType.oneVsOne ? '1v1' : 'Group';

    return GlassCard(
      padding: const EdgeInsets.all(16),
      border: Border.all(color: AppColors.amber.withValues(alpha: 0.2)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AvatarCircle(
                radius: 20,
                imageUrl: firstOther?.avatarURL,
                initials: (firstOther?.displayName.isNotEmpty ?? false)
                    ? firstOther!.displayName[0].toUpperCase()
                    : '?',
                borderColor: AppColors.amber.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '\u2694\ufe0f You vs $otherLabel',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$typeLabel \u00b7 ${battle.durationDays}-day \u00b7 +${battle.xpReward} XP',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: AppColors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (_isCreator)
                _busy
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppColors.primary),
                      )
                    : IconButton(
                        icon: const Icon(Icons.delete_outline,
                            color: AppColors.error),
                        tooltip: 'Delete pending battle',
                        onPressed: _confirmAndDelete,
                      ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.hourglass_top,
                  size: 14, color: AppColors.amber.withValues(alpha: 0.8)),
              const SizedBox(width: 6),
              Text(
                waitingCount == 0
                    ? 'Awaiting activation'
                    : 'Waiting on $waitingCount invitee${waitingCount == 1 ? '' : 's'}',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: AppColors.amber),
              ),
              const Spacer(),
              if (!_isCreator)
                Text(
                  'Only creator can delete',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.onSurfaceVariant
                          .withValues(alpha: 0.6)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
