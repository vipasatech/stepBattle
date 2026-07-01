import 'dart:ui';

import 'battleground_tile.dart';

/// The visible path through the battleground tile.
///
/// Coordinates are **normalized to the tile's pixel dimensions** — both axes
/// run 0..1, where (0, 0) is the top-left of the tile image and (1, 1) is
/// the bottom-right. Callers multiply by their on-screen tile size to get
/// pixel positions.
///
/// Two packs ship with the app — see [ArenaPack]:
///
///   • [ArenaPack.forest] uses [_forestWaypoints] — traced top→bottom from
///     `morningVersion.png` in a 1:2 portrait tile. The first and last
///     waypoints share the same `dx` so stacked copies of the tile form a
///     seamless continuous path.
///
///   • [ArenaPack.city] uses [_cityWaypoints] — traced left→right from
///     `morningVersion.webp` in a 2:1 landscape tile. The runner enters the
///     left edge through the café district, curves around the central
///     fountain plaza, then exits the right edge through the park-with-pond.
///     We do NOT tile this pack horizontally; the path is long enough that
///     one tile gives a generous "leader / trailer" spread already.
///
/// Interpolation uses a Catmull-Rom spline so an avatar moving along it
/// follows smooth curves rather than zig-zagging straight between
/// waypoints. We treat the endpoints as if mirrored across themselves
/// (clamping) — equivalent to standard "non-uniform Catmull-Rom with
/// duplicated endpoint control points".
class BattlegroundPath {
  BattlegroundPath._();

  /// Forest tile, top → bottom (portrait, 1:2). See file-level docs.
  static const List<Offset> _forestWaypoints = [
    Offset(0.52, 0.00), //  0: enters top, just right of center
    Offset(0.45, 0.08), //  1: curves left
    Offset(0.43, 0.15), //  2: deeper left bend (past first ruin)
    Offset(0.50, 0.22), //  3: swings back to center
    Offset(0.57, 0.28), //  4: right bend
    Offset(0.52, 0.36), //  5: straightens
    Offset(0.43, 0.42), //  6: left bend (past wooden totem)
    Offset(0.48, 0.50), //  7: mid-tile, near center
    Offset(0.56, 0.56), //  8: right bend
    Offset(0.52, 0.64), //  9: straightens
    Offset(0.43, 0.70), // 10: left bend (past second ruin)
    Offset(0.50, 0.78), // 11: back to center
    Offset(0.55, 0.84), // 12: gentle right
    Offset(0.51, 0.92), // 13: centering
    Offset(0.52, 1.00), // 14: exits bottom (= entry point of next tile)
  ];

  /// City tile, left → right (landscape, 2:1). Visually traced from
  /// `morningVersion.webp`; minor wobble is expected — refine in place if
  /// the avatar visibly drifts off the cream-stone trail.
  static const List<Offset> _cityWaypoints = [
    Offset(0.00, 0.30), //  0: enters left edge near café district
    Offset(0.06, 0.27), //  1: rises slightly past awning row
    Offset(0.13, 0.31), //  2: dips toward the bell tower
    Offset(0.21, 0.39), //  3: descends past tower into market
    Offset(0.28, 0.46), //  4: through market stalls
    Offset(0.35, 0.43), //  5: rises away from tents
    Offset(0.42, 0.39), //  6: approaching fountain plaza
    Offset(0.50, 0.45), //  7: passing the fountain on the south side
    Offset(0.58, 0.48), //  8: past the fountain, swings right
    Offset(0.65, 0.50), //  9: into the right-side plaza
    Offset(0.73, 0.55), // 10: bends down toward the park
    Offset(0.81, 0.62), // 11: enters the park
    Offset(0.88, 0.65), // 12: past the lily pond
    Offset(0.94, 0.66), // 13: hugging the park edge
    Offset(1.00, 0.65), // 14: exits right edge
  ];

  static List<Offset> _waypointsFor(ArenaPack pack) =>
      pack == ArenaPack.city ? _cityWaypoints : _forestWaypoints;

  /// Returns the normalized position along the path at fractional progress
  /// `t` ∈ [0, 1]. For the forest pack, `t = 0` is the top entry and
  /// `t = 1` is the bottom exit; for city, `t = 0` is the left entry and
  /// `t = 1` is the right exit.
  ///
  /// Out-of-range values are clamped — pass progress past 1.0 to keep the
  /// avatar at the exit point rather than overshooting.
  static Offset positionAt(double t, {ArenaPack pack = ArenaPack.forest}) {
    final waypoints = _waypointsFor(pack);
    if (t <= 0) return waypoints.first;
    if (t >= 1) return waypoints.last;

    // Map `t` onto the waypoint list. We treat the list as a uniformly-
    // spaced polyline (each segment carries 1/(N-1) of total progress);
    // that's a small lie because real arc-length between waypoints varies,
    // but for ~15 points laid out roughly evenly along the tile it's
    // imperceptible. If we ever need uniform velocity we'd pre-compute
    // cumulative arc length and binary-search by `t`.
    final segments = waypoints.length - 1;
    final scaled = t * segments;
    final i = scaled.floor().clamp(0, segments - 1);
    final localT = scaled - i;

    return _catmullRom(
      _pointOrClamp(waypoints, i - 1),
      _pointOrClamp(waypoints, i),
      _pointOrClamp(waypoints, i + 1),
      _pointOrClamp(waypoints, i + 2),
      localT,
    );
  }

  /// Convenience: position scaled to a concrete tile size in pixels.
  /// `tileSize.width` × `dx` and `tileSize.height` × `dy`.
  static Offset positionInTile(
    double t,
    Size tileSize, {
    ArenaPack pack = ArenaPack.forest,
  }) {
    final n = positionAt(t, pack: pack);
    return Offset(n.dx * tileSize.width, n.dy * tileSize.height);
  }

  /// Tangent direction (unit-ish) at progress `t`. Used to rotate the
  /// avatar so they face the direction of travel along the curve.
  ///
  /// Computed by sampling `positionAt(t+ε) - positionAt(t-ε)`; this is a
  /// numerical derivative, accurate enough for a UI hint. The returned
  /// vector's magnitude is not normalized — callers should `atan2(dy, dx)`
  /// if they only need the angle.
  static Offset tangentAt(double t, {ArenaPack pack = ArenaPack.forest}) {
    const eps = 0.005;
    final a = positionAt((t - eps).clamp(0.0, 1.0), pack: pack);
    final b = positionAt((t + eps).clamp(0.0, 1.0), pack: pack);
    return Offset(b.dx - a.dx, b.dy - a.dy);
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Returns waypoint `i`, clamped at both ends. Catmull-Rom needs the
  /// segment-neighbours i-1 and i+2 to exist; clamping duplicates the
  /// endpoints which gives the standard "no-extrapolation" boundary
  /// behavior (curve starts/ends tangent-aligned with the first/last
  /// segment instead of flying off).
  static Offset _pointOrClamp(List<Offset> waypoints, int i) {
    if (i < 0) return waypoints.first;
    if (i >= waypoints.length) return waypoints.last;
    return waypoints[i];
  }

  /// Centripetal Catmull-Rom interpolation between p1 and p2, with p0 and
  /// p3 as the outer control points. `t` ∈ [0, 1].
  ///
  /// Standard formula — see e.g. Catmull & Rom 1974. We use the uniform
  /// (α=0) variant because waypoint spacing is hand-tuned and we don't
  /// want centripetal weighting to drift the curve off the visible path.
  static Offset _catmullRom(
    Offset p0,
    Offset p1,
    Offset p2,
    Offset p3,
    double t,
  ) {
    final t2 = t * t;
    final t3 = t2 * t;

    double axis(double a, double b, double c, double d) {
      return 0.5 *
          ((2 * b) +
              (-a + c) * t +
              (2 * a - 5 * b + 4 * c - d) * t2 +
              (-a + 3 * b - 3 * c + d) * t3);
    }

    return Offset(
      axis(p0.dx, p1.dx, p2.dx, p3.dx),
      axis(p0.dy, p1.dy, p2.dy, p3.dy),
    );
  }
}
