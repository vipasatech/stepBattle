import 'package:flutter/material.dart';
import '../config/colors.dart';

/// Gradient progress bar with a "spark" glow at the leading edge.
/// Per DESIGN.md: gradient fill from primary to secondary, spark element at leading edge.
class StepProgressBar extends StatelessWidget {
  final double progress; // 0.0 – 1.0
  final double height;
  final Color? startColor;
  final Color? endColor;
  final Color? trackColor;
  final bool showSpark;

  const StepProgressBar({
    super.key,
    required this.progress,
    this.height = 12,
    this.startColor,
    this.endColor,
    this.trackColor,
    this.showSpark = true,
  });

  @override
  Widget build(BuildContext context) {
    final clamped = progress.clamp(0.0, 1.0);
    final start = startColor ?? AppColors.primaryBrand;
    final end = endColor ?? AppColors.primary;

    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final fillWidth = constraints.maxWidth * clamped;
          return Stack(
            children: [
              // Track
              Container(
                decoration: BoxDecoration(
                  color: trackColor ?? AppColors.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(height / 2),
                ),
              ),
              // Fill
              if (clamped > 0)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.easeOutCubic,
                  width: fillWidth,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [start, end],
                    ),
                    borderRadius: BorderRadius.circular(height / 2),
                  ),
                ),
              // Spark glow at leading edge
              if (showSpark && clamped > 0.02)
                Positioned(
                  left: fillWidth - (height / 2),
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: Container(
                      width: height * 0.6,
                      height: height * 0.6,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.white.withValues(alpha: 0.8),
                            blurRadius: 8,
                            spreadRadius: 2,
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
