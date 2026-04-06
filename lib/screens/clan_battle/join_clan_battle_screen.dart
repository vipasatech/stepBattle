import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../config/colors.dart';
import '../../models/clan_battle_model.dart';
import '../../providers/clan_provider.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/status_pill.dart';

class JoinClanBattleScreen extends ConsumerStatefulWidget {
  const JoinClanBattleScreen({super.key});

  @override
  ConsumerState<JoinClanBattleScreen> createState() =>
      _JoinClanBattleScreenState();
}

class _JoinClanBattleScreenState
    extends ConsumerState<JoinClanBattleScreen> {
  List<ClanBattleModel> _battles = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadBattles();
  }

  Future<void> _loadBattles() async {
    try {
      final battles =
          await ref.read(clanServiceProvider).getAvailableClanBattles();
      if (mounted) {
        setState(() {
          _battles = battles;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('BATTLE ARENA',
                style: theme.textTheme.titleMedium?.copyWith(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w700,
                    fontStyle: FontStyle.italic)),
            Text('Available Battles',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: AppColors.onSurfaceVariant)),
          ],
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary))
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
              children: [
                // Hero
                GlassCard(
                  padding: const EdgeInsets.all(28),
                  border: Border.all(
                      color: AppColors.primary.withValues(alpha: 0.1)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('CLAN BATTLES',
                          style: theme.textTheme.headlineLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                              letterSpacing: -1)),
                      const SizedBox(height: 6),
                      Text(
                          'Join forces with your squad and dominate the leaderboard.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                              color: AppColors.onSurfaceVariant)),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                if (_battles.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(40),
                    child: Center(
                      child: Column(
                        children: [
                          Icon(Icons.bolt,
                              size: 48,
                              color: AppColors.onSurfaceVariant
                                  .withValues(alpha: 0.3)),
                          const SizedBox(height: 12),
                          Text('No open clan battles right now',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                  color: AppColors.onSurfaceVariant)),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: Text('Create one instead \u2192',
                                style: theme.textTheme.labelLarge
                                    ?.copyWith(color: AppColors.primary)),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  ..._battles.map((b) => Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: _BattleListCard(battle: b),
                      )),
              ],
            ),
    );
  }
}

class _BattleListCard extends StatelessWidget {
  final ClanBattleModel battle;

  const _BattleListCard({required this.battle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLive = battle.status == ClanBattleStatus.active;

    return GlassCard(
      padding: const EdgeInsets.all(20),
      border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.05)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.groups, color: AppColors.primary, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${battle.clanA.clanName} vs ${battle.clanB.clanName}',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _InfoChip(
                icon: Icons.schedule,
                label: '${battle.durationDays}-Day Battle',
              ),
              if (isLive)
                const StatusPill(type: StatusType.live)
              else
                _InfoChip(
                    icon: Icons.calendar_today, label: 'Starts soon'),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () {
                // TODO: Join the battle with current clan
              },
              child: const Text('Join'),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppColors.primary),
          const SizedBox(width: 5),
          Text(label,
              style: const TextStyle(
                fontFamily: 'Manrope',
                fontSize: 11,
                fontWeight: FontWeight.w700,
              )),
        ],
      ),
    );
  }
}
