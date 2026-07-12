import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/colors.dart';
import '../../models/battle_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/battle_provider.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/status_pill.dart';

/// Public lobby list for battle discovery (Q10/Q12).
///
/// • Pending public battles: joinable instantly.
/// • Active public battles â‰¤24h old: shown but flagged "Full" so people
///   see what just kicked off.
/// • After 24h, active public battles drop off the feed.
class DiscoverBattlesScreen extends ConsumerStatefulWidget {
  const DiscoverBattlesScreen({super.key});

  @override
  ConsumerState<DiscoverBattlesScreen> createState() =>
      _DiscoverBattlesScreenState();
}

class _DiscoverBattlesScreenState extends ConsumerState<DiscoverBattlesScreen> {
  late Future<List<BattleModel>> _future;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    final uid = ref.read(authStateProvider).valueOrNull?.id ?? '';
    _future = ref.read(battleServiceProvider).getPublicBattles(userId: uid);
  }

  Future<void> _onJoin(BattleModel b) async {
    final me = ref.read(currentUserProvider).valueOrNull;
    if (me == null) return;
    if (b.status != BattleStatus.pending) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Battle has already started.')),
      );
      return;
    }
    try {
      final battleId = await ref.read(battleServiceProvider).joinByCode(
            code: b.joinCode ?? '',
            userId: me.userId,
            displayName: me.displayName,
            preferredName: me.preferredName,
            avatarUrl: me.avatarURL,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Joined!')),
      );
      context.push('/battle-ground/$battleId');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: const Text('Discover'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          setState(_refresh);
          await _future;
        },
        child: FutureBuilder<List<BattleModel>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return Center(
                  child: CircularProgressIndicator(color: AppColors.primary));
            }
            if (snap.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Could not load open battles. Pull to retry.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.onSurfaceVariant),
                  ),
                ),
              );
            }
            final list = snap.data ?? const <BattleModel>[];
            if (list.isEmpty) {
              return EmptyState(
                icon: Icons.travel_explore,
                title: 'No open battles',
                subtitle: 'Be the first — create a public battle.',
                ctaLabel: 'Back to Battles',
                onCtaTap: () => context.pop(),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 120),
              itemCount: list.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (_, i) =>
                  _PublicLobbyCard(battle: list[i], onJoin: _onJoin),
            );
          },
        ),
      ),
    );
  }
}

class _PublicLobbyCard extends StatelessWidget {
  final BattleModel battle;
  final Future<void> Function(BattleModel) onJoin;

  const _PublicLobbyCard({required this.battle, required this.onJoin});

  String get _typeLabel => switch (battle.type) {
        BattleType.oneVsOne => '1v1',
        BattleType.group => 'Multi-player',
        BattleType.team =>
          '${battle.teamCount ?? battle.teamLabels.length}-team',
      };

  int get _activeRoster => battle.participants
      .where((p) => p.inviteStatus != ParticipantInviteStatus.rejected)
      .length;

  int get _cap => battle.type == BattleType.oneVsOne ? 2 : 10;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final creator = battle.participants.firstWhere(
      (p) => p.userId == battle.createdBy,
      orElse: () => battle.participants.first,
    );
    final isActive = battle.status == BattleStatus.active;

    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$_typeLabel battle by ${creator.friendlyName}',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$_activeRoster / $_cap players · +${battle.xpReward} XP',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (isActive)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.onSurfaceVariant.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'FULL',
                    style: TextStyle(
                      color: AppColors.onSurfaceVariant,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.2,
                    ),
                  ),
                )
              else
                const StatusPill(type: StatusType.pending),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (battle.joinCode != null)
                Text(
                  'Code: ${battle.joinCode}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: AppColors.secondary,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w700,
                  ),
                )
              else
                const SizedBox.shrink(),
              FilledButton(
                onPressed: isActive ? null : () => onJoin(battle),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(isActive ? 'Started' : 'Join'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
