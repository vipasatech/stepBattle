import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/colors.dart';
import '../providers/auth_provider.dart';
import '../utils/app_logger.dart';
import '../widgets/bottom_sheet_handle.dart';
import '../widgets/shimmer_loader.dart';

/// Read-only history of the caller's XP ledger entries for the last 7 days.
/// Opened from the "i" icon on the Buy XP sheet header so users can see
/// exactly where each earn / spend / refund happened before deciding to
/// top up.
///
/// Data source: `public.xp_ledger` (Migration 0016). RLS on that table
/// is self-only, so `.select().eq('user_id', me)` is redundant but kept
/// for the query planner + defence-in-depth.
Future<void> showXpHistorySheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useRootNavigator: true,
    builder: (_) => const _XpHistorySheet(),
  );
}

/// One row in the xp_ledger fetch — pared down to the fields the sheet
/// actually renders. Kept as a plain record so we don't pull in a
/// full model class for a read-only display use.
typedef _LedgerEntry = ({
  DateTime ts,
  int delta,
  String reason,
  String? battleId,
});

/// Riverpod provider — fetches the last 7 days of xp_ledger rows for
/// the current user. Autodispose so leaving the sheet drops the cache
/// (fresh fetch next open — the ledger is append-only, so cache stale-
/// ness only ever means "missing recent rows," never "wrong").
final _xpHistoryProvider =
    FutureProvider.autoDispose<List<_LedgerEntry>>((ref) async {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return const [];
  final cutoff =
      DateTime.now().toUtc().subtract(const Duration(days: 7));
  try {
    final rows = await Supabase.instance.client
        .from('xp_ledger')
        .select('delta, reason, created_at, context')
        .eq('user_id', user.id)
        .gte('created_at', cutoff.toIso8601String())
        .order('created_at', ascending: false)
        .limit(200);
    return (rows as List).map((r) {
      final ctx = r['context'];
      String? battleId;
      if (ctx is Map && ctx['battle_id'] is String) {
        battleId = ctx['battle_id'] as String;
      }
      return (
        ts: DateTime.tryParse(r['created_at']?.toString() ?? '')
                ?.toLocal() ??
            DateTime.now(),
        delta: (r['delta'] as num?)?.toInt() ?? 0,
        reason: (r['reason'] as String?) ?? 'admin_adjust',
        battleId: battleId,
      );
    }).toList();
  } catch (e, s) {
    AppLogger.xp.e('xpHistory:fetchFailed',
        fields: {'uid': user.id}, error: e, stack: s);
    return const [];
  }
});

class _XpHistorySheet extends ConsumerWidget {
  const _XpHistorySheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final async = ref.watch(_xpHistoryProvider);

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          children: [
            const BottomSheetHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('XP history',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: scheme.onSurface,
                        fontWeight: FontWeight.w900,
                      )),
                  const SizedBox(height: 4),
                  Text(
                    'Last 7 days — every earn, spend, and refund on your XP.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: async.when(
                loading: () => ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  children: const [
                    ShimmerLoader(height: 56, borderRadius: 12),
                    SizedBox(height: 8),
                    ShimmerLoader(height: 56, borderRadius: 12),
                    SizedBox(height: 8),
                    ShimmerLoader(height: 56, borderRadius: 12),
                    SizedBox(height: 8),
                    ShimmerLoader(height: 56, borderRadius: 12),
                  ],
                ),
                error: (e, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Could not load history: $e',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                data: (entries) {
                  if (entries.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.receipt_long_outlined,
                                size: 48,
                                color: scheme.onSurfaceVariant),
                            const SizedBox(height: 10),
                            Text(
                              'No XP activity in the last 7 days.',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  return ListView.separated(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _EntryTile(entry: entries[i]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  final _LedgerEntry entry;
  const _EntryTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final spec = _reasonSpec(entry.reason);
    // Deltas <0 are always "loss" (red); >0 are always "gain" (green).
    // A zero-delta row is technically possible from admin_adjust — treat
    // as neutral surface.
    final isLoss = entry.delta < 0;
    final isGain = entry.delta > 0;
    final amountColor = isGain
        ? AppColors.success
        : isLoss
            ? AppColors.error
            : scheme.onSurfaceVariant;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: spec.tint.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(spec.icon, color: spec.tint, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title line — for battle-scoped reasons, append the
                // 4-char battle id so users can trace which battle a
                // stake / refund / win came from ("Battle stake · #A3F2").
                Text(
                  entry.battleId != null && _isBattleReason(entry.reason)
                      ? '${spec.label} · #${_shortBattleId(entry.battleId!)}'
                      : spec.label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _friendlyTs(entry.ts),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${isLoss ? '' : '+'}${_fmt(entry.delta)} XP',
            style: theme.textTheme.titleSmall?.copyWith(
              color: amountColor,
              fontWeight: FontWeight.w800,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  static String _fmt(int n) {
    final absN = n.abs();
    final s = absN.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return n < 0 ? '-${buf.toString()}' : buf.toString();
  }

  /// Coarse "5 min ago / 2h ago / Jul 24" formatting. Matches the tone
  /// of the pending-battle countdown and battle-history date labels —
  /// no seconds-level precision needed on an economic log.
  static String _friendlyTs(DateTime ts) {
    final now = DateTime.now();
    final d = now.difference(ts);
    if (d.inMinutes < 1) return 'Just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    return _shortDate(ts);
  }

  // First 4 chars of the battle UUID, matching `BattleModel.shortId`
  // (the same tag shown on battle cards and the arena header).
  static String _shortBattleId(String id) =>
      id.length >= 4 ? id.substring(0, 4).toUpperCase() : id.toUpperCase();

  static bool _isBattleReason(String reason) =>
      reason == 'battle_stake' ||
      reason == 'battle_win' ||
      reason == 'battle_refund';

  static String _shortDate(DateTime t) {
    const months = [
      'Jan','Feb','Mar','Apr','May','Jun',
      'Jul','Aug','Sep','Oct','Nov','Dec'
    ];
    return '${months[t.month - 1]} ${t.day}';
  }
}

/// Icon + tint + human label per xp_ledger.reason value.
({IconData icon, Color tint, String label}) _reasonSpec(String reason) {
  switch (reason) {
    case 'daily_mission':
      return (
        icon: Icons.flag_outlined,
        tint: AppColors.tertiary,
        label: 'Daily mission',
      );
    case 'streak_milestone':
      return (
        icon: Icons.local_fire_department,
        tint: const Color(0xFFD97706),
        label: 'Streak milestone',
      );
    case 'battle_stake':
      return (
        icon: Icons.shield_outlined,
        tint: AppColors.error,
        label: 'Battle stake',
      );
    case 'battle_win':
      return (
        icon: Icons.emoji_events_outlined,
        tint: AppColors.success,
        label: 'Battle won',
      );
    case 'battle_refund':
      return (
        icon: Icons.replay,
        tint: AppColors.onSurfaceVariant,
        label: 'Battle refunded',
      );
    case 'purchase':
      return (
        icon: Icons.add_shopping_cart,
        tint: AppColors.primary,
        label: 'XP purchased',
      );
    case 'purchase_refund':
      // Visually pairs with 'purchase' above — same shopping-cart glyph
      // family, "remove" variant so the sheet reads purchase + refund as
      // a matched pair. Neutral tint on the badge because the row's
      // amount pill already renders red for the negative delta; a red
      // badge on top of that would double-signal.
      return (
        icon: Icons.remove_shopping_cart_outlined,
        tint: AppColors.onSurfaceVariant,
        label: 'XP refunded',
      );
    case 'admin_adjust':
    default:
      return (
        icon: Icons.tune,
        tint: AppColors.onSurfaceVariant,
        label: 'Adjustment',
      );
  }
}
