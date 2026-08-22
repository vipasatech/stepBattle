import 'package:flutter/material.dart';
import '../config/colors.dart';

/// Card surface used throughout the app.
///
/// Was originally implemented as a real glassmorphism widget (a
/// `ClipRRect + BackdropFilter(ImageFilter.blur(20))` compositing the
/// framebuffer on every frame). That looked lovely on a screenshot
/// but was the single biggest scroll-jank source: 4-5 of these
/// stacked in the Home viewport meant 4-5 full-viewport Gaussian
/// blurs every composite frame while the list scrolled underneath.
///
/// This version keeps the visual identity — soft rounded rectangle,
/// subtle border, warm inner glow — but paints it with an opaque
/// tinted `Container`. No `BackdropFilter`, no compositor
/// framebuffer read, no per-frame blur cost. On the dark theme the
/// difference is essentially invisible against the ambient dark
/// background; on light theme it reads as a clean elevated card
/// rather than a see-through pane. The name stays for callers.
///
/// If the frosted look ever needs to come back for a specific
/// surface (e.g. a floating sheet over a photo), use a bespoke
/// `BackdropFilter` there — don't reintroduce it here, because the
/// callers of `GlassCard` are almost all on scroll paths.
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final Border? border;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(24),
    this.borderRadius = 24,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        // Opaque tinted surface, alpha ~0.94 so it still reads as
        // "surface variant" without letting the frame below composite
        // through. `glassBackground` is theme-aware and swaps between
        // light/dark surface tints automatically.
        color: AppColors.glassBackground,
        borderRadius: BorderRadius.circular(borderRadius),
        border: border ??
            Border.all(
              color: AppColors.onSurface.withValues(alpha: 0.05),
            ),
        boxShadow: [
          BoxShadow(
            color: AppColors.glassGlow,
            blurRadius: 4,
            spreadRadius: 0,
          ),
        ],
      ),
      child: child,
    );
  }
}
