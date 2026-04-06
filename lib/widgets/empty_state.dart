import 'package:flutter/material.dart';
import '../config/colors.dart';

/// Reusable empty state — every list must have one per spec.
/// Shows icon + headline + sub-text + optional CTA button.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? ctaLabel;
  final VoidCallback? onCtaTap;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.ctaLabel,
    this.onCtaTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: AppColors.onSurfaceVariant.withValues(alpha: 0.4)),
          const SizedBox(height: 20),
          Text(
            title,
            style: theme.textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppColors.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          if (ctaLabel != null) ...[
            const SizedBox(height: 24),
            FilledButton(
              onPressed: onCtaTap,
              child: Text(ctaLabel!),
            ),
          ],
        ],
      ),
    );
  }
}
