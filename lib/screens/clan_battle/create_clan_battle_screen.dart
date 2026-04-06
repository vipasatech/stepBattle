import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../config/colors.dart';
import '../../models/clan_model.dart';
import '../../providers/clan_provider.dart';
import '../../widgets/glass_card.dart';

class CreateClanBattleScreen extends ConsumerStatefulWidget {
  const CreateClanBattleScreen({super.key});

  @override
  ConsumerState<CreateClanBattleScreen> createState() =>
      _CreateClanBattleScreenState();
}

class _CreateClanBattleScreenState
    extends ConsumerState<CreateClanBattleScreen> {
  final _searchController = TextEditingController();
  ClanModel? _selectedOpponent;
  int _durationDays = 3;
  String _battleType = 'total_steps';
  bool _creating = false;
  List<ClanModel> _searchResults = [];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _searchController.text.trim();
    if (q.isEmpty) return;
    try {
      final results = await ref.read(clanServiceProvider).searchClans(q);
      setState(() => _searchResults = results);
    } catch (_) {}
  }

  Future<void> _create() async {
    if (_selectedOpponent == null) return;
    final myClan = ref.read(currentClanProvider).valueOrNull;
    if (myClan == null) return;

    setState(() => _creating = true);
    try {
      await ref.read(clanServiceProvider).createClanBattle(
            clanAId: myClan.clanId,
            clanAName: myClan.name,
            clanBId: _selectedOpponent!.clanId,
            clanBName: _selectedOpponent!.name,
            durationDays: _durationDays,
            battleType: _battleType,
          );
      if (mounted) Navigator.pop(context);
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
    final myClan = ref.watch(currentClanProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('CREATE CLAN BATTLE',
            style: theme.textTheme.titleMedium?.copyWith(
                color: AppColors.primary,
                fontWeight: FontWeight.w700,
                fontStyle: FontStyle.italic)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
        children: [
          // Matchup hero
          GlassCard(
            padding: const EdgeInsets.all(28),
            child: Row(
              children: [
                // My clan
                Expanded(
                  child: Column(
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                              color:
                                  AppColors.primary.withValues(alpha: 0.4)),
                        ),
                        child: const Icon(Icons.groups,
                            color: AppColors.primary, size: 36),
                      ),
                      const SizedBox(height: 8),
                      Text(myClan?.name ?? 'Your Clan',
                          style: theme.textTheme.labelMedium?.copyWith(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w700),
                          textAlign: TextAlign.center),
                    ],
                  ),
                ),
                Text('VS',
                    style: theme.textTheme.headlineSmall?.copyWith(
                        color: AppColors.outlineVariant.withValues(alpha: 0.4),
                        fontWeight: FontWeight.w900,
                        fontStyle: FontStyle.italic)),
                // Opponent
                Expanded(
                  child: GestureDetector(
                    onTap: () {},
                    child: Column(
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: _selectedOpponent != null
                                  ? AppColors.primary
                                      .withValues(alpha: 0.3)
                                  : AppColors.outlineVariant
                                      .withValues(alpha: 0.3),
                              width: 2,
                              strokeAlign: BorderSide.strokeAlignInside,
                            ),
                          ),
                          child: _selectedOpponent != null
                              ? Icon(Icons.shield,
                                  color: AppColors.primary, size: 36)
                              : const Icon(Icons.person_search,
                                  color: AppColors.onSurfaceVariant,
                                  size: 28),
                        ),
                        const SizedBox(height: 8),
                        Text(
                            _selectedOpponent?.name ??
                                'Search Opponent',
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: AppColors.onSurfaceVariant),
                            textAlign: TextAlign.center),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Search
          TextField(
            controller: _searchController,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: 'Find a rival clan...',
              prefixIcon:
                  const Icon(Icons.search, color: AppColors.outline),
            ),
          ),
          const SizedBox(height: 12),

          // Search results
          ..._searchResults.map((clan) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  tileColor: _selectedOpponent?.clanId == clan.clanId
                      ? AppColors.primaryBrand.withValues(alpha: 0.1)
                      : AppColors.surfaceContainerLow,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  leading: Icon(Icons.shield, color: AppColors.tertiary),
                  title: Text(clan.name,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  subtitle: Text(
                      '${clan.memberCount} members · ${clan.totalClanXP} XP',
                      style: theme.textTheme.bodySmall),
                  trailing: FilledButton(
                    onPressed: () =>
                        setState(() => _selectedOpponent = clan),
                    style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 6)),
                    child: const Text('Select'),
                  ),
                ),
              )),

          const SizedBox(height: 24),

          // Config
          Text('BATTLE CONFIGURATION',
              style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.onSurfaceVariant, letterSpacing: 2)),
          const SizedBox(height: 12),

          GlassCard(
            padding: EdgeInsets.zero,
            borderRadius: 16,
            child: Column(
              children: [
                // Duration
                _ConfigRow(
                  icon: Icons.schedule,
                  label: 'Duration',
                  child: Row(
                    children: [1, 3, 7].map((d) {
                      final sel = d == _durationDays;
                      return Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: GestureDetector(
                          onTap: () =>
                              setState(() => _durationDays = d),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 7),
                            decoration: BoxDecoration(
                              color: sel
                                  ? AppColors.primary
                                  : AppColors.surfaceContainerLowest,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text('$d Day${d > 1 ? 's' : ''}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: sel
                                      ? AppColors.onPrimary
                                      : AppColors.onSurfaceVariant,
                                  fontWeight: FontWeight.w700,
                                )),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                Divider(
                    height: 1,
                    color: AppColors.outlineVariant.withValues(alpha: 0.1)),
                // Type
                _ConfigRow(
                  icon: Icons.leaderboard,
                  label: 'Battle Type',
                  child: DropdownButton<String>(
                    value: _battleType,
                    underline: const SizedBox(),
                    dropdownColor: AppColors.surfaceContainerHigh,
                    style: theme.textTheme.titleSmall?.copyWith(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w700),
                    items: const [
                      DropdownMenuItem(
                          value: 'total_steps',
                          child: Text('Total Steps')),
                      DropdownMenuItem(
                          value: 'daily_average',
                          child: Text('Daily Average')),
                    ],
                    onChanged: (v) =>
                        setState(() => _battleType = v ?? 'total_steps'),
                  ),
                ),
                Divider(
                    height: 1,
                    color: AppColors.outlineVariant.withValues(alpha: 0.1)),
                // Reward
                _ConfigRow(
                  icon: Icons.military_tech,
                  label: 'Reward Pool',
                  child: Text('+300 XP',
                      style: theme.textTheme.titleSmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                          fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),

          // Buttons
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton(
              onPressed:
                  _selectedOpponent != null && !_creating ? _create : null,
              style: FilledButton.styleFrom(
                disabledBackgroundColor:
                    AppColors.primary.withValues(alpha: 0.2),
              ),
              child: _creating
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('CREATE BATTLE'),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: OutlinedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('CANCEL'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConfigRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget child;

  const _ConfigRow(
      {required this.icon, required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          Icon(icon, color: AppColors.onSurfaceVariant, size: 20),
          const SizedBox(width: 12),
          Text(label,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w500)),
          const Spacer(),
          child,
        ],
      ),
    );
  }
}
