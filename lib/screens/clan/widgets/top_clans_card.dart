import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../config/colors.dart';
import '../../../widgets/glass_card.dart';

/// Top-10 clans by `clans.clan_xp` (migration 0016 + 0017).
///
/// Lives on the Clan dashboard. The list is auto-refreshed when this
/// widget rebuilds (e.g., the user pulls down). Reads the `clans` table
/// directly — no separate view is needed since [clan_xp] is the single
/// authoritative balance.
final _topClansProvider = FutureProvider<List<_ClanRankRow>>((ref) async {
  final supabase = Supabase.instance.client;
  final rows = await supabase
      .from('clans')
      .select('id, name, tag, clan_xp')
      .order('clan_xp', ascending: false)
      .limit(10);
  return (rows as List)
      .map((r) => _ClanRankRow.fromRow(r as Map<String, dynamic>))
      .toList();
});

class TopClansCard extends ConsumerWidget {
  const TopClansCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(_topClansProvider);

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
      borderRadius: 20,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.shield_moon_outlined,
                  color: AppColors.primary, size: 18),
              const SizedBox(width: 8),
              Text('TOP CLANS BY XP',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: AppColors.onSurfaceVariant,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w800,
                  )),
            ],
          ),
          const SizedBox(height: 12),
          async.when(
            data: (rows) => rows.isEmpty
                ? _empty(theme)
                : Column(
                    children: [
                      for (var i = 0; i < rows.length; i++)
                        _ClanRow(
                            index: i + 1, row: rows[i], isLast: i == rows.length - 1),
                    ],
                  ),
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Couldn\'t load clan ranks',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.onSurfaceVariant),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _empty(ThemeData theme) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          'No clans yet — be the first to earn clan XP.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: AppColors.onSurfaceVariant),
        ),
      );
}

class _ClanRankRow {
  final String id;
  final String name;
  final String? tag;
  final int clanXp;

  _ClanRankRow({
    required this.id,
    required this.name,
    required this.tag,
    required this.clanXp,
  });

  factory _ClanRankRow.fromRow(Map<String, dynamic> r) => _ClanRankRow(
        id: r['id'] as String,
        name: (r['name'] as String?) ?? 'Unnamed Clan',
        tag: r['tag'] as String?,
        clanXp: (r['clan_xp'] as num?)?.toInt() ?? 0,
      );
}

class _ClanRow extends StatelessWidget {
  final int index;
  final _ClanRankRow row;
  final bool isLast;
  const _ClanRow({
    required this.index,
    required this.row,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isPodium = index <= 3;
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 8),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isPodium
                  ? AppColors.primary.withValues(alpha: 0.15)
                  : AppColors.surfaceContainerHigh,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$index',
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: isPodium
                    ? AppColors.primary
                    : AppColors.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Row(
              children: [
                if (row.tag != null && row.tag!.isNotEmpty) ...[
                  Text(
                    '[${row.tag}]',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.primaryBrand,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    row.name,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Text(
            _fmt(row.clanXp),
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: AppColors.primary,
            ),
          ),
        ],
      ),
    );
  }

  static String _fmt(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) {
      final k = n / 1000.0;
      return '${k.toStringAsFixed(k < 10 ? 1 : 0)}K';
    }
    return '${(n / 1000000).toStringAsFixed(1)}M';
  }
}
