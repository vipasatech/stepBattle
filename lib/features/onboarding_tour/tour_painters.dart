import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Paints a dim overlay with a crisp cutout at the target rect.
/// Full-screen `Positioned.fill` widget host expected.
///
/// **Visual grammar (v5 — 2026-09-04, third user-feedback pass):**
/// classic spotlight pattern — heavier dim on everything except the
/// target rect. The target stays completely untouched (original
/// colours + brightness); the surrounding page fades back. The
/// contrast between crisp target and dimmed surround IS the "popped
/// up" effect — no glow, no ring, no artificial halo.
///
///   • Ground: solid black at `dimOpacity` (default 0.55) — heavy
///     enough that surrounding widgets recede visibly but you can
///     still tell WHERE the target is on the page.
///   • Cutout: rounded rectangle hugging the target's own bounds
///     (+ 12 dp padding, 16 dp corner radius), with a 20 dp gradient
///     falloff so the transition to dim is bloomed, not stamped.
///   • Glow: OFF by default (`glowOpacity: 0`). The white glow used
///     in v3/v4 bled into surrounding content and read as messy;
///     kept as a knob so future tuning is one param away.
class SpotlightPainter extends CustomPainter {
  /// Screen-space rect of the target widget. If null, the painter
  /// falls back to painting the full-screen dim without any hole —
  /// used briefly during the frame the tour switches steps and the
  /// new target hasn't measured yet.
  final Rect? targetRect;

  /// How much padding to add around the target rect before drawing
  /// the spotlight. Larger = more airy, smaller = tighter reveal.
  final double padding;

  /// Soft falloff distance beyond [padding]. This is where the
  /// spotlight fades from full-transparent to full-dim.
  final double featherRadius;

  /// Opacity of the surrounding dim.
  final double dimOpacity;

  const SpotlightPainter({
    required this.targetRect,
    this.padding = 12,
    this.featherRadius = 20,
    // v5 default: heavy dim + crisp cutout = target pops purely by
    // contrast. Sheet double-dim was fixed separately (sheets now
    // pass barrierColor: transparent), so 0.55 doesn't stack.
    this.dimOpacity = 0.55,
    this.cornerRadius = 16,
    // Glow OFF by default — the additive halo bled into neighbour
    // widgets and looked messy. Kept as a param for future tuning.
    this.glowColor = const Color(0xFFFFFFFF),
    this.glowRadius = 48,
    this.glowOpacity = 0.0,
  });

  /// Radius of the rounded rectangle around the target. Matches the
  /// natural card radius most of the highlighted widgets already use.
  final double cornerRadius;

  /// Color of the outward glow drawn around the target. Defaults to
  /// the app's primary purple so the highlight reads as brand-native.
  final Color glowColor;

  /// How far the glow extends beyond the target's own bounds.
  final double glowRadius;

  /// Peak opacity of the glow (at the target edge; falls to 0 at the
  /// full glow radius).
  final double glowOpacity;

  @override
  void paint(Canvas canvas, Size size) {
    final dimColor = Colors.black.withValues(alpha: dimOpacity);
    final full = Rect.fromLTWH(0, 0, size.width, size.height);

    // No target yet — paint whatever dim was requested (probably 0.18
    // or 0 in v3) so the tour still has SOME veil during the first
    // frame while target is measuring.
    if (targetRect == null) {
      if (dimOpacity > 0) canvas.drawRect(full, Paint()..color = dimColor);
      return;
    }

    final rect = targetRect!;
    final spotRect = rect.inflate(padding);
    final spotCenter = spotRect.center;

    // (1) Very light dim over the whole screen + punch-out at the
    // target so its pixels stay pristine. Skipped when dimOpacity=0.
    if (dimOpacity > 0) {
      canvas.saveLayer(full, Paint());
      canvas.drawRect(full, Paint()..color = dimColor);
      final rrect = RRect.fromRectAndRadius(
        spotRect,
        Radius.circular(cornerRadius),
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = Colors.white
          ..blendMode = BlendMode.dstOut,
      );
      // OPTIONAL soft feather around the punch. Off by default
      // (featherRadius: 0) because the radial gradient bleeds
      // outward in a CIRCLE that extends far beyond the target's
      // rectangular corners — it lit up neighbour widgets and read
      // as an oval halo. User asked for a hard-edged band exactly
      // around the target (plant-app "Reminders" style). Kept as
      // a knob so a soft edge is one param away if wanted later.
      if (featherRadius > 0) {
        final halfDiag = math.sqrt(spotRect.width * spotRect.width +
                spotRect.height * spotRect.height) /
            2;
        final maxRadius = halfDiag + featherRadius;
        final featherShader = ui.Gradient.radial(
          spotCenter,
          maxRadius,
          [
            Colors.white,
            Colors.white,
            Colors.white.withValues(alpha: 0),
          ],
          [0.0, halfDiag / maxRadius, 1.0],
        );
        canvas.drawRect(
          full,
          Paint()
            ..shader = featherShader
            ..blendMode = BlendMode.dstOut,
        );
      }
      canvas.restore();
    }

    // (2) Optional additive glow around the target. Off by default
    // (v5 removed it — it bled into neighbour widgets and looked
    // messy). Kept as a runtime knob so future designs can bring it
    // back with a single param change.
    if (glowOpacity > 0) {
      final glowHalfDiag = math.sqrt(
              spotRect.width * spotRect.width + spotRect.height * spotRect.height) /
          2;
      final glowOuterRadius = glowHalfDiag + glowRadius;
      final glowShader = ui.Gradient.radial(
        spotCenter,
        glowOuterRadius,
        [
          glowColor.withValues(alpha: 0),
          glowColor.withValues(alpha: 0),
          glowColor.withValues(alpha: glowOpacity),
          glowColor.withValues(alpha: 0),
        ],
        [
          0.0,
          (glowHalfDiag - 4) / glowOuterRadius,
          glowHalfDiag / glowOuterRadius,
          1.0,
        ],
      );
      canvas.drawRect(
        full,
        Paint()
          ..shader = glowShader
          ..blendMode = BlendMode.plus,
      );
    }
  }

  @override
  bool shouldRepaint(covariant SpotlightPainter oldDelegate) =>
      oldDelegate.targetRect != targetRect ||
      oldDelegate.padding != padding ||
      oldDelegate.featherRadius != featherRadius ||
      oldDelegate.dimOpacity != dimOpacity ||
      oldDelegate.cornerRadius != cornerRadius ||
      oldDelegate.glowColor != glowColor ||
      oldDelegate.glowRadius != glowRadius ||
      oldDelegate.glowOpacity != glowOpacity;
}

/// Clips a widget's paint area to "everything EXCEPT the target
/// rectangle" — used with [BackdropFilter] so the underlying screen
/// gets blurred outside the target, and stays crisp inside it.
///
/// **Why not just paint blur into a shader mask:** BackdropFilter is
/// the only widget that can blur what's ALREADY on the screen behind
/// it (as opposed to blurring its own children). To exclude the
/// target region from that blur we clip the filter's draw area
/// through this clipper — the un-clipped hole receives no blur pass
/// and shows the underlying pixel as-is.
///
/// Uses even-odd fill rule: the outer full-screen rect + inner
/// rounded target rect combine into a "donut" shape whose interior
/// is the clip area.
class InverseRectClipper extends CustomClipper<Path> {
  final Rect? targetRect;
  final double padding;
  final double cornerRadius;

  const InverseRectClipper({
    required this.targetRect,
    this.padding = 12,
    this.cornerRadius = 16,
  });

  @override
  Path getClip(Size size) {
    final full = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final rect = targetRect;
    if (rect == null) return full;
    final hole = Path()
      ..addRRect(RRect.fromRectAndRadius(
        rect.inflate(padding),
        Radius.circular(cornerRadius),
      ));
    // Even-odd: full ∆ hole = donut shape (everything except the hole).
    return Path.combine(PathOperation.difference, full, hole);
  }

  @override
  bool shouldReclip(covariant InverseRectClipper oldClipper) =>
      oldClipper.targetRect != targetRect ||
      oldClipper.padding != padding ||
      oldClipper.cornerRadius != cornerRadius;
}

/// Draws a curved hand-drawn arrow from the tooltip text down (or up)
/// to the spotlighted target. Bezier with 2 control points — the
/// gentle S-curve reads as hand-drawn while staying deterministic.
class TourArrowPainter extends CustomPainter {
  /// Where the arrow STARTS — usually the anchor of the tooltip's
  /// last text baseline, in the same coordinate space as [end].
  final Offset start;

  /// Where the arrow tip lands — usually the near edge of the
  /// spotlight ring, in the same coordinate space as [start].
  final Offset end;

  /// True when the arrow curves DOWN from tooltip-above to spotlight-
  /// below (reference screens 1, 3, 4 — the "down to nav" arrow).
  /// False when the arrow curves UP from tooltip-below to spotlight-
  /// above.
  final bool curveDown;

  final Color color;
  final double strokeWidth;

  const TourArrowPainter({
    required this.start,
    required this.end,
    required this.curveDown,
    this.color = Colors.white,
    // Bumped 2.0 → 2.4 (2026-09-04 feedback: head + curve were too
    // thin to read against a dim ground; user reported the left leg
    // looked "cut" because the stroke was too fine to survive
    // anti-aliasing at the curve's inflection).
    this.strokeWidth = 2.4,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.90)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Cubic Bezier — two control points shifted horizontally to give
    // the arrow its gentle sweep. The horizontal drift (`sweep`)
    // scales with vertical distance so long arrows curve more than
    // short ones. Direction reference from the design's screens 1 & 4.
    final dy = end.dy - start.dy;
    final sweep = (dy.abs() * 0.28).clamp(20.0, 90.0);
    // On downward arrows the sweep goes RIGHT-then-back, on upward
    // arrows it goes LEFT-then-back — matches the reference's
    // opposite-directional curls between screens 1 (down-arrow curls
    // right) and 4 (up-arrow curls left). Mirror based on curveDown.
    final side = curveDown ? 1 : -1;
    final c1 = Offset(start.dx + sweep * side, start.dy + dy * 0.35);
    final c2 = Offset(end.dx - sweep * side, start.dy + dy * 0.75);

    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, end.dx, end.dy);
    canvas.drawPath(path, paint);

    // Arrowhead — reverted to stroked V (2026-09-04 user feedback:
    // "the arrow which is previous only good, just tilt the head of
    // arrow a bit of previous and use it"). Two lines meeting at
    // the tip, drawn with the same paint as the curve for continuity.
    // The head tilts naturally with the curve's exit tangent (from
    // c2 → end), and a small extra ±rotation makes it feel more
    // hand-drawn rather than perfectly axis-aligned.
    final tangent = (end - c2);
    final tangentLen = tangent.distance == 0 ? 1 : tangent.distance;
    final baseUx = tangent.dx / tangentLen;
    final baseUy = tangent.dy / tangentLen;
    // Tiny rotation added to the tangent — 8° right — so the head
    // reads as gently tilted rather than dead-on-perpendicular.
    const tiltRad = 8 * 3.14159265 / 180;
    final cosT = math.cos(tiltRad);
    final sinT = math.sin(tiltRad);
    final ux = baseUx * cosT - baseUy * sinT;
    final uy = baseUx * sinT + baseUy * cosT;
    const headLen = 12.0;
    const headHalfWidth = 6.0;
    final legA = Offset(
      end.dx - ux * headLen - uy * headHalfWidth,
      end.dy - uy * headLen + ux * headHalfWidth,
    );
    final legB = Offset(
      end.dx - ux * headLen + uy * headHalfWidth,
      end.dy - uy * headLen - ux * headHalfWidth,
    );
    final headPath = Path()
      ..moveTo(legA.dx, legA.dy)
      ..lineTo(end.dx, end.dy)
      ..lineTo(legB.dx, legB.dy);
    canvas.drawPath(headPath, paint);
  }

  @override
  bool shouldRepaint(covariant TourArrowPainter oldDelegate) =>
      oldDelegate.start != start ||
      oldDelegate.end != end ||
      oldDelegate.curveDown != curveDown ||
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth;
}
