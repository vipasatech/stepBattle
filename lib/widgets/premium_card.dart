import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../config/colors.dart';

/// Premium surface with a violet edge-glow field.
///
/// Composition:
///   1. **Base body** — theme surface with a subtle diagonal gradient
///      that eases from surface-color at the top to a slight violet
///      tint at the bottom. Reads as "the card is lit from below."
///   2. **Corner glow layers** — four radial gradients pinned at each
///      corner (Stack + Positioned). Each is a small violet halo that
///      bleeds inward and dies to transparent well before the middle;
///      the four together create the impression that the card is
///      floating in a soft accent field without any single glow
///      dominating.
///   3. **Perimeter accent border** — a hairline `Border` that carries
///      a violet tint (brighter than the plain hairline), giving the
///      card's edge a "just-lit" outline.
///   4. **Ambient drop shadow** — one physical shadow so the card
///      genuinely sits above the page.
///
/// Adapts to light AND dark:
///   • Dark → base is `surfaceContainerLow`, blends to violet-on-black.
///   • Light → base is white, blends to violet-on-white (softer alpha
///     so the accent doesn't look bruised on a pale bg).
///
/// Performance:
///   • All decoration is `BoxDecoration` (gradient + border + shadow)
///     and `Positioned` widgets — no `filter: blur()`, no
///     `BackdropFilter`. Safe inside scrollables.
///   • The 4 corner gradients are cached widgets — [_CornerGlow] is
///     const-compatible when consumers pass const colors.
///
/// Drop-in for GlassCard where you want the premium treatment. The
/// child receives the same padded content area; only the surrounding
/// chrome changes.
class PremiumCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  /// Intensity of the corner glow field. `standard` (default) suits
  /// most home surfaces; `strong` for the hero card that should catch
  /// the eye first. `soft` for secondary tiles.
  final PremiumCardIntensity intensity;

  const PremiumCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.borderRadius = 20,
    this.intensity = PremiumCardIntensity.standard,
  });

  @override
  Widget build(BuildContext context) {
    final isLight = AppColors.isLight;
    final radius = BorderRadius.circular(borderRadius);

    // Reference-inspired palette per the "Walking" + "Hydrate Hero"
    // cards the tester shared: deep, saturated violet body with a
    // diagonal gradient that darkens toward one corner, a very faint
    // dot-mesh texture for tactility, and a violet edge glow that
    // wraps the card. Intensity dial scales the mesh + shadow depth,
    // not the base violet (which we want consistent across surfaces
    // so the app feels of a piece).
    final scale = switch (intensity) {
      PremiumCardIntensity.soft => 0.7,
      PremiumCardIntensity.standard => 1.0,
      PremiumCardIntensity.strong => 1.35,
    };

    // Base gradient colours. Dark = deep purple → near-black. Light =
    // soft lavender → cool white. Both use the brand violet as the
    // "lit corner" and blend toward the theme's neutral so the card
    // still belongs to the surrounding page.
    final (Color topLeft, Color bottomRight) = isLight
        ? (
            Color.alphaBlend(
              AppColors.primary.withValues(alpha: 0.10),
              const Color(0xFFFAF7FF),
            ),
            const Color(0xFFFFFFFF),
          )
        : (
            const Color(0xFF1A0F2E),   // deep purple-black top-left
            const Color(0xFF08060C),   // near-black bottom-right
          );

    return Container(
      // Ambient shadow — physical elevation cue.
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isLight ? 0.06 : 0.4),
            blurRadius: 24 * scale,
            offset: const Offset(0, 10),
          ),
          BoxShadow(
            color: AppColors.primary.withValues(alpha: isLight ? 0.05 : 0.15),
            blurRadius: 40 * scale,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          children: [
            // Layer 1 — deep purple diagonal gradient body.
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [topLeft, bottomRight],
                  ),
                ),
              ),
            ),

            // Layer 2 — off-center violet accent halo bleeding from
            // one corner. Reads as a "lit from one side" impression
            // rather than the uniform-violet-fill of Layer 1.
            _CornerGlow(
              corner: Alignment.topLeft,
              color: AppColors.primary
                  .withValues(alpha: (isLight ? 0.10 : 0.28) * scale),
            ),
            _CornerGlow(
              corner: Alignment.bottomRight,
              color: AppColors.primary
                  .withValues(alpha: (isLight ? 0.06 : 0.14) * scale),
            ),

            // Layer 3 — faint dot mesh for tactile texture (matches
            // the reference "Hydrate Hero" card dot pattern). Only
            // visible on dark bg; disabled on light where it reads
            // as noise.
            if (!isLight)
              const Positioned.fill(
                child: IgnorePointer(child: _DotMesh()),
              ),

            // Layer 4 — perimeter violet accent border. Hairline
            // width so it reads as glow, not a hard outline.
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(
                      color: AppColors.primary
                          .withValues(alpha: isLight ? 0.18 : 0.32),
                      width: 1,
                    ),
                  ),
                ),
              ),
            ),

            // Content on top of every decoration layer.
            Padding(padding: padding, child: child),
          ],
        ),
      ),
    );
  }
}

/// Intensity dial for [PremiumCard]. Consumers pick per surface so a
/// hero card can carry a stronger glow than a secondary tile.
enum PremiumCardIntensity { soft, standard, strong }

/// Faint dot mesh overlay used inside dark-mode [PremiumCard]. Mimics
/// the tactile dot texture from the "Hydrate Hero" reference card the
/// tester shared — small, low-opacity white dots on a 20px grid.
///
/// CustomPainter draws directly; no image assets. Cheap because it
/// runs once per layout pass and the parent is inside a RepaintBoundary
/// via ClipRRect.
class _DotMesh extends StatelessWidget {
  const _DotMesh();

  @override
  Widget build(BuildContext context) {
    // CustomPaint with `size: Size.infinite` was propagating unbounded
    // paint-size requests up the tree — combined with the ancestor
    // Stack + Padding + RepaintBoundary chain, that showed up as
    // "hasSize was not true" during paint in Diagnostics. Wrapping
    // with an explicit SizedBox.expand pins the painter's canvas to
    // the Positioned.fill parent's actual measured size at layout,
    // not at paint.
    return SizedBox.expand(
      child: CustomPaint(painter: _DotMeshPainter()),
    );
  }
}

class _DotMeshPainter extends CustomPainter {
  static const double _spacing = 20.0;
  static const double _dotRadius = 0.9;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.06);
    // Vignette-fade: dots near the center are more visible than at
    // the edges, so the pattern reads as ambient depth rather than a
    // finite rectangular tile.
    final cx = size.width / 2;
    final cy = size.height / 2;
    final maxDist =
        math.sqrt(cx * cx + cy * cy);
    for (double y = 0; y < size.height; y += _spacing) {
      for (double x = 0; x < size.width; x += _spacing) {
        final dx = x - cx;
        final dy = y - cy;
        final dist = math.sqrt(dx * dx + dy * dy);
        // Fade to zero opacity at the corners.
        final t = 1.0 - (dist / maxDist).clamp(0.0, 1.0);
        if (t <= 0.05) continue;
        paint.color = Colors.white.withValues(alpha: 0.06 * t);
        canvas.drawCircle(Offset(x, y), _dotRadius, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotMeshPainter oldDelegate) => false;
}

/// One of the four corner glow layers. Pins itself to `corner` with
/// a fixed max reach (~55% of the shorter card dimension), painting a
/// violet radial that fades to zero well before the card centre. The
/// four layers combined produce a rimmed-in-light impression.
class _CornerGlow extends StatelessWidget {
  final Alignment corner;
  final Color color;

  const _CornerGlow({required this.corner, required this.color});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: corner,
              // 0.9 reach — the halo bleeds ~90% of the way across
              // the card. Keeps corner colour rich while still
              // dying out visibly before the opposite corner.
              radius: 0.9,
              colors: [color, Colors.transparent],
              stops: const [0.0, 0.6],
            ),
          ),
        ),
      ),
    );
  }
}
