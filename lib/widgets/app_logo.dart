import 'package:flutter/material.dart';

/// Brand logo (`assets/logos/logo.png`) rendered as a rounded square so it
/// reads as an app icon regardless of the underlying image's aspect ratio.
///
/// Use [size] for both width and height; the corner radius is derived as a
/// fraction of [size] (iOS-style ~14%). Pass [boxFit] to override the default
/// `BoxFit.cover` if you need letterboxing.
class AppLogo extends StatelessWidget {
  final double size;
  final BoxFit boxFit;

  const AppLogo({
    super.key,
    required this.size,
    this.boxFit = BoxFit.cover,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.14),
      child: Image.asset(
        'assets/logos/logo.png',
        width: size,
        height: size,
        fit: boxFit,
      ),
    );
  }
}
