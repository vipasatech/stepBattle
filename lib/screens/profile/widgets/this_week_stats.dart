import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../config/colors.dart';
import '../../../providers/step_provider.dart';
import '../../../widgets/glass_card.dart';

/// "This Week" stats section — total steps, XP earned, battles won, missions done.
class ThisWeekStats extends ConsumerWidget {
  const ThisWeekStats({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final weeklySteps = ref.watch(weeklyStepsProvider).valueOrNull ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('This Week',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700)),
            Icon(Icons.calendar_month, color: AppColors.primary, size: 22),
          ],
        ),
        const SizedBox(height: 12),
        GlassCard(
          padding: const EdgeInsets.all(20),
          borderRadius: 20,
          child: Column(
            children: [
              _StatRow(
                  label: 'Total Steps',
                  value: _fmt(weeklySteps),
                  valueColor: AppColors.primary),
              _Divider(),
              _StatRow(
                  label: 'XP Earned',
                  value: '200 XP',
                  valueColor: AppColors.tertiary),
              _Divider(),
              _StatRow(label: 'Battles Won', value: '2 / 3'),
              _Divider(),
              _StatRow(label: 'Missions Done', value: '7 / 10'),
            ],
          ),
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

class _StatRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _StatRow({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: AppColors.onSurfaceVariant)),
          Text(value,
              style: theme.textTheme.titleMedium?.copyWith(
                color: valueColor ?? AppColors.onSurface,
                fontWeight: FontWeight.w700,
              )),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(height: 1, color: Colors.white.withValues(alpha: 0.05));
  }
}
