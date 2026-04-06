import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/colors.dart';
import '../models/battle_model.dart';
import '../providers/battle_provider.dart';
import '../services/battle_service.dart';
import '../widgets/avatar_circle.dart';
import '../widgets/bottom_sheet_handle.dart';

/// 1v1 battle setup — select one opponent, then create.
class Battle1v1SetupSheet extends ConsumerStatefulWidget {
  const Battle1v1SetupSheet({super.key});

  @override
  ConsumerState<Battle1v1SetupSheet> createState() =>
      _Battle1v1SetupSheetState();
}

class _Battle1v1SetupSheetState extends ConsumerState<Battle1v1SetupSheet> {
  final _searchController = TextEditingController();
  String? _selectedOpponentId;
  String? _selectedOpponentName;
  bool _creating = false;

  final _battleCode = BattleService.generateBattleCode();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _createBattle() async {
    if (_selectedOpponentId == null) return;
    setState(() => _creating = true);

    try {
      final me = FirebaseAuth.instance.currentUser!;
      await ref.read(battleServiceProvider).createBattle(
            type: BattleType.oneVsOne,
            participants: [
              BattleParticipant(
                userId: me.uid,
                displayName: me.displayName ?? 'You',
                avatarURL: me.photoURL,
              ),
              BattleParticipant(
                userId: _selectedOpponentId!,
                displayName: _selectedOpponentName ?? 'Opponent',
              ),
            ],
            durationDays: 1,
            createdBy: me.uid,
          );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create battle: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: const BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
          children: [
            const BottomSheetHandle(),

            // Title + Battle ID
            Center(
              child: Text('1 vs 1',
                  style: theme.textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 4),
            Center(
              child: GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: _battleCode));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Battle ID copied!')),
                  );
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Battle ID: #$_battleCode',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.secondary,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.content_copy,
                        size: 14, color: AppColors.secondary),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 28),

            // Player layout: YOU vs SELECT FRIEND
            Row(
              children: [
                // You card
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppColors.glassBackground,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                          color: AppColors.primary.withValues(alpha: 0.2)),
                      boxShadow: [
                        BoxShadow(
                          color:
                              AppColors.primaryBrand.withValues(alpha: 0.15),
                          blurRadius: 20,
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        const AvatarCircle(
                          radius: 32,
                          initials: 'YOU',
                          borderColor: AppColors.primary,
                        ),
                        const SizedBox(height: 8),
                        Text('YOU',
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        Container(
                          margin: const EdgeInsets.only(top: 6),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text('Ready',
                              style: theme.textTheme.labelSmall?.copyWith(
                                  color: AppColors.onPrimary,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ),
                  ),
                ),
                // VS
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text('VS',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w900,
                        fontStyle: FontStyle.italic,
                      )),
                ),
                // Opponent slot
                Expanded(
                  child: GestureDetector(
                    onTap: () {
                      // TODO: Open Add Friends sheet in single-select mode
                    },
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: _selectedOpponentId != null
                              ? AppColors.primary.withValues(alpha: 0.3)
                              : AppColors.outlineVariant.withValues(alpha: 0.3),
                          width: 2,
                          strokeAlign: BorderSide.strokeAlignInside,
                        ),
                        color: _selectedOpponentId != null
                            ? AppColors.glassBackground
                            : AppColors.surfaceContainerLow,
                      ),
                      child: Column(
                        children: [
                          if (_selectedOpponentId != null) ...[
                            AvatarCircle(
                              radius: 32,
                              initials: _selectedOpponentName?[0] ?? '?',
                            ),
                            const SizedBox(height: 8),
                            Text(_selectedOpponentName ?? '',
                                style: theme.textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w700)),
                          ] else ...[
                            Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: AppColors.outlineVariant
                                        .withValues(alpha: 0.3),
                                    width: 2,
                                    strokeAlign:
                                        BorderSide.strokeAlignInside),
                              ),
                              child: const Icon(Icons.person_add,
                                  color: AppColors.onSurfaceVariant,
                                  size: 28),
                            ),
                            const SizedBox(height: 8),
                            Text('+ Select Friend',
                                style: theme.textTheme.labelSmall?.copyWith(
                                    color: AppColors.onSurfaceVariant)),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),

            // Search field
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search by name or username',
                prefixIcon:
                    const Icon(Icons.search, color: AppColors.outline),
                filled: true,
                fillColor:
                    Colors.white.withValues(alpha: 0.05),
              ),
            ),
            const SizedBox(height: 20),

            // Suggested rivals header
            Text('Suggested Rivals',
                style: theme.textTheme.labelSmall?.copyWith(
                    color: AppColors.onSurfaceVariant, letterSpacing: 2)),
            const SizedBox(height: 12),

            // Placeholder rival rows
            ..._buildSuggestedRivals(theme),

            const SizedBox(height: 28),

            // Create button
            SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton(
                onPressed:
                    _selectedOpponentId != null && !_creating
                        ? _createBattle
                        : null,
                style: FilledButton.styleFrom(
                  disabledBackgroundColor: AppColors.surfaceContainerHighest,
                  disabledForegroundColor: AppColors.onSurfaceVariant,
                ),
                child: _creating
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Create Battle'),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                'Battle starts immediately after opponent accepts',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildSuggestedRivals(ThemeData theme) {
    // Placeholder data — will be replaced by friend list provider
    final rivals = [
      ('Marcus_Bolt', 'MB', 'Rank #42 · 12.4k Avg Steps', AppColors.primary),
      ('Sarah_Sprint', 'SS', 'Rank #12 · 15.1k Avg Steps', AppColors.tertiary),
      ('Leo.Steps', 'LS', 'Rank #89 · 10.8k Avg Steps', AppColors.secondary),
    ];

    return rivals.map((r) {
      final isSelected = _selectedOpponentName == r.$1;
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.primaryBrand.withValues(alpha: 0.1)
                : AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              AvatarCircle(
                radius: 22,
                initials: r.$2,
                borderColor: r.$4,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.$1,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    Text(r.$3, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () => setState(() {
                  _selectedOpponentId = 'placeholder_${r.$1}';
                  _selectedOpponentName = r.$1;
                }),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? AppColors.success
                        : AppColors.primaryBrand,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    isSelected ? Icons.check : Icons.add,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }).toList();
  }
}
