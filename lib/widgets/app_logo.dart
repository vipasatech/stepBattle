import 'package:flutter/material.dart';

/// Brand logo rendered at the requested [size].
///
/// Two shapes:
///   • Default (`circular: false`): `assets/logos/logo.png` clipped with a
///     ~14% iOS-style rounded square. Used wherever the logo sits inside
///     other rounded chrome.
///   • `circular: true`: `assets/logos/logo_square.png` clipped with
///     [ClipOval] — same render the Flutter splash uses. Use this on
///     places like the Home AppBar where the logo is the only branding
///     element and a circular crop reads more app-icon-like.
class AppLogo extends StatelessWidget {
  final double size;
  final BoxFit boxFit;
  final bool circular;

  const AppLogo({
    super.key,
    required this.size,
    this.boxFit = BoxFit.cover,
    this.circular = false,
  });

  @override
  Widget build(BuildContext context) {
    if (circular) {
      return ClipOval(
        child: Image.asset(
          'assets/logos/logo_square.png',
          width: size,
          height: size,
          fit: boxFit,
        ),
      );
    }
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
