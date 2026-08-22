import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/colors.dart';
import '../models/subscription_model.dart';
import '../providers/subscription_provider.dart';

/// The little "verified" badge shown next to paid users' names.
///
/// Uses Material's [Icons.verified] (the 8-point rosette with a
/// checkmark) tinted with our purple → violet gradient via a
/// [ShaderMask]. That gives the same premium-checkmark UX Twitter /
/// Instagram users are trained to recognise WITHOUT copying either
/// brand's exact icon or blue color — the icon shape itself is part
/// of the free Material Icons set, and the color is ours.
///
/// Auto-hides on Free-tier accounts, so callers don't need to gate
/// it themselves — just place it wherever a paid user's name shows
/// and it silently disappears when the tier is Free.
class ProBadge extends ConsumerWidget {
  /// Overall size in logical pixels. 18 works well next to display
  /// names; 12 for tight spots like avatar corners.
  final double size;

  /// If true, tapping does nothing (the badge is decorative). Set
  /// to a callback to route users to the subscription screen from a
  /// tap — useful for teasing the feature to non-Pro users, but we
  /// only render for paid users so the callback is optional.
  final VoidCallback? onTap;

  const ProBadge({super.key, this.size = 18, this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tier = ref.watch(subscriptionProvider).tier;
    if (tier == SubscriptionTier.basic) return const SizedBox.shrink();

    // Family gets the accent-teal gradient; Pro keeps the purple.
    // Same physical shape either way — reads as "verified" at any
    // glance, but the color quietly signals which tier they're on.
    final gradient = tier == SubscriptionTier.max
        ? LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.tertiary,
              AppColors.tertiary.withValues(alpha: 0.7),
            ],
          )
        : LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.primary,
              const Color(0xFF7C3AED),
            ],
          );

    final badge = ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => gradient.createShader(bounds),
      child: Icon(
        Icons.verified,
        size: size,
        color: Colors.white, // masked by ShaderMask; color required
      ),
    );

    if (onTap == null) return badge;
    return GestureDetector(onTap: onTap, child: badge);
  }
}
