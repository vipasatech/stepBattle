import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Time-of-day phase derived from local hour.
enum DayPhase { dawn, day, dusk, night }

DayPhase phaseFor(DateTime t) {
  final h = t.hour + t.minute / 60.0;
  if (h >= 5 && h < 7) return DayPhase.dawn;
  if (h >= 7 && h < 17.5) return DayPhase.day;
  if (h >= 17.5 && h < 20) return DayPhase.dusk;
  return DayPhase.night;
}

class SkyPalette {
  final Color top;
  final Color mid;
  final Color bottom;
  final Color mountainFar;
  final Color mountainNear;
  final Color hill;
  final Color ground;
  final Color pathLight;
  final Color pathDark;
  final bool showStars;
  final bool showSun;

  const SkyPalette({
    required this.top,
    required this.mid,
    required this.bottom,
    required this.mountainFar,
    required this.mountainNear,
    required this.hill,
    required this.ground,
    required this.pathLight,
    required this.pathDark,
    this.showStars = false,
    this.showSun = true,
  });

  static SkyPalette forPhase(DayPhase p) => switch (p) {
        DayPhase.dawn => const SkyPalette(
            top: Color(0xFF2C1B3C),
            mid: Color(0xFFE88873),
            bottom: Color(0xFFF6C78A),
            mountainFar: Color(0xFF4A3B5A),
            mountainNear: Color(0xFF33293F),
            hill: Color(0xFF2A3550),
            ground: Color(0xFF1E2540),
            pathLight: Color(0xFF57527A),
            pathDark: Color(0xFF2E2A47),
            showStars: false,
          ),
        DayPhase.day => const SkyPalette(
            top: Color(0xFF3B7CC4),
            mid: Color(0xFF6FA8D6),
            bottom: Color(0xFFB8D7EC),
            mountainFar: Color(0xFF425C86),
            mountainNear: Color(0xFF33486A),
            hill: Color(0xFF2F5A4F),
            ground: Color(0xFF2E4B3C),
            pathLight: Color(0xFF6B8060),
            pathDark: Color(0xFF3F5540),
            showStars: false,
          ),
        DayPhase.dusk => const SkyPalette(
            top: Color(0xFF2A1A4A),
            mid: Color(0xFFB55470),
            bottom: Color(0xFFE89968),
            mountainFar: Color(0xFF3A2C55),
            mountainNear: Color(0xFF26203F),
            hill: Color(0xFF232640),
            ground: Color(0xFF1A1D30),
            pathLight: Color(0xFF45476C),
            pathDark: Color(0xFF1F2136),
            showStars: false,
          ),
        DayPhase.night => const SkyPalette(
            top: Color(0xFF070A1E),
            mid: Color(0xFF111B3E),
            bottom: Color(0xFF1E2C52),
            mountainFar: Color(0xFF1A2240),
            mountainNear: Color(0xFF0F1530),
            hill: Color(0xFF111A2A),
            ground: Color(0xFF0A0E1C),
            pathLight: Color(0xFF2A3658),
            pathDark: Color(0xFF101528),
            showStars: true,
            showSun: false,
          ),
      };
}

// =============================================================================
// Skybox — fixed gradient backdrop with optional sun/stars.
// =============================================================================
class SkyboxPainter extends CustomPainter {
  final SkyPalette palette;
  final double time; // 0..1 continuous

  SkyboxPainter({required this.palette, required this.time});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..shader = ui.Gradient.linear(
        rect.topLeft,
        rect.bottomLeft,
        [palette.top, palette.mid, palette.bottom],
        const [0.0, 0.55, 1.0],
      );
    canvas.drawRect(rect, paint);

    if (palette.showStars) {
      final starPaint = Paint()..color = Colors.white.withValues(alpha: 0.8);
      final rng = math.Random(17);
      for (var i = 0; i < 70; i++) {
        final x = rng.nextDouble() * size.width;
        final y = rng.nextDouble() * size.height * 0.6;
        final twinkle =
            0.4 + 0.6 * (0.5 + 0.5 * math.sin(time * 2 * math.pi + i));
        starPaint.color = Colors.white.withValues(alpha: 0.2 + twinkle * 0.6);
        canvas.drawCircle(Offset(x, y), rng.nextDouble() * 1.4 + 0.4, starPaint);
      }

      // Moon
      final moon = Paint()..color = const Color(0xFFF5F2E1);
      canvas.drawCircle(
          Offset(size.width * 0.82, size.height * 0.18), 18, moon);
      canvas.drawCircle(
          Offset(size.width * 0.82, size.height * 0.18),
          28,
          Paint()
            ..color = const Color(0x33F5F2E1)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
    } else if (palette.showSun) {
      // Sun — soft glow
      final sunX = size.width * 0.78;
      final sunY = size.height * 0.22;
      canvas.drawCircle(
        Offset(sunX, sunY),
        60,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.18)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30),
      );
      canvas.drawCircle(
        Offset(sunX, sunY),
        22,
        Paint()..color = Colors.white.withValues(alpha: 0.85),
      );
    }
  }

  @override
  bool shouldRepaint(covariant SkyboxPainter oldDelegate) =>
      oldDelegate.palette != palette || oldDelegate.time != time;
}

// =============================================================================
// Drifting clouds — slow horizontal motion independent of camera.
// =============================================================================
class CloudsPainter extends CustomPainter {
  final double time; // continuous seconds
  final SkyPalette palette;

  CloudsPainter({required this.time, required this.palette});

  static const _cloudSeed = [
    _C(x: 0.05, y: 0.12, w: 120, h: 24, speed: 0.012),
    _C(x: 0.35, y: 0.20, w: 180, h: 36, speed: 0.008),
    _C(x: 0.70, y: 0.08, w: 90, h: 18, speed: 0.015),
    _C(x: 0.20, y: 0.28, w: 140, h: 28, speed: 0.010),
    _C(x: 0.88, y: 0.22, w: 110, h: 20, speed: 0.013),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final cloudColor = palette.showStars
        ? Colors.white.withValues(alpha: 0.12)
        : Colors.white.withValues(alpha: 0.78);
    final paint = Paint()
      ..color = cloudColor
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8);

    for (final c in _cloudSeed) {
      final travelled = (c.x + time * c.speed) % 1.2 - 0.1;
      final px = travelled * size.width;
      final py = c.y * size.height;
      _drawCloud(canvas, Offset(px, py), c.w, c.h, paint);
    }
  }

  void _drawCloud(Canvas canvas, Offset o, double w, double h, Paint p) {
    final path = Path();
    path.addOval(Rect.fromCenter(center: o, width: w, height: h));
    path.addOval(Rect.fromCenter(
        center: o.translate(-w * 0.25, -h * 0.1),
        width: w * 0.55,
        height: h * 0.9));
    path.addOval(Rect.fromCenter(
        center: o.translate(w * 0.28, -h * 0.15),
        width: w * 0.6,
        height: h));
    canvas.drawPath(path, p);
  }

  @override
  bool shouldRepaint(covariant CloudsPainter oldDelegate) =>
      oldDelegate.time != time || oldDelegate.palette != palette;
}

class _C {
  final double x;
  final double y;
  final double w;
  final double h;
  final double speed;
  const _C({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.speed,
  });
}

// =============================================================================
// Distant mountain silhouettes — slow parallax.
// =============================================================================
class MountainsPainter extends CustomPainter {
  final double cameraX;
  final double parallax;
  final SkyPalette palette;
  final int layer; // 0 = far, 1 = near

  MountainsPainter({
    required this.cameraX,
    required this.parallax,
    required this.palette,
    required this.layer,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final color = layer == 0 ? palette.mountainFar : palette.mountainNear;
    final paint = Paint()..color = color;

    // Peak positions repeat every "tile" in world coords.
    final offset = -cameraX * parallax;
    const tileW = 320.0;
    final peakBaselineY =
        size.height * (layer == 0 ? 0.58 : 0.66);
    final seed = layer == 0 ? 11 : 23;
    final rng = math.Random(seed);
    final peaks = List.generate(
      80,
      (i) {
        final h = 80.0 + rng.nextDouble() * (layer == 0 ? 80 : 120);
        final wobble = rng.nextDouble() * 0.4 + 0.8;
        return _Peak(x: i * tileW * 0.6, baseWidth: tileW * wobble, height: h);
      },
    );

    final path = Path();
    path.moveTo(-50, size.height);
    path.lineTo(-50, peakBaselineY);
    for (final p in peaks) {
      final px = p.x + offset;
      if (px > size.width + 100) break;
      if (px + p.baseWidth < -100) continue;
      path.lineTo(px, peakBaselineY);
      path.lineTo(px + p.baseWidth * 0.5, peakBaselineY - p.height);
      path.lineTo(px + p.baseWidth, peakBaselineY);
    }
    path.lineTo(size.width + 50, peakBaselineY);
    path.lineTo(size.width + 50, size.height);
    path.close();
    canvas.drawPath(path, paint);

    // Subtle highlight stroke along the ridge for the near layer
    if (layer == 1) {
      final highlight = Paint()
        ..color = Colors.white.withValues(alpha: 0.05)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      canvas.drawPath(path, highlight);
    }
  }

  @override
  bool shouldRepaint(covariant MountainsPainter oldDelegate) =>
      oldDelegate.cameraX != cameraX ||
      oldDelegate.parallax != parallax ||
      oldDelegate.palette != palette ||
      oldDelegate.layer != layer;
}

class _Peak {
  final double x;
  final double baseWidth;
  final double height;
  const _Peak(
      {required this.x, required this.baseWidth, required this.height});
}

// =============================================================================
// Rolling hills — mid parallax, with trees.
// =============================================================================
class HillsPainter extends CustomPainter {
  final double cameraX;
  final double parallax;
  final SkyPalette palette;

  HillsPainter({
    required this.cameraX,
    required this.parallax,
    required this.palette,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final offset = -cameraX * parallax;
    final baseline = size.height * 0.78;

    final fill = Paint()..color = palette.hill;
    final path = Path();
    path.moveTo(-50, size.height);
    path.lineTo(-50, baseline);

    const step = 48.0;
    final rng = math.Random(7);
    for (var i = -2; i < 300; i++) {
      final x1 = i * step + offset;
      final y = baseline - 20 - rng.nextDouble() * 14;
      path.quadraticBezierTo(
          x1 + step * 0.5, y - 10, x1 + step, baseline - rng.nextDouble() * 6);
      if (x1 + step > size.width + 100) break;
    }
    path.lineTo(size.width + 50, size.height);
    path.close();
    canvas.drawPath(path, fill);

    // Trees
    final treeColor = Color.lerp(palette.hill, Colors.black, 0.25)!;
    final treeTrunk = Color.lerp(palette.hill, Colors.black, 0.45)!;
    final rng2 = math.Random(19);
    for (var i = -2; i < 120; i++) {
      if (rng2.nextDouble() > 0.55) continue;
      final x = i * 80.0 + rng2.nextDouble() * 40 + offset;
      if (x < -30 || x > size.width + 30) continue;
      final treeH = 18.0 + rng2.nextDouble() * 12;
      canvas.drawRect(
        Rect.fromLTWH(x, baseline - treeH * 0.2, 2, treeH * 0.25),
        Paint()..color = treeTrunk,
      );
      canvas.drawCircle(
        Offset(x + 1, baseline - treeH * 0.5),
        treeH * 0.55,
        Paint()..color = treeColor,
      );
    }
  }

  @override
  bool shouldRepaint(covariant HillsPainter oldDelegate) =>
      oldDelegate.cameraX != cameraX ||
      oldDelegate.parallax != parallax ||
      oldDelegate.palette != palette;
}

// =============================================================================
// Track / ground foreground — runs at full parallax (1×).
// Dashed centerline + milestone markers.
// =============================================================================
class TrackPainter extends CustomPainter {
  final double cameraX;
  final SkyPalette palette;
  final double trackTop; // y of top edge of path in viewport
  final double trackHeight;

  TrackPainter({
    required this.cameraX,
    required this.palette,
    required this.trackTop,
    required this.trackHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final offset = -cameraX;

    // Ground plane below track top
    final groundRect =
        Rect.fromLTWH(0, trackTop, size.width, size.height - trackTop);
    final groundPaint = Paint()
      ..shader = ui.Gradient.linear(
        groundRect.topLeft,
        groundRect.bottomLeft,
        [palette.ground, Color.lerp(palette.ground, Colors.black, 0.4)!],
      );
    canvas.drawRect(groundRect, groundPaint);

    // Track surface — slightly lighter band
    final trackRect = Rect.fromLTWH(
        0, trackTop + trackHeight * 0.1, size.width, trackHeight);
    canvas.drawRect(
      trackRect,
      Paint()
        ..shader = ui.Gradient.linear(
          trackRect.topLeft,
          trackRect.bottomLeft,
          [palette.pathLight, palette.pathDark],
        ),
    );

    // Dashed centerline — repeats every 40 world px
    final lineY = trackRect.center.dy;
    final dashPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..strokeWidth = 3;
    const dashW = 18.0;
    const dashGap = 22.0;
    const period = dashW + dashGap;
    final firstDashWorldX = (cameraX ~/ period) * period.toDouble();
    for (var i = -1; i < size.width / period + 2; i++) {
      final worldX = firstDashWorldX + i * period;
      final x1 = worldX + offset;
      canvas.drawLine(
        Offset(x1, lineY),
        Offset(x1 + dashW, lineY),
        dashPaint,
      );
    }

    // Milestone markers — every 2000 world px, a stake with a banner.
    // These are pure decor; their world spacing doesn't map to steps.
    const milestoneSpacing = 800.0;
    final firstMilestone =
        ((cameraX - 200) ~/ milestoneSpacing).toDouble() * milestoneSpacing;
    for (var i = 0; i < size.width / milestoneSpacing + 3; i++) {
      final worldX = firstMilestone + i * milestoneSpacing;
      final x = worldX + offset;
      if (x < -40 || x > size.width + 40) continue;
      _drawMilestone(canvas, x, trackRect.top, trackHeight, i.isEven);
    }

    // Top edge highlight
    canvas.drawLine(
      Offset(0, trackTop),
      Offset(size.width, trackTop),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.08)
        ..strokeWidth = 1,
    );
  }

  void _drawMilestone(
      Canvas canvas, double x, double trackTopY, double th, bool left) {
    final stakeTop = trackTopY - 30;
    final stakeBottom = trackTopY + th * 0.1;

    final stakePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 2;
    canvas.drawLine(
        Offset(x, stakeTop), Offset(x, stakeBottom), stakePaint);

    // Flag triangle
    final flag = Path();
    final dir = left ? -1.0 : 1.0;
    flag.moveTo(x, stakeTop);
    flag.lineTo(x + 18 * dir, stakeTop + 6);
    flag.lineTo(x, stakeTop + 12);
    flag.close();
    canvas.drawPath(
      flag,
      Paint()..color = const Color(0xFF84ADFF).withValues(alpha: 0.7),
    );
  }

  @override
  bool shouldRepaint(covariant TrackPainter oldDelegate) =>
      oldDelegate.cameraX != cameraX ||
      oldDelegate.palette != palette ||
      oldDelegate.trackTop != trackTop ||
      oldDelegate.trackHeight != trackHeight;
}
