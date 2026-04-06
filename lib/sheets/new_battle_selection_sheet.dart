import 'package:flutter/material.dart';
import '../config/colors.dart';
import '../widgets/bottom_sheet_handle.dart';
import 'battle_1v1_setup_sheet.dart';
import 'battle_group_setup_sheet.dart';

/// Step 1 of battle creation: choose 1v1 or Group format.
class NewBattleSelectionSheet extends StatefulWidget {
  const NewBattleSelectionSheet({super.key});

  @override
  State<NewBattleSelectionSheet> createState() =>
      _NewBattleSelectionSheetState();
}

class _NewBattleSelectionSheetState extends State<NewBattleSelectionSheet> {
  int? _selected; // 0 = 1v1, 1 = group

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
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

          // Two selection cards
          Row(
            children: [
              Expanded(
                child: _FormatCard(
                  icon: Icons.person,
                  title: '1 vs 1',
                  subtitle: 'Compete head-to-head\nwith one friend',
                  isSelected: _selected == 0,
                  onTap: () => setState(() => _selected = 0),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _FormatCard(
                  icon: Icons.group,
                  title: 'Group Battle',
                  subtitle: 'Compete with multiple\nparticipants',
                  isSelected: _selected == 1,
                  onTap: () => setState(() => _selected = 1),
                ),
              ),
            ],
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
    );
  }

  void _continue() {
    Navigator.pop(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _selected == 0
          ? const Battle1v1SetupSheet()
          : const BattleGroupSetupSheet(),
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
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primaryBrand.withValues(alpha: 0.1)
              : AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(20),
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
          children: [
            Container(
              width: 52,
              height: 52,
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
                  size: 28),
            ),
            const SizedBox(height: 12),
            Text(title,
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                fontSize: 11,
              ),
              textAlign: TextAlign.center,
            ),
            // Selection checkmark
            if (isSelected) ...[
              const SizedBox(height: 8),
              Container(
                width: 20,
                height: 20,
                decoration: const BoxDecoration(
                  color: AppColors.primaryBrand,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check,
                    color: Colors.white, size: 14),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
