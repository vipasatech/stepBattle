import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../config/colors.dart';

/// Themed background for the Battle Status screen — the "swipe right"
/// alternative to a user-picked photo. Draws:
///
///   1. A vertical brand-violet gradient (deep purple at top, near-black
///      at the bottom).
///   2. A soft radial glow behind where the battle-result card sits.
///   3. Faint battleground silhouette suggested by a horizon line plus
///      a light peppering of small "runner" dots along the mid-band.
///
/// Pure CustomPaint — no image assets. That keeps the share PNG small
/// (~50 KB vs ~500 KB for a photo background) and means the look is
/// perfectly consistent across devices.
class ThemedBattleBackground extends StatelessWidget {
  /// Rough vertical position of the card the background is sitting
  /// under (0.0 = top of the canvas, 1.0 = bottom). Used to place the
  /// radial glow behind the card. Defaults to the vertical centre.
  final double cardCenterFraction;

  const ThemedBattleBackground({
    super.key,
    this.cardCenterFraction = 0.5,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: CustomPaint(
        painter: _ThemedBattleBackgroundPainter(
          cardCenterFraction: cardCenterFraction,
        ),
      ),
    );
  }
}

class _ThemedBattleBackgroundPainter extends CustomPainter {
  final double cardCenterFraction;
  _ThemedBattleBackgroundPainter({required this.cardCenterFraction});

  @override
  void paint(Canvas canvas, Size size) {
    _paintGradient(canvas, size);
    _paintGlow(canvas, size);
    _paintHorizon(canvas, size);
    _paintRunnerDots(canvas, size);
  }

  /// Vertical brand gradient — deep violet at the top, near-black at
  /// the bottom. Same palette as the deep-space slides in the
  /// Welcome carousel, minor variation on the exact stops so the
  /// two surfaces don't look identical.
  void _paintGradient(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color(0xFF3B0F8B), // brand violet, saturated
          Color(0xFF1B0940), // mid-violet
          Color(0xFF0A0518), // near-black
        ],
        stops: [0.0, 0.45, 1.0],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  /// Soft radial glow behind the card so the card's transparent
  /// contents catch a bit of "spotlight" and don't feel adrift.
  void _paintGlow(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * cardCenterFraction;
    final radius = size.shortestSide * 0.65;
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          AppColors.primary.withValues(alpha: 0.35),
          AppColors.primary.withValues(alpha: 0.0),
        ],
      ).createShader(
        Rect.fromCircle(center: Offset(cx, cy), radius: radius),
      );
    canvas.drawCircle(Offset(cx, cy), radius, paint);
  }

  /// Faint horizon line at ~72 % height — evokes a battlefield ridge
  /// without needing a bitmap silhouette. Thin, low-opacity, purple-
  /// tinted so it stays subtle.
  void _paintHorizon(Canvas canvas, Size size) {
    final y = size.height * 0.72;
    final paint = Paint()
      ..color = AppColors.primary.withValues(alpha: 0.35)
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);

    // A second, blurrier line just below for atmospheric depth.
    final softPaint = Paint()
      ..color = AppColors.primary.withValues(alpha: 0.12)
      ..strokeWidth = 6
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);
    canvas.drawLine(
      Offset(0, y + 3),
      Offset(size.width, y + 3),
      softPaint,
    );
  }

  /// A scattering of tiny bright dots along the horizon band — reads
  /// as distant runners lining up on the battle line. Positions are
  /// deterministic (seeded RNG) so the background doesn't shift
  /// between rebuilds.
  void _paintRunnerDots(Canvas canvas, Size size) {
    final rand = math.Random(42);
    final yBase = size.height * 0.72;
    final paint = Paint()..style = PaintingStyle.fill;
    // 12 dots spread across the width with small vertical jitter.
    for (var i = 0; i < 12; i++) {
      final x = (i + 0.5) * size.width / 12 +
          (rand.nextDouble() - 0.5) * (size.width / 20);
      final y = yBase + (rand.nextDouble() - 0.5) * 8;
      final r = 1.2 + rand.nextDouble() * 1.2;
      final alpha = 0.6 + rand.nextDouble() * 0.35;
      paint.color = Colors.white.withValues(alpha: alpha);
      canvas.drawCircle(Offset(x, y), r, paint);
    }
  }

  @override
  bool shouldRepaint(_ThemedBattleBackgroundPainter old) =>
      old.cardCenterFraction != cardCenterFraction;
}
