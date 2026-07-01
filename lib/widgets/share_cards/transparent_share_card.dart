import 'package:flutter/material.dart';

import '../../models/run_session_model.dart';
import '_card_shared.dart';
import '_route_polyline_painter.dart';
import 'share_card_size.dart';

/// Transparent-style share card.
///
/// Visual: transparent background (alpha 0 PNG) + a small "TRANSPARENT"
/// tag in the top-left (preview-only) + a horizontal 4-column stats
/// row (Distance / Time / Pace / Steps) that matches the Map + Photo
/// variants + a large route polyline below in brand violet +
/// STEPBATTLE wordmark centred at the bottom.
///
/// Designed for the Instagram Story sticker drag: the user pairs it
/// with their own background so text and route paint in white to read
/// against any photo.
class TransparentShareCard extends StatelessWidget {
  final RunSession session;
  final ShareCardSize size;

  /// When true, paint the "TRANSPARENT" label in the top-left. The
  /// sheet's PREVIEW passes true so the user has a visual reminder
  /// that this card is a sticker for overlaying. The PNG-export path
  /// passes false — the exported sticker should be pure stats +
  /// route + wordmark on an alpha-0 canvas, without the preview label
  /// baked in.
  final bool showLabel;

  const TransparentShareCard({
    super.key,
    required this.session,
    required this.size,
    this.showLabel = true,
  });

  @override
  Widget build(BuildContext context) {
    final scale = size.width / 1080;
    final isSquare = size == ShareCardSize.square;

    // Route polyline paints in brand violet so it matches the Map
    // variant and the app's primary throughout.
    final accent = const Color(0xFF7C3AED);

    return Material(
      color: Colors.transparent,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: Container(
          color: Colors.transparent,
          padding: EdgeInsets.fromLTRB(
            60 * scale,
            isSquare ? 60 * scale : 140 * scale,
            60 * scale,
            isSquare ? 60 * scale : 140 * scale,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Sticker-hint tag in the top-left — preview-only. The
              // `showLabel` flag lets the sheet render this in the
              // preview but strip it from the exported PNG.
              if (showLabel)
                Align(
                  alignment: Alignment.topLeft,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                        horizontal: 20 * scale, vertical: 8 * scale),
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: Colors.white, width: 2 * scale),
                      borderRadius: BorderRadius.circular(8 * scale),
                    ),
                    child: Text(
                      'TRANSPARENT',
                      style: TextStyle(
                        color: Colors.white,
                        fontFamily: 'Manrope',
                        fontSize: 22 * scale,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                )
              else
                SizedBox(height: 40 * scale),
              SizedBox(height: 50 * scale),

              // 4-column stats row (Distance / Time / Pace / Steps),
              // painted in white for legibility on any background. Uses
              // the same shared helper as the Map + Photo variants so
              // column widths are equal across all three views.
              ShareCardPieces.statsRow(
                session: session,
                light: true,
                scale: scale,
              ),

              // Route polyline — uses whatever vertical room is left,
              // so the path fills the middle of the card rather than
              // rendering as a thumbnail. Previously the fixed
              // SizedBox height was too small for tall/narrow paths.
              if (session.path.length >= 2)
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: 40 * scale),
                    child: CustomPaint(
                      painter: RoutePolylinePainter(
                        path: session.path,
                        color: accent,
                        strokeWidth: 12 * scale,
                        padding: EdgeInsets.all(16 * scale),
                      ),
                    ),
                  ),
                )
              else
                SizedBox(height: 100 * scale),

              // Wordmark bottom-centred.
              Align(
                alignment: Alignment.bottomCenter,
                child: ShareCardPieces.wordmark(light: true, scale: scale),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
