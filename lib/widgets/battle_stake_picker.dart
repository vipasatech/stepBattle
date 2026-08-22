import 'package:flutter/material.dart';

import '../config/constants.dart';

/// Reusable XP-stake picker for battle-creation flows. Presets + ±50
/// stepper. Floor is the v2 economy minimum ([AppConstants.minBattleStakeXp],
/// currently 100). Displays live pot preview computed as
/// `stake × participantsCount` — for 1v1 the caller passes 2, for a
/// group battle they pass the count of accepted+creator seats.
class BattleStakePicker extends StatelessWidget {
  /// Current per-participant stake value.
  final int value;

  /// Called when the user picks a new value. Never below the min.
  final ValueChanged<int> onChanged;

  /// Number of participants used to compute the pot preview above the
  /// picker ("Pot X XP"). Must be ≥ 2 for the label to make sense.
  final int participantsCount;

  static const _presets = [100, 250, 500, 1000];
  static const _step = 50;

  const BattleStakePicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.participantsCount = 2,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Bind colors to the resolved ColorScheme instead of AppColors.
    // AppColors reads a global brightness flag that can go stale in
    // bottom-sheet subtrees (see [AppColors.updateBrightness] docs) —
    // when it does, "onSurface" resolves to the DARK variant (near-
    // white) even in light mode, producing white-on-light text ("100"
    // in the preset chips vanishes). ColorScheme is inherited via
    // Theme.of(context) and always matches the actual rendered theme.
    final scheme = theme.colorScheme;
    final floor = AppConstants.minBattleStakeXp;
    final pot = value * participantsCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('STAKE',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  letterSpacing: 2,
                  fontWeight: FontWeight.w800,
                )),
            const Spacer(),
            Text('Pot ${_fmt(pot)} XP',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w800,
                )),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final p in _presets) ...[
              Expanded(
                child: GestureDetector(
                  onTap: () => onChanged(p),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: p == value
                          ? scheme.primary.withValues(alpha: 0.18)
                          : scheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: p == value
                            ? scheme.primary
                            : scheme.outlineVariant,
                      ),
                    ),
                    child: Center(
                      child: Text(_fmt(p),
                          style: theme.textTheme.labelMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: p == value
                                ? scheme.primary
                                : scheme.onSurface,
                          )),
                    ),
                  ),
                ),
              ),
              if (p != _presets.last) const SizedBox(width: 6),
            ],
          ],
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton.outlined(
              onPressed: value > floor
                  ? () => onChanged((value - _step).clamp(floor, 1 << 30))
                  : null,
              icon: const Icon(Icons.remove),
            ),
            const SizedBox(width: 16),
            Text(
              '${_fmt(value)} XP',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(width: 16),
            IconButton.outlined(
              onPressed: () => onChanged(value + _step),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Plain-English explainer of the stake economics. Testers
        // reported it "looked like" no XP was deducted when they
        // accepted a battle — this line makes the transaction explicit
        // at creation time so both sides know what they're committing.
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: scheme.primary.withValues(alpha: 0.18),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(Icons.info_outline,
                  size: 16, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  // Winner-takes-the-pot is now shown in the top-right
                  // "Pot X XP" chip on the picker header; repeating it
                  // in the caption was noisy per tester feedback.
                  'Each player pays ${_fmt(value)} XP',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _fmt(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}
