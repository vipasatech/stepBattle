import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../models/run_session_model.dart';
import '_card_shared.dart';
import 'share_card_size.dart';

/// Map-style share card.
///
/// Visual: real OSM tiles as the background (auto-fit around the
/// route's bounding box) + a violet polyline drawn on top by
/// `flutter_map`'s `PolylineLayer` + start / end markers + three
/// draggable text overlays (STEPBATTLE wordmark, session title,
/// 4-stat row).
///
/// Overlays match the Photo variant's interaction model — the sheet
/// drives tap-to-select-then-drag and passes updated offsets back in.
/// [selectedElement] tells the widget which overlay should render a
/// dashed selection border for user feedback.
class MapShareCard extends StatelessWidget {
  final RunSession session;
  final ShareCardSize size;
  final Offset titleOffset;
  final Offset statsOffset;
  final Offset wordmarkOffset;
  final ShareCardElement? selectedElement;

  const MapShareCard({
    super.key,
    required this.session,
    required this.size,
    required this.titleOffset,
    required this.statsOffset,
    required this.wordmarkOffset,
    this.selectedElement,
  });

  /// Default anchor points for the three overlays on the Map variant.
  /// Wordmark sits near the top; title + stats stack at bottom-left.
  static const Offset defaultTitleOffset = Offset(0.5, 0.78);
  static const Offset defaultStatsOffset = Offset(0.5, 0.90);
  static const Offset defaultWordmarkOffset = Offset(0.5, 0.09);

  /// Fractional hit-boxes — used by the sheet for tap-testing and by
  /// [PositionedOverlay] to size the visible selection border. The
  /// title box is slightly taller than the Photo variant's title
  /// because it contains the shoe icon above the text.
  static const Size titleHitFraction = Size(0.90, 0.14);
  static const Size statsHitFraction = Size(0.92, 0.14);
  static const Size wordmarkHitFraction = Size(0.60, 0.07);

  @override
  Widget build(BuildContext context) {
    final scale = size.width / 1080;
    final isSquare = size == ShareCardSize.square;
    // Brand violet — the app's primary. Matches the walk/session pill
    // and streak strip so the shared card reads as part of the same
    // visual identity.
    const routeAccent = Color(0xFF7C3AED);

    final latlngs = session.path
        .map((p) => LatLng(p.lat, p.lng))
        .toList(growable: false);

    // Fallback for a session with fewer than 2 GPS fixes — render the
    // polyline-free card so the layout still works. In practice the
    // Map variant is only offered when the session has a real path,
    // but this is defensive.
    final hasRoute = latlngs.length >= 2;

    return Material(
      color: Colors.transparent,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ---- Real OSM tile background ------------------------------
            if (hasRoute)
              FlutterMap(
                options: MapOptions(
                  initialCameraFit: CameraFit.bounds(
                    bounds: LatLngBounds.fromPoints(latlngs),
                    // Leave room at the bottom for the stats overlay so
                    // the polyline doesn't run into text.
                    padding: EdgeInsets.fromLTRB(
                      60 * scale,
                      140 * scale,
                      60 * scale,
                      isSquare ? 360 * scale : 500 * scale,
                    ),
                  ),
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.none,
                  ),
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.stepbattle.stepbattle',
                  ),
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: latlngs,
                        strokeWidth: 14 * scale,
                        color: routeAccent,
                        strokeCap: StrokeCap.round,
                        strokeJoin: StrokeJoin.round,
                      ),
                    ],
                  ),
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: latlngs.first,
                        width: 26 * scale,
                        height: 26 * scale,
                        child: const _RoutePin(color: Color(0xFF22C55E)),
                      ),
                      Marker(
                        point: latlngs.last,
                        width: 26 * scale,
                        height: 26 * scale,
                        child: const _RoutePin(color: Color(0xFFEF4444)),
                      ),
                    ],
                  ),
                ],
              )
            else
              Container(color: const Color(0xFFE9ECF1)),

            // ---- Bottom scrim so stats read on any tile mix -----------
            // Ambient — text still has its own shadows for legibility
            // when dragged elsewhere, but the bottom third is where
            // both defaults live so a scrim keeps the default look
            // clean.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: isSquare ? 360 * scale : 500 * scale,
              child: const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x00FFFFFF),
                      Color(0xF5FFFFFF),
                    ],
                  ),
                ),
              ),
            ),

            // ---- Wordmark overlay (draggable) -------------------------
            // Wrapped in a semi-transparent white pill so the brand tag
            // reads over busy tile backgrounds regardless of where the
            // user drags it.
            PositionedOverlay(
              anchor: wordmarkOffset,
              cardSize: size.logicalSize,
              selected: selectedElement == ShareCardElement.wordmark,
              selectionColor: const Color(0xFF7C3AED),
              hitFraction: wordmarkHitFraction,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 20 * scale,
                  vertical: 8 * scale,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.82),
                  borderRadius: BorderRadius.circular(24 * scale),
                ),
                child: ShareCardPieces.wordmark(
                  light: false,
                  scale: scale,
                ),
              ),
            ),

            // ---- Title overlay (draggable) ----------------------------
            // Shoe icon sits above the title inside the same box so
            // they drag as one unit — matches the original Map layout.
            PositionedOverlay(
              anchor: titleOffset,
              cardSize: size.logicalSize,
              selected: selectedElement == ShareCardElement.title,
              selectionColor: const Color(0xFF7C3AED),
              hitFraction: titleHitFraction,
              child: _shadowedDark(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    ShareCardPieces.shoeIcon(light: false, scale: scale),
                    SizedBox(height: 14 * scale),
                    ShareCardPieces.titleBlock(
                      session: session,
                      light: false,
                      scale: scale,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),

            // ---- Stats overlay (draggable) ----------------------------
            PositionedOverlay(
              anchor: statsOffset,
              cardSize: size.logicalSize,
              selected: selectedElement == ShareCardElement.stats,
              selectionColor: const Color(0xFF7C3AED),
              hitFraction: statsHitFraction,
              child: _shadowedDark(
                child: SizedBox(
                  width: 950 * scale,
                  child: ShareCardPieces.statsRow(
                    session: session,
                    light: false,
                    scale: scale,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Give dark text a white "glow" so it reads over dark tile patches
  /// (parks, water, forested areas). Matches the shadowing pattern the
  /// Photo variant uses for its light-on-dark case.
  Widget _shadowedDark({required Widget child}) {
    return DefaultTextStyle.merge(
      style: TextStyle(
        shadows: [
          Shadow(
            offset: const Offset(0, 0),
            blurRadius: 12,
            color: Colors.white.withValues(alpha: 0.9),
          ),
          Shadow(
            offset: const Offset(0, 0),
            blurRadius: 4,
            color: Colors.white.withValues(alpha: 0.9),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// Start / finish pin — filled circle with a white outer ring, matches
/// the pin used on the session detail's route map so users see the
/// same visual identity in the share card.
class _RoutePin extends StatelessWidget {
  final Color color;
  const _RoutePin({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 4,
            offset: Offset(0, 2),
          ),
        ],
      ),
    );
  }
}
