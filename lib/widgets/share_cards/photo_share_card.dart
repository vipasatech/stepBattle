import 'package:flutter/material.dart';

import '../../models/run_session_model.dart';
import '_card_shared.dart';
import 'share_card_size.dart';

/// Photo-style share card.
///
/// Full-bleed photo background + three transparent overlays — the
/// STEPBATTLE wordmark, the session title, and a 4-column stats row.
/// All three live at fractional anchor points (0..1) so their
/// positions scale between preview and the 1080×1920 export. The
/// sheet drives tap-to-select-then-drag and hands updated offsets back
/// to this widget on repaint; [selectedElement] tells the widget which
/// overlay should render its dashed selection border.
class PhotoShareCard extends StatelessWidget {
  final RunSession session;
  final String photoUrl;
  final ShareCardSize size;
  final Offset titleOffset;
  final Offset statsOffset;
  final Offset wordmarkOffset;
  final ShareCardElement? selectedElement;

  const PhotoShareCard({
    super.key,
    required this.session,
    required this.photoUrl,
    required this.size,
    required this.titleOffset,
    required this.statsOffset,
    required this.wordmarkOffset,
    this.selectedElement,
  });

  /// Default anchors for the three overlays. Layout is centered — the
  /// wordmark sits in the top-third of the card and the title / stats
  /// stack lives in the lower-third.
  static const Offset defaultTitleOffset = Offset(0.5, 0.66);
  static const Offset defaultStatsOffset = Offset(0.5, 0.80);
  static const Offset defaultWordmarkOffset = Offset(0.5, 0.14);

  /// Approximate hit-boxes (in card fractions) for each overlay — used
  /// by the sheet to test taps and to size the visual selection border.
  static const Size titleHitFraction = Size(0.78, 0.10);
  static const Size statsHitFraction = Size(0.92, 0.14);
  static const Size wordmarkHitFraction = Size(0.55, 0.07);

  @override
  Widget build(BuildContext context) {
    final scale = size.width / 1080;

    return Material(
      color: Colors.transparent,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ---- Photo background --------------------------------------
            Image.network(
              photoUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                color: const Color(0xFF1B1B1F),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.broken_image_outlined,
                  size: 80,
                  color: Colors.white24,
                ),
              ),
            ),

            // ---- Wordmark overlay (draggable) ------------------------
            PositionedOverlay(
              anchor: wordmarkOffset,
              cardSize: size.logicalSize,
              selected: selectedElement == ShareCardElement.wordmark,
              selectionColor: Colors.white.withValues(alpha: 0.7),
              hitFraction: wordmarkHitFraction,
              child: _shadowed(
                child: ShareCardPieces.wordmark(light: true, scale: scale),
              ),
            ),

            // ---- Title overlay (draggable) ----------------------------
            PositionedOverlay(
              anchor: titleOffset,
              cardSize: size.logicalSize,
              selected: selectedElement == ShareCardElement.title,
              selectionColor: Colors.white.withValues(alpha: 0.7),
              hitFraction: titleHitFraction,
              child: _titleBlock(scale),
            ),

            // ---- Stats overlay (draggable) ----------------------------
            PositionedOverlay(
              anchor: statsOffset,
              cardSize: size.logicalSize,
              selected: selectedElement == ShareCardElement.stats,
              selectionColor: Colors.white.withValues(alpha: 0.7),
              hitFraction: statsHitFraction,
              child: _statsBlock(scale),
            ),
          ],
        ),
      ),
    );
  }

  Widget _titleBlock(double scale) {
    return _shadowed(
      child: SizedBox(
        width: 900 * scale,
        child: Text(
          session.displayName,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white,
            fontFamily: 'Manrope',
            fontSize: 66 * scale,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.4,
            height: 1.05,
          ),
        ),
      ),
    );
  }

  Widget _statsBlock(double scale) {
    return _shadowed(
      child: SizedBox(
        width: 950 * scale,
        child: ShareCardPieces.statsRow(
          session: session,
          light: true,
          scale: scale,
        ),
      ),
    );
  }

  /// Wrap [child] in a DefaultTextStyle whose shadow keeps the text
  /// legible against any photo (light or dark). Cheaper than a whole
  /// background card and preserves the user's original photo aesthetic.
  Widget _shadowed({required Widget child}) {
    return DefaultTextStyle.merge(
      style: TextStyle(
        shadows: [
          Shadow(
            offset: const Offset(0, 2),
            blurRadius: 8,
            color: Colors.black.withValues(alpha: 0.75),
          ),
          Shadow(
            offset: const Offset(0, 0),
            blurRadius: 22,
            color: Colors.black.withValues(alpha: 0.55),
          ),
        ],
      ),
      child: child,
    );
  }
}
