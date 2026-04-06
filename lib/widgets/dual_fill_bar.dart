import 'package:flutter/material.dart';
import '../config/colors.dart';

/// Two-colour battle progress bar: your steps vs opponent's steps.
/// Blue fill (you) overlaps amber fill (opponent).
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
    if (total == 0) {
      return SizedBox(
        height: height,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(height / 2),
          ),
        ),
      );
    }

    final yourFraction = (yourSteps / total).clamp(0.0, 1.0);
    final opponentFraction = (opponentSteps / total).clamp(0.0, 1.0);

    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            children: [
              // Track
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(height / 2),
                ),
              ),
              // Opponent (amber) — rendered first, behind
              AnimatedContainer(
                duration: const Duration(milliseconds: 500),
                width: constraints.maxWidth * opponentFraction,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFF59E0B), Color(0xFFFBBF24)],
                  ),
                  borderRadius: BorderRadius.circular(height / 2),
                ),
              ),
              // You (blue) — rendered on top
              AnimatedContainer(
                duration: const Duration(milliseconds: 500),
                width: constraints.maxWidth * yourFraction,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppColors.primaryBrand, AppColors.primary],
                  ),
                  borderRadius: BorderRadius.circular(height / 2),
                ),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Container(
                    width: 3,
                    height: height,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.white.withValues(alpha: 0.8),
                          blurRadius: 4,
                        ),
                      ],
                    ),
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
