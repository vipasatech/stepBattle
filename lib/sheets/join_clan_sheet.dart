import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/colors.dart';
import '../models/clan_model.dart';
import '../providers/clan_provider.dart';
import '../widgets/bottom_sheet_handle.dart';

class JoinClanSheet extends ConsumerStatefulWidget {
  const JoinClanSheet({super.key});

  @override
  ConsumerState<JoinClanSheet> createState() => _JoinClanSheetState();
}

class _JoinClanSheetState extends ConsumerState<JoinClanSheet> {
  final _searchController = TextEditingController();
  List<ClanModel> _results = [];
  bool _searching = false;
  bool _joining = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _searchController.text.trim();
    if (q.isEmpty) return;
    setState(() => _searching = true);
    try {
      final results = await ref.read(clanServiceProvider).searchClans(q);
      setState(() => _results = results);
    } catch (_) {
      // ignore
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _joinClan(ClanModel clan) async {
    setState(() => _joining = true);
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      await ref
          .read(clanServiceProvider)
          .joinClan(clanId: clan.clanId, userId: uid);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85),
      decoration: const BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const BottomSheetHandle(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Join a Clan',
                    style: theme.textTheme.headlineMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('Enter a Clan ID or search by name',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: AppColors.onSurfaceVariant)),
                const SizedBox(height: 20),

                // Search field
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        style: theme.textTheme.bodyMedium,
                        onSubmitted: (_) => _search(),
                        decoration: InputDecoration(
                          hintText: 'Enter Clan ID (e.g. #CL7X9) or clan name',
                          prefixIcon: const Icon(Icons.search,
                              color: AppColors.outline, size: 20),
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _search,
                      child: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: AppColors.primaryBrand,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.arrow_forward,
                            color: Colors.white, size: 20),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Results
          Flexible(
            child: _searching
                ? const Center(
                    child:
                        CircularProgressIndicator(color: AppColors.primary))
                : _results.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(40),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.shield,
                                size: 48,
                                color: AppColors.onSurfaceVariant
                                    .withValues(alpha: 0.3)),
                            const SizedBox(height: 12),
                            Text('Search for a clan above to get started',
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: AppColors.onSurfaceVariant),
                                textAlign: TextAlign.center),
                          ],
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        itemCount: _results.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: 10),
                        itemBuilder: (_, i) =>
                            _ClanResultRow(
                              clan: _results[i],
                              onJoin: _joining
                                  ? null
                                  : () => _joinClan(_results[i]),
                            ),
                      ),
          ),

          // Cancel
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
            child: SizedBox(
              width: double.infinity,
              height: 50,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ClanResultRow extends StatelessWidget {
  final ClanModel clan;
  final VoidCallback? onJoin;

  const _ClanResultRow({required this.clan, this.onJoin});

  static const _colors = [
    AppColors.error,
    AppColors.success,
    AppColors.tertiary,
    AppColors.primary,
    AppColors.amber,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accentColor = _colors[clan.name.length % _colors.length];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border(left: BorderSide(color: accentColor, width: 4)),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.shield, color: accentColor, size: 24),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(clan.name,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                Text(
                  '${clan.memberCount} / ${clan.maxMembers} members | ${clan.totalClanXP} XP',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: AppColors.onSurfaceVariant),
                ),
              ],
            ),
          ),
          FilledButton(
            onPressed: clan.isFull ? null : onJoin,
            style: FilledButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
            child: Text(clan.isFull ? 'Full' : 'Join'),
          ),
        ],
      ),
    );
  }
}
