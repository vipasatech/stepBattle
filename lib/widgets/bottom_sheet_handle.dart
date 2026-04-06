import 'package:flutter/material.dart';
import '../config/colors.dart';

/// Standard drag handle for bottom sheets — per spec: pill at top centre.
class BottomSheetHandle extends StatelessWidget {
  const BottomSheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 48,
        height: 5,
        margin: const EdgeInsets.only(top: 12, bottom: 20),
        decoration: BoxDecoration(
          color: AppColors.outlineVariant.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(3),
        ),
      ),
    );
  }
}
