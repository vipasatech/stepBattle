import 'package:flutter/material.dart';

import '../../models/run_session_model.dart';

/// Paints a session's GPS path as a stylised polyline.
///
/// Used by:
///   • `MapShareCard` — the route over a stylised map-y backdrop.
///   • `TransparentShareCard` — the route alone, no background.
///
/// Coordinates are normalised to the path's bounding box and remapped
/// to fit inside [padding] of the canvas. We DO NOT render real map
/// tiles here — that's a Phase 2 concern; for v1 the route shape on a
/// gradient backdrop reads as a route well enough.
class RoutePolylinePainter extends CustomPainter {
  final List<RunPoint> path;
  final Color color;
  final double strokeWidth;
  final EdgeInsets padding;

  RoutePolylinePainter({
    required this.path,
    required this.color,
    this.strokeWidth = 6,
    this.padding = const EdgeInsets.all(24),
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (path.length < 2) return;

    // 1. Compute lat/lng bounding box.
    double minLat = path.first.lat, maxLat = path.first.lat;
    double minLng = path.first.lng, maxLng = path.first.lng;
    for (final p in path.skip(1)) {
      if (p.lat < minLat) minLat = p.lat;
      if (p.lat > maxLat) maxLat = p.lat;
      if (p.lng < minLng) minLng = p.lng;
      if (p.lng > maxLng) maxLng = p.lng;
    }
    final latSpan = (maxLat - minLat).abs();
    final lngSpan = (maxLng - minLng).abs();
    // Degenerate paths (e.g. all points on one stretched line) get a
    // tiny epsilon so we don't divide by zero.
    final safeLatSpan = latSpan < 1e-9 ? 1e-9 : latSpan;
    final safeLngSpan = lngSpan < 1e-9 ? 1e-9 : lngSpan;

    // 2. Fit the bounding box inside the canvas with `padding` margins,
    //    preserving the aspect ratio (otherwise the route would be
    //    visibly stretched on portrait canvases).
    final drawW = size.width - padding.horizontal;
    final drawH = size.height - padding.vertical;
    final boxAspect = safeLngSpan / safeLatSpan;
    final canvasAspect = drawW / drawH;
    double mapW, mapH;
    if (boxAspect > canvasAspect) {
      mapW = drawW;
      mapH = drawW / boxAspect;
    } else {
      mapH = drawH;
      mapW = drawH * boxAspect;
    }
    final offsetX = padding.left + (drawW - mapW) / 2;
    final offsetY = padding.top + (drawH - mapH) / 2;

    Offset project(RunPoint p) {
      final x = offsetX + ((p.lng - minLng) / safeLngSpan) * mapW;
      // Latitudes north of equator increase upward; canvas Y increases
      // downward — flip so the route reads the same orientation as on
      // a real map.
      final y = offsetY + (1 - (p.lat - minLat) / safeLatSpan) * mapH;
      return Offset(x, y);
    }

    final pathPath = Path()..moveTo(project(path.first).dx, project(path.first).dy);
    for (final p in path.skip(1)) {
      final off = project(p);
      pathPath.lineTo(off.dx, off.dy);
    }

    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    canvas.drawPath(pathPath, paint);
  }

  @override
  bool shouldRepaint(covariant RoutePolylinePainter oldDelegate) =>
      oldDelegate.path != path ||
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.padding != padding;
}
