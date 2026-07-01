import 'package:flutter/material.dart';

import '../../models/run_session_model.dart';

/// Which overlay element the sheet has currently selected. Both the
/// Map and Photo variants surface `title`, `stats`, and `wordmark` as
/// separately-draggable boxes; the sheet tracks one at a time.
enum ShareCardElement { title, stats, wordmark }

/// Shared rendering pieces used by all three share-card variants
/// (`MapShareCard`, `PhotoShareCard`, `TransparentShareCard`). Pulled
/// into one file so the visual identity — title + 3-stat stack + the
/// "STEPBATTLE" wordmark watermark — is bumped in one place.
class ShareCardPieces {
  ShareCardPieces._();

  /// Format distance metres → "3.81 km" (or "812 m" under 1 km).
  static String formatDistance(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    final km = meters / 1000.0;
    return '${km.toStringAsFixed(km < 10 ? 2 : 1)} km';
  }

  /// Format pace seconds/km → "7:27 /km". Null / NaN → "--".
  /// Every current share-card caller wants the "/km" unit shown so
  /// it's baked into the helper — matches how apps like Strava
  /// display the value on their share cards.
  static String formatPace(double? secPerKm) {
    if (secPerKm == null || secPerKm.isNaN || !secPerKm.isFinite) return '--';
    final m = secPerKm ~/ 60;
    final s = (secPerKm % 60).round();
    return '$m:${s.toString().padLeft(2, '0')} /km';
  }

  /// Format seconds → "28m 21s" / "1h 12m".
  static String formatDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m}m ${s}s';
  }

  /// Title-only block — session name in the bold headline style.
  /// Text alignment / max width are the caller's problem so this fits
  /// inside a draggable [PositionedOverlay] on any variant.
  static Widget titleBlock({
    required RunSession session,
    required bool light,
    required double scale,
    TextAlign textAlign = TextAlign.center,
  }) {
    final fg = light ? Colors.white : const Color(0xFF1B1B1F);
    return Text(
      session.displayName,
      textAlign: textAlign,
      style: TextStyle(
        color: fg,
        fontFamily: 'Manrope',
        fontSize: 66 * scale,
        fontWeight: FontWeight.w900,
        height: 1.05,
        letterSpacing: -0.4,
      ),
    );
  }

  /// 4-column stats row (Distance / Time / Pace / Steps). Renders as
  /// its own draggable box on the Map / Photo variants.
  static Widget statsRow({
    required RunSession session,
    required bool light,
    required double scale,
  }) {
    final fg = light ? Colors.white : const Color(0xFF1B1B1F);
    final dim = light
        ? Colors.white.withValues(alpha: 0.8)
        : const Color(0xFF49464E);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _stat(
            label: 'Distance',
            value: formatDistance(session.distanceMeters),
            fg: fg,
            dim: dim,
            scale: scale,
          ),
        ),
        Expanded(
          child: _stat(
            label: 'Time',
            value: formatDuration(session.durationSeconds),
            fg: fg,
            dim: dim,
            scale: scale,
          ),
        ),
        Expanded(
          child: _stat(
            label: 'Pace',
            value: formatPace(session.avgPaceSecPerKm),
            fg: fg,
            dim: dim,
            scale: scale,
          ),
        ),
        Expanded(
          child: _stat(
            label: 'Steps',
            value: '${session.steps}',
            fg: fg,
            dim: dim,
            scale: scale,
          ),
        ),
      ],
    );
  }

  static Widget _stat({
    required String label,
    required String value,
    required Color fg,
    required Color dim,
    required double scale,
  }) {
    // Center-aligned label + value inside an equal-width column. The
    // Row wrapping this widget uses Expanded for each column, so widths
    // are already equal; centering the content per column then makes
    // the space BETWEEN adjacent columns visually equal too, no matter
    // what value strings the caller passes.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: dim,
            fontFamily: 'Manrope',
            fontSize: 26 * scale,
            fontWeight: FontWeight.w700,
          ),
        ),
        SizedBox(height: 6 * scale),
        Text(
          value,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: fg,
            fontFamily: 'Manrope',
            fontSize: 52 * scale,
            fontWeight: FontWeight.w900,
            height: 1.0,
            letterSpacing: -0.2,
          ),
        ),
      ],
    );
  }

  /// "STEPBATTLE" wordmark — styled mono-spaced italic so it reads as a
  /// watermark, not a paragraph. `light` mirrors the title/stats so the
  /// brand contrasts against whatever background it's painted over.
  static Widget wordmark({required bool light, required double scale}) {
    final fg = light ? Colors.white : const Color(0xFF1B1B1F);
    return Text(
      'STEPBATTLE',
      style: TextStyle(
        color: fg,
        fontFamily: 'Manrope',
        fontStyle: FontStyle.italic,
        fontWeight: FontWeight.w900,
        fontSize: 38 * scale,
        letterSpacing: 2.4,
        height: 1.0,
      ),
    );
  }

  /// Small shoe-icon glyph used in the Map / Photo bottom-left cluster.
  /// Sized via [scale] so it matches the title above it.
  static Widget shoeIcon({required bool light, required double scale}) {
    final fg = light ? Colors.white : const Color(0xFF1B1B1F);
    return Icon(
      Icons.directions_run,
      color: fg,
      size: 68 * scale,
    );
  }
}

/// Anchors [child] at a fractional [anchor] point on the card, sized to
/// [hitFraction] (also fractional). Draws a dashed white border when
/// [selected]. Used by all card variants for their draggable overlays —
/// the sheet drives selection + drag; the widget only paints.
class PositionedOverlay extends StatelessWidget {
  /// Fractional anchor point on the card (0..1 in each axis) at which
  /// the overlay's CENTRE is placed.
  final Offset anchor;

  /// Logical size of the card the overlay lives on (e.g. 1080×1920).
  final Size cardSize;

  /// Show a dashed white border around the hit region.
  final bool selected;
  final Color selectionColor;

  /// Size of the visible / tappable box, expressed as fractions of the
  /// card (so it scales with the card at export time).
  final Size hitFraction;

  final Widget child;

  const PositionedOverlay({
    super.key,
    required this.anchor,
    required this.cardSize,
    required this.selected,
    required this.selectionColor,
    required this.hitFraction,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final hitW = hitFraction.width * cardSize.width;
    final hitH = hitFraction.height * cardSize.height;
    return Positioned(
      left: anchor.dx * cardSize.width - hitW / 2,
      top: anchor.dy * cardSize.height - hitH / 2,
      width: hitW,
      height: hitH,
      child: DecoratedBox(
        decoration: selected
            ? BoxDecoration(
                border: Border.all(
                  color: selectionColor,
                  width: 3,
                ),
                borderRadius: BorderRadius.circular(14),
              )
            : const BoxDecoration(),
        child: Center(child: child),
      ),
    );
  }
}
