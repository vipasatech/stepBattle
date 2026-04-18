import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../config/colors.dart';
import '../../models/battle_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/battle_provider.dart';
import '../../sheets/new_battle_selection_sheet.dart';
import '../../widgets/avatar_circle.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/glass_card.dart';
import 'widgets/battle_card.dart';

class BattlesScreen extends ConsumerStatefulWidget {
  const BattlesScreen({super.key});

  @override
  ConsumerState<BattlesScreen> createState() => _BattlesScreenState();
}

class _BattlesScreenState extends ConsumerState<BattlesScreen> {
  @override
  void initState() {
    super.initState();
    // Auto-cancel any pending battles older than 24h that the user created
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final uid = ref.read(authStateProvider).valueOrNull?.uid;
      if (uid != null) {
        ref
            .read(battleServiceProvider)
            .cancelExpiredPendingBattles(uid);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Battles',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: AppColors.primaryBrand,
                fontWeight: FontWeight.w900,
              ),
        ),
        actions: [
          FilledButton.icon(
            onPressed: () => _showNewBattleSheet(context),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New Battle'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              textStyle: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: const _BattlesBody(),
    );
  }

  void _showNewBattleSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const NewBattleSelectionSheet(),
    );
  }
}

class _BattlesBody extends ConsumerWidget {
  const _BattlesBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allBattles = ref.watch(allBattlesProvider);
    final incomingInvites =
        ref.watch(incomingBattleInvitesProvider).valueOrNull ?? [];
    final uid = ref.watch(authStateProvider).valueOrNull?.uid ?? '';

    return allBattles.when(
      loading: () => const Center(
          child: CircularProgressIndicator(color: AppColors.primary)),
      error: (e, _) => Center(child: Text('Error loading battles: $e')),
      data: (_) {
        final active = ref.watch(activeBattlesProvider);
        final scheduled = ref.watch(scheduledBattlesProvider);
        final completed = ref.watch(completedBattlesProvider);

        if (incomingInvites.isEmpty &&
            active.isEmpty &&
            scheduled.isEmpty &&
            completed.isEmpty) {
          return EmptyState(
            icon: Icons.bolt,
            title: 'No battles yet',
            subtitle: 'Challenge a friend to a step battle!',
            ctaLabel: '\u2694\ufe0f  Start a Battle',
            onCtaTap: () => _showNewBattle(context),
          );
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
          children: [
            // Section: Incoming invites (needs user action)
            if (incomingInvites.isNotEmpty) ...[
              _SectionHeader(
                title: 'Incoming Invites',
                count: incomingInvites.length,
                highlight: true,
              ),
              const SizedBox(height: 12),
              ...incomingInvites.map((b) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _IncomingInviteCard(battle: b, currentUserId: uid),
                  )),
              const SizedBox(height: 24),
            ],

            // Active
            if (active.isNotEmpty) ...[
              _SectionHeader(title: 'Active Battles', count: active.length),
              const SizedBox(height: 12),
              ...active.map((b) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: BattleCard(battle: b, currentUserId: uid),
                  )),
              const SizedBox(height: 24),
            ],

            // Pending (my outgoing invites awaiting acceptance)
            if (scheduled.isNotEmpty) ...[
              _SectionHeader(
                title: 'Waiting for Opponent',
                count: scheduled.length,
                onChevronTap: () => context.go('/battles/pending'),
              ),
              const SizedBox(height: 12),
              ...scheduled.map((b) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: BattleCard(battle: b, currentUserId: uid),
                  )),
              const SizedBox(height: 24),
            ],

            // Completed
            if (completed.isNotEmpty) ...[
              _SectionHeader(title: 'Completed', count: completed.length),
              const SizedBox(height: 12),
              ...completed.map((b) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: BattleCard(battle: b, currentUserId: uid),
                  )),
            ],
          ],
        );
      },
    );
  }

  void _showNewBattle(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const NewBattleSelectionSheet(),
    );
  }
}

// =============================================================================
// Incoming battle invite card with Accept / Reject
// =============================================================================
class _IncomingInviteCard extends ConsumerStatefulWidget {
  final BattleModel battle;
  final String currentUserId;

  const _IncomingInviteCard({
    required this.battle,
    required this.currentUserId,
  });

  @override
  ConsumerState<_IncomingInviteCard> createState() =>
      _IncomingInviteCardState();
}

class _IncomingInviteCardState extends ConsumerState<_IncomingInviteCard> {
  bool _busy = false;

  Future<void> _accept() async {
    setState(() => _busy = true);
    try {
      await ref.read(battleServiceProvider).acceptInvite(
            battleId: widget.battle.battleId,
            userId: widget.currentUserId,
          );
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _reject() async {
    setState(() => _busy = true);
    try {
      await ref.read(battleServiceProvider).rejectInvite(
            battleId: widget.battle.battleId,
            userId: widget.currentUserId,
          );
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final battle = widget.battle;

    // Find the inviter (the first participant who accepted — usually the creator)
    final inviter = battle.participants.firstWhere(
      (p) => p.userId == battle.createdBy,
      orElse: () => battle.participants.first,
    );

    final typeLabel = battle.type == BattleType.oneVsOne ? '1v1' : 'Group';

    return GlassCard(
      padding: const EdgeInsets.all(16),
      border: Border.all(color: AppColors.amber.withValues(alpha: 0.3)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AvatarCircle(
                radius: 22,
                imageUrl: inviter.avatarURL,
                initials: inviter.displayName.isNotEmpty
                    ? inviter.displayName[0].toUpperCase()
                    : '?',
                borderColor: AppColors.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${inviter.displayName} challenged you',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    Text(
                      '$typeLabel battle · ${battle.durationDays}-day duration · +${battle.xpReward} XP on win',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_busy)
            const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.primary),
              ),
            )
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _reject,
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(
                          color: AppColors.error.withValues(alpha: 0.4)),
                      foregroundColor: AppColors.error,
                    ),
                    child: const Text('Reject'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: _accept,
                    child: const Text('Accept'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final bool highlight;
  final VoidCallback? onChevronTap;

  const _SectionHeader({
    required this.title,
    required this.count,
    this.highlight = false,
    this.onChevronTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chevron = Icon(
      Icons.chevron_right,
      color: onChevronTap != null
          ? AppColors.primary
          : AppColors.primary.withValues(alpha: 0.25),
      size: 24,
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Text(
              title,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: highlight ? AppColors.amber : AppColors.onSurface,
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: highlight
                      ? AppColors.amber.withValues(alpha: 0.15)
                      : AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('$count',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: highlight ? AppColors.amber : AppColors.primary,
                      fontWeight: FontWeight.w900,
                    )),
              ),
            ],
          ],
        ),
        onChevronTap != null
            ? GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onChevronTap,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: chevron,
                ),
              )
            : chevron,
      ],
    );
  }
}
