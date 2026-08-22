import 'package:flutter/material.dart';

import '../../../config/colors.dart';
import '../../../models/battle_model.dart';
import '../../../widgets/empty_state.dart';
import 'battle_card.dart';

/// Search-by-battle-ID tab for both Discover (open public battles) and
/// Completed (finished battles). Renders a persistent text field at the
/// top and filters `battles` by case-insensitive substring match on
/// either the 4-char short id ("20C9") or the full UUID prefix. Empty
/// query → hint state; matches < 1 → helpful "no match" state; matches
/// ≥ 1 → BattleCard list.
///
/// Shared so both screens stay consistent — a tester who learns the
/// pattern in Discover doesn't have to relearn it in Completed.
class BattleSearchTab extends StatefulWidget {
  final List<BattleModel> battles;
  final String currentUserId;
  final void Function(BattleModel)? onTap;
  final String scopeLabel;

  const BattleSearchTab({
    super.key,
    required this.battles,
    required this.currentUserId,
    this.onTap,
    this.scopeLabel = 'battles',
  });

  @override
  State<BattleSearchTab> createState() => _BattleSearchTabState();
}

class _BattleSearchTabState extends State<BattleSearchTab> {
  late final TextEditingController _controller;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _controller.addListener(() {
      setState(() => _query = _controller.text.trim());
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Case-insensitive match. Two accepted inputs:
  ///   • Short id shown on battle cards ("20C9" / "#20C9")
  ///   • Full UUID (or its prefix, since users may paste part of one)
  bool _matches(BattleModel b, String q) {
    final needle = q.replaceAll('#', '').toLowerCase();
    if (needle.isEmpty) return false;
    return b.shortId.replaceAll('#', '').toLowerCase().contains(needle) ||
        b.battleId.toLowerCase().contains(needle);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final results = _query.isEmpty
        ? const <BattleModel>[]
        : widget.battles.where((b) => _matches(b, _query)).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: _controller,
            autofocus: false,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search by battle ID (e.g. 20C9)',
              hintStyle: TextStyle(
                color: AppColors.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
              prefixIcon: Icon(Icons.search, color: AppColors.onSurfaceVariant),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      color: AppColors.onSurfaceVariant,
                      onPressed: () => _controller.clear(),
                    ),
              filled: true,
              fillColor: AppColors.surfaceContainerLow,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: AppColors.primary, width: 1.2),
              ),
            ),
          ),
        ),
        if (_query.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
            child: Row(
              children: [
                Text(
                  '${results.length} ${results.length == 1 ? "match" : "matches"}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: AppColors.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
        Expanded(
          child: _query.isEmpty
              ? EmptyState(
                  icon: Icons.search,
                  title: 'Search ${widget.scopeLabel}',
                  subtitle:
                      'Type a battle ID (or the 4-character short code) to jump straight to it.',
                )
              : results.isEmpty
                  ? EmptyState(
                      icon: Icons.search_off,
                      title: 'No match for "$_query"',
                      subtitle:
                          'Double-check the ID. IDs are 4 letters/digits — e.g. #20C9.',
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                      cacheExtent: 600,
                      itemCount: results.length,
                      itemBuilder: (_, i) {
                        final b = results[i];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: BattleCard(
                            battle: b,
                            currentUserId: widget.currentUserId,
                            onTap: widget.onTap == null
                                ? null
                                : () => widget.onTap!(b),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }
}
