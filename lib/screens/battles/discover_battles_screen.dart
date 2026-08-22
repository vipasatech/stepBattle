import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/colors.dart';
import '../../models/battle_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/battle_provider.dart';
import '../../providers/subscription_provider.dart';
import '../../sheets/upgrade_cta_sheet.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/shimmer_loader.dart';
import '../../widgets/status_pill.dart';
import 'widgets/battle_search_tab.dart';

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
    // Subscription gate — public join needs both the public-join cap
    // AND the umbrella entries cap to have room. If not, open the
    // upgrade sheet instead of hitting Supabase.
    final decision = ref.read(canJoinPublicBattleProvider);
    if (!decision.allowed) {
      await showUpgradeCtaSheet(
        context,
        focusTier: decision.upgradeTo,
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
    // Batch A #7: split Discover into "1v1" and "Multi" tabs
    // so users can browse the format they want without wading through
    // the other. Team battles never appear here (they're private-only
    // per Batch A #1). Third tab is "Search" — filter by battle ID
    // (short code #XXXX or full UUID prefix) across BOTH formats so
    // a user with a shared code doesn't have to guess the tab first.
    final uid = ref.watch(authStateProvider).valueOrNull?.id ?? '';
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => context.pop(),
          ),
          title: const Text('Discover'),
          bottom: TabBar(
            labelColor: AppColors.primary,
            unselectedLabelColor: AppColors.onSurfaceVariant,
            indicatorColor: AppColors.primary,
            // Match indicator to the full tab width so the underline
            // spans the same distance as the selected tab's gradient
            // fill (default is `.label` which shrinks it to the text).
            indicatorSize: TabBarIndicatorSize.tab,
            tabs: const [
              Tab(text: '1v1'),
              Tab(text: 'Multi'),
              Tab(icon: Icon(Icons.search, size: 18)),
            ],
          ),
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
                return const _DiscoverShimmer();
              }
              if (snap.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Could not load open battles. Pull to retry.',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(color: AppColors.onSurfaceVariant),
                    ),
                  ),
                );
              }
              final all = snap.data ?? const <BattleModel>[];
              return TabBarView(
                children: [
                  _DiscoverList(
                    battles: all
                        .where((b) => b.type == BattleType.oneVsOne)
                        .toList(),
                    emptyTitle: 'No open 1v1 battles',
                    emptySubtitle:
                        'Be the first — create a public 1v1 battle.',
                    onJoin: _onJoin,
                    onEmptyCta: () => context.pop(),
                  ),
                  _DiscoverList(
                    battles: all
                        .where((b) => b.type == BattleType.group)
                        .toList(),
                    emptyTitle: 'No open multi battles',
                    emptySubtitle:
                        'Be the first — create a public multi battle.',
                    onJoin: _onJoin,
                    onEmptyCta: () => context.pop(),
                  ),
                  // Search across all open public battles regardless of
                  // format. Tap → same _onJoin flow so a matched result
                  // acts identically to tapping the card in its format tab.
                  BattleSearchTab(
                    battles: all,
                    currentUserId: uid,
                    scopeLabel: 'open battles',
                    onTap: _onJoin,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Loading skeleton shown while the initial Discover fetch is in
/// flight. Extracted so both tabs can reuse.
class _DiscoverShimmer extends StatelessWidget {
  const _DiscoverShimmer();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: const [
        ShimmerCard(),
        SizedBox(height: 12),
        ShimmerCard(),
        SizedBox(height: 12),
        ShimmerCard(),
      ],
    );
  }
}

/// Per-tab list body — receives the already-filtered subset of public
/// battles for the given tab and renders the shared card layout.
class _DiscoverList extends StatelessWidget {
  final List<BattleModel> battles;
  final String emptyTitle;
  final String emptySubtitle;
  final Future<void> Function(BattleModel) onJoin;
  final VoidCallback onEmptyCta;

  const _DiscoverList({
    required this.battles,
    required this.emptyTitle,
    required this.emptySubtitle,
    required this.onJoin,
    required this.onEmptyCta,
  });

  @override
  Widget build(BuildContext context) {
    if (battles.isEmpty) {
      return EmptyState(
        icon: Icons.travel_explore,
        title: emptyTitle,
        subtitle: emptySubtitle,
        ctaLabel: 'Back to Battles',
        onCtaTap: onEmptyCta,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 120),
      itemCount: battles.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, i) =>
          _PublicLobbyCard(battle: battles[i], onJoin: onJoin),
    );
  }
}

class _PublicLobbyCard extends StatelessWidget {
  final BattleModel battle;
  final Future<void> Function(BattleModel) onJoin;

  const _PublicLobbyCard({required this.battle, required this.onJoin});

  // First word of the "<type> battle by <name>" title.
  String get _typeLabel => switch (battle.type) {
        BattleType.oneVsOne => '1v1',
        BattleType.group => 'Multi',
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
                      '$_activeRoster / $_cap players · +${battle.stakeXp} XP',
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
              // Only pending battles surface in Discover (see
              // getPublicBattles). Once a public battle activates it
              // drops off this feed entirely, so there's no FULL state
              // to render here anymore.
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
                onPressed: () => onJoin(battle),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Join'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
