import 'package:flutter/material.dart';
import '../../../config/colors.dart';
import '../../../models/user_model.dart';

/// "All Time" stats — 2x2 grid: Total XP, Battles, Best Streak, Total Steps.
class AllTimeStats extends StatelessWidget {
  final UserModel user;

  const AllTimeStats({super.key, required this.user});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('All Time',
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _StatTile(
                label: 'Total XP',
                value: _fmt(user.totalXP),
                valueColor: AppColors.tertiary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatTile(
                label: 'Battles',
                child: RichText(
                  text: TextSpan(
                    style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700),
                    children: [
                      TextSpan(
                          text: '4W',
                          style: TextStyle(color: AppColors.primary)),
                      const TextSpan(text: ' / '),
                      TextSpan(
                          text: '3L',
                          style: TextStyle(color: AppColors.errorDim)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _StatTile(
                label: 'Best Streak',
                value: '${user.bestStreak} DAYS',
                valueColor: AppColors.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatTile(
                label: 'Total Steps',
                value: _fmt(user.totalStepsAllTime),
              ),
            ),
          ],
        ),
      ],
    );
  }

  static String _fmt(int n) {
    if (n == 0) return '0';
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String? value;
  final Color? valueColor;
  final Widget? child;

  const _StatTile({required this.label, this.value, this.valueColor, this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        children: [
          Text(label,
              style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.outline, letterSpacing: 2)),
          const SizedBox(height: 8),
          child ??
              Text(value ?? '',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: valueColor ?? AppColors.onSurface,
                    fontWeight: FontWeight.w700,
                  )),
        ],
      ),
    );
  }
}
