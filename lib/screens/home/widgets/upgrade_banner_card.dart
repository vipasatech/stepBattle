import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config/colors.dart';
import '../../../models/subscription_model.dart';
import '../../../providers/subscription_provider.dart';
import '../../../sheets/upgrade_cta_sheet.dart';

/// Compact "Go Pro" banner shown on Home only for users still on the
/// Free tier. Auto-hides the moment they upgrade — no dismiss state
/// to persist, since the tier itself gates the render. Placed between
/// the streak strip and the overview card so it's above-the-fold on
/// most phones but not the very first thing the eye lands on.
class UpgradeBannerCard extends ConsumerWidget {
  const UpgradeBannerCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sub = ref.watch(subscriptionProvider);
    if (sub.tier != SubscriptionTier.basic) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => showUpgradeCtaSheet(context),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppColors.primary.withValues(alpha: 0.22),
                  AppColors.primary.withValues(alpha: 0.08),
                ],
              ),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.4),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.rocket_launch,
                    color: AppColors.primary,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Go Pro',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: AppColors.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '4× battles, unlimited public joins, 500 XP streak bonus.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                          height: 1.35,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Icon(
                  Icons.arrow_forward_rounded,
                  color: AppColors.primary,
                  size: 18,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
