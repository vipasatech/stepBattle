import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../config/colors.dart';

/// Centralized network image widget backed by [CachedNetworkImage].
///
/// Every user-facing remote image (avatars, run photos, thumbnails)
/// goes through this so the disk-cache policy lives in one place —
/// swapping caching strategies later is a one-file change.
///
/// One-shot render sites (share cards captured to PNG via
/// `RepaintBoundary`) intentionally still use `Image.network` because
/// they need the image frame to complete before capture; `CachedNetworkImage`
/// composes its frames through a builder pipeline that some capture
/// harnesses don't wait for.
class AppNetworkImage extends StatelessWidget {
  const AppNetworkImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.placeholderColor,
    this.showSpinner = true,
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// If set, wraps the image in a `ClipRRect` with these corners.
  final BorderRadius? borderRadius;

  /// Colour of the placeholder box while the image is loading. Defaults
  /// to `AppColors.surfaceContainerHigh`, which reads as a soft skeleton
  /// on both light and dark themes.
  final Color? placeholderColor;

  /// Whether to overlay a small spinner on the placeholder. Turn off
  /// for very small tiles (< 24 dp) where the spinner would dominate.
  final bool showSpinner;

  @override
  Widget build(BuildContext context) {
    final placeholderFill = placeholderColor ?? AppColors.surfaceContainerHigh;

    // Down-sample the decoded bitmap to the render size when we have
    // one. Supabase storage returns full-size avatar/photo uploads
    // (often 1–3 MB, 2000×2000+). Without this, an 18 dp avatar
    // circle allocated the full-resolution bitmap in memory — 100
    // avatars on the Ranks board could hold ~200 MB of decoded pixels
    // even though every one was rendered as a tiny disc.
    //
    // `devicePixelRatio` keeps things sharp on 3× phones. We cap at
    // 1024 as a safety net for pages that pass an unusually large
    // width (like a full-width hero) — beyond that we're back to
    // source-resolution and the point of the sizing is lost.
    final dpr = MediaQuery.of(context).devicePixelRatio;
    int? memCacheWidth;
    int? memCacheHeight;
    if (width != null && width!.isFinite) {
      memCacheWidth = (width! * dpr).round().clamp(1, 1024);
    }
    if (height != null && height!.isFinite) {
      memCacheHeight = (height! * dpr).round().clamp(1, 1024);
    }

    Widget image = CachedNetworkImage(
      imageUrl: url,
      width: width,
      height: height,
      fit: fit,
      memCacheWidth: memCacheWidth,
      memCacheHeight: memCacheHeight,
      fadeInDuration: const Duration(milliseconds: 120),
      placeholder: (_, __) => Container(
        color: placeholderFill,
        alignment: Alignment.center,
        child: showSpinner
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : null,
      ),
      errorWidget: (_, __, ___) => Container(
        color: placeholderFill,
        alignment: Alignment.center,
        child: Icon(
          Icons.broken_image_outlined,
          color: AppColors.onSurfaceVariant,
          size: (width != null && width! < 40) ? 16 : 24,
        ),
      ),
    );

    if (borderRadius != null) {
      image = ClipRRect(borderRadius: borderRadius!, child: image);
    }
    return image;
  }
}

/// [ImageProvider] variant for widgets like [CircleAvatar] that take a
/// provider (not a widget). Callers that know their render size —
/// typically the avatar/circle path — should pass [maxSize] so the
/// bitmap is decoded down to that logical size × devicePixelRatio.
/// Without this, a 40 dp circle avatar decoded a 2000×2000 Supabase
/// upload at source resolution; multiply by the ~100 rows on the
/// leaderboard board and the image cache alone was allocating
/// ~200 MB of decoded pixels for tiny circles.
///
/// [maxSize] is the largest of width or height in logical pixels
/// (both dimensions clamp together — square is the common case). It
/// is multiplied by [devicePixelRatio] internally so callers can
/// pass the plain widget size. Pass `null` to keep source resolution
/// (only sensible for share-card / full-viewport hero images).
ImageProvider appNetworkImageProvider(
  String url, {
  int? maxSize,
  double devicePixelRatio = 1.0,
}) {
  final base = CachedNetworkImageProvider(url);
  if (maxSize == null) return base;
  final side = (maxSize * devicePixelRatio).round().clamp(1, 1024);
  return ResizeImage(base, width: side, height: side);
}
