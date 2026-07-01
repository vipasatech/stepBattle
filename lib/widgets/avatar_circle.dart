import 'package:flutter/material.dart';
import '../config/colors.dart';

/// User avatar circle with optional border ring and badge overlay.
class AvatarCircle extends StatelessWidget {
  final String? imageUrl;
  final String? initials;
  final double radius;
  /// Border-ring colour. Null defaults to the theme's primary at build
  /// time — kept nullable so the default flips automatically with the
  /// active theme rather than being baked at construction.
  final Color? borderColor;
  final double borderWidth;
  final Widget? badge;

  const AvatarCircle({
    super.key,
    this.imageUrl,
    this.initials,
    this.radius = 20,
    this.borderColor,
    this.borderWidth = 2,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final ring = borderColor ?? AppColors.primary;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: radius * 2,
          height: radius * 2,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: ring, width: borderWidth),
          ),
          child: CircleAvatar(
            radius: radius - borderWidth,
            backgroundColor: AppColors.surfaceContainerHighest,
            backgroundImage:
                imageUrl != null ? NetworkImage(imageUrl!) : null,
            child: imageUrl == null
                ? Text(
                    initials ?? '?',
                    style: TextStyle(
                      fontFamily: 'Space Grotesk',
                      fontWeight: FontWeight.w700,
                      fontSize: radius * 0.6,
                      color: AppColors.primary,
                    ),
                  )
                : null,
          ),
        ),
        if (badge != null)
          Positioned(
            bottom: -2,
            right: -2,
            child: badge!,
          ),
      ],
    );
  }
}
