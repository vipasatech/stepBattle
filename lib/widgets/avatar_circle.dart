import 'dart:io';

import 'package:flutter/material.dart';
import '../config/colors.dart';
import 'app_network_image.dart';

/// User avatar circle with optional border ring and badge overlay.
///
/// Image priority: `localImagePath` (device-only profile photo) →
/// `imageUrl` (Supabase-hosted avatar) → `initials`.
class AvatarCircle extends StatelessWidget {
  final String? imageUrl;
  /// Path to a local image file on device — takes priority over
  /// `imageUrl`. Used by the profile screen for the user's own
  /// device-only photo pick.
  final String? localImagePath;
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
    this.localImagePath,
    this.initials,
    this.radius = 20,
    this.borderColor,
    this.borderWidth = 2,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final ring = borderColor ?? AppColors.primary;
    // Decode the bitmap at the render size × device pixel ratio.
    // Without this the ImageProvider path (which CircleAvatar uses
    // instead of the CachedNetworkImage widget) decoded 2-3 MB
    // Supabase uploads at source resolution — invisible on a
    // 40 dp circle but catastrophic when 100 of them scroll past on
    // the Ranks board and each holds ~2 MB of decoded pixels in the
    // ImageCache.
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final decodeSide = (radius * 2).round();
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
            backgroundImage: localImagePath != null
                ? FileImage(File(localImagePath!)) as ImageProvider
                : (imageUrl != null
                    ? appNetworkImageProvider(
                        imageUrl!,
                        maxSize: decodeSide,
                        devicePixelRatio: dpr,
                      )
                    : null),
            child: (localImagePath == null && imageUrl == null)
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
