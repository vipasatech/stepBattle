import 'package:flutter/material.dart';
import '../config/colors.dart';
import '../widgets/bottom_sheet_handle.dart';
import 'battle_1v1_setup_sheet.dart';
import 'battle_group_setup_sheet.dart';
import 'battle_team_setup_sheet.dart';

/// Step 1 of battle creation: choose 1v1, Multi-player, or Team format.
class NewBattleSelectionSheet extends StatefulWidget {
  const NewBattleSelectionSheet({super.key});

  @override
  State<NewBattleSelectionSheet> createState() =>
      _NewBattleSelectionSheetState();
}

class _NewBattleSelectionSheetState extends State<NewBattleSelectionSheet> {
  int? _selected; // 0 = 1v1, 1 = multi-player, 2 = team

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            24, 0, 24, 32 + MediaQuery.of(context).padding.bottom),
        child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const BottomSheetHandle(),

          // Title
          Align(
            alignment: Alignment.centerLeft,
            child: Text('New Battle',
                style: theme.textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('Choose your battle format',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: AppColors.onSurfaceVariant)),
          ),
          const SizedBox(height: 28),

          // Three selection cards — 1v1 / Multiplayer / Team.
          //
          // IntrinsicHeight collapses the Row's vertical extent to the
          // tallest child's natural height; without it `stretch` would
          // demand infinite height from a child inside the parent
          // SingleChildScrollView and the whole sheet would fail layout.
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _FormatCard(
                    icon: Icons.person,
                    title: '1v1',
                    subtitle: 'Head-to-head\nwith a friend',
                    isSelected: _selected == 0,
                    onTap: () => setState(() => _selected = 0),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _FormatCard(
                    icon: Icons.group,
                    title: 'Multiplayer',
                    subtitle: 'Free-for-all\nup to 10',
                    isSelected: _selected == 1,
                    onTap: () => setState(() => _selected = 1),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _FormatCard(
                    icon: Icons.flag,
                    title: 'Team',
                    subtitle: '2–4 teams\ncombined steps',
                    isSelected: _selected == 2,
                    onTap: () => setState(() => _selected = 2),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),

          // Continue button
          SizedBox(
            width: double.infinity,
            height: 56,
            child: FilledButton(
              onPressed: _selected != null ? _continue : null,
              style: FilledButton.styleFrom(
                disabledBackgroundColor: AppColors.surfaceContainerHigh,
                disabledForegroundColor: AppColors.onSurfaceVariant,
              ),
              child: const Text('Continue'),
            ),
          ),
        ],
        ),
      ),
    );
  }

  void _continue() {
    Navigator.pop(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      // Same reason as the parent selection sheet: push to root navigator
      // so the "Send Battle Invite" CTA at the bottom of the setup sheet
      // sits above the shell's bottom nav instead of being hidden behind it.
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => switch (_selected) {
        0 => const Battle1v1SetupSheet(),
        1 => const BattleGroupSetupSheet(),
        2 => const BattleTeamSetupSheet(),
        _ => const Battle1v1SetupSheet(),
      },
    );
  }
}

class _FormatCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool isSelected;
  final VoidCallback onTap;

  const _FormatCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primaryBrand.withValues(alpha: 0.1)
              : AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isSelected
                ? AppColors.primaryBrand
                : AppColors.outlineVariant,
            width: isSelected ? 2 : 1,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    blurRadius: 20,
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: isSelected
                    ? AppColors.primaryBrand.withValues(alpha: 0.2)
                    : AppColors.surfaceContainerHigh,
                shape: BoxShape.circle,
              ),
              child: Icon(icon,
                  color: isSelected
                      ? AppColors.primary
                      : AppColors.onSurfaceVariant,
                  size: 22),
            ),
            const SizedBox(height: 10),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                title,
                maxLines: 1,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                fontSize: 11,
                height: 1.25,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            // Selection checkmark
            if (isSelected) ...[
              const SizedBox(height: 8),
              Container(
                width: 18,
                height: 18,
                decoration: const BoxDecoration(
                  color: AppColors.primaryBrand,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check,
                    color: Colors.white, size: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
