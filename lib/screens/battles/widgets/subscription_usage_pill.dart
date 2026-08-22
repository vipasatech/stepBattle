import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config/colors.dart';
import '../../../models/subscription_model.dart';
import '../../../providers/subscription_provider.dart';
import '../../../sheets/upgrade_cta_sheet.dart';

/// Small pill in the Battles-tab header: `"X/Y entries · Tier"`. Tap
/// opens [showUpgradeCtaSheet]. Colour shifts amber → red as the
/// user gets closer to their cap.
class SubscriptionUsagePill extends ConsumerWidget {
  const SubscriptionUsagePill({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sub = ref.watch(subscriptionProvider);
    final limits = sub.limits;
    final used = sub.usage.totalEntries;
    final cap = limits.monthlyBattleEntries;
    final ratio = cap == 0 ? 0.0 : used / cap;

    // Colour ladder: plenty left → primary tint; getting low → amber;
    // nearly out → error red.
    final Color colour = ratio < 0.5
        ? AppColors.primary
        : (ratio < 0.85 ? AppColors.amber : AppColors.error);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => showUpgradeCtaSheet(context),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: colour.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(14),
            border:
                Border.all(color: colour.withValues(alpha: 0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                sub.tier == SubscriptionTier.basic
                    ? Icons.workspace_premium_outlined
                    : Icons.workspace_premium,
                size: 13,
                color: colour,
              ),
              const SizedBox(width: 5),
              Text(
                '$used/$cap · ${sub.tier.displayName}',
                style: TextStyle(
                  color: colour,
                  fontFamily: 'Manrope',
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
