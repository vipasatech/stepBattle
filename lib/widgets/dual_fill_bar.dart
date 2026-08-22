import 'package:flutter/material.dart';
import '../config/colors.dart';

/// Two-colour battle progress bar showing **share of total steps** between
/// you and your opponent.
///
/// Split-track layout — the two fills are ADJACENT, never overlapping:
///
///   `[purple: 0 → yourFraction]  [amber: yourFraction → 100%]`
///
/// This means both bars are ALWAYS visible regardless of who's winning
/// (the previous overlap layout hid the losing player's fill under the
/// winner's, which made a "700 vs 100" match look like a solo bar). The
/// bar always fills the whole track — the split point is the story.
class DualFillBar extends StatelessWidget {
  final int yourSteps;
  final int opponentSteps;
  final double height;

  const DualFillBar({
    super.key,
    required this.yourSteps,
    required this.opponentSteps,
    this.height = 14,
  });

  @override
  Widget build(BuildContext context) {
    final total = yourSteps + opponentSteps;
    final radius = height / 2;

    // No progress yet — show the empty pill only.
    if (total == 0) {
      return SizedBox(
        height: height,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(radius),
          ),
        ),
      );
    }

    final yourFraction = (yourSteps / total).clamp(0.0, 1.0);
    // Solo case corner-rounding: whichever bar fills alone gets ALL four
    // corners rounded; when both are present each takes half.
    final purpleRadius = opponentSteps == 0
        ? BorderRadius.circular(radius)
        : BorderRadius.horizontal(left: Radius.circular(radius));
    final amberRadius = yourSteps == 0
        ? BorderRadius.circular(radius)
        : BorderRadius.horizontal(right: Radius.circular(radius));

    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final yourWidth = constraints.maxWidth * yourFraction;
          const anim = Duration(milliseconds: 500);
          const curve = Curves.easeInOut;
          return Stack(
            children: [
              // Track (background pill) — always drawn, sits behind fills.
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(radius),
                ),
              ),
              // Opponent (amber) fill — from yourWidth to the right edge.
              if (opponentSteps > 0)
                AnimatedPositioned(
                  duration: anim,
                  curve: curve,
                  left: yourWidth,
                  top: 0,
                  bottom: 0,
                  right: 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFFF59E0B), Color(0xFFFBBF24)],
                      ),
                      borderRadius: amberRadius,
                    ),
                  ),
                ),
              // Your (purple) fill — from 0 to yourWidth.
              if (yourSteps > 0)
                AnimatedPositioned(
                  duration: anim,
                  curve: curve,
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: yourWidth,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [AppColors.primaryBrand, AppColors.primary],
                      ),
                      borderRadius: purpleRadius,
                    ),
                  ),
                ),
              // White marker at the split point — only when BOTH bars
              // exist (otherwise a single-colour bar doesn't need a
              // divider). Clamped so it never draws outside the track.
              if (yourSteps > 0 && opponentSteps > 0)
                AnimatedPositioned(
                  duration: anim,
                  curve: curve,
                  left: (yourWidth - 1.5)
                      .clamp(0.0, constraints.maxWidth - 3.0),
                  top: 0,
                  bottom: 0,
                  width: 3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      boxShadow: [
                        BoxShadow(
                          color:
                              AppColors.onSurface.withValues(alpha: 0.8),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
