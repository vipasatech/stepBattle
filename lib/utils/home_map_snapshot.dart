import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'app_logger.dart';

/// Persistent PNG cache of the user's Home-tab "Who's Leading Near
/// You" map preview.
///
/// **Why:** the preview used to instantiate a live `FlutterMap` on
/// every Home mount when the user had a home pin set. FlutterMap
/// downloads OSM tiles and holds a widget graph that repaints on
/// composition — expensive for a card that's currently gated to a
/// "Coming Soon" tap sheet. Since the preview is a static frame
/// (no pan, no zoom, no interaction) we capture the pixels ONCE via
/// [RepaintBoundary.toImage], save the PNG to the app documents
/// directory, and every subsequent visit paints that file — zero
/// tile downloads, zero FlutterMap widget cost.
///
/// **Cache key:** rounded lat/lng in the filename. Rounding to 3
/// decimal places gives ~110 m precision at the equator, which is
/// tighter than the preview's zoom-12 render resolution anyway.
/// Different home → different filename → new capture. Old snapshots
/// never overlap so we never serve a stale-for-this-user pin.
class HomeMapSnapshot {
  const HomeMapSnapshot._();

  /// Bumping this suffix invalidates every existing on-disk snapshot
  /// (useful when the visual design of the preview changes). Bumped
  /// v1 → v2 to purge the earlier snapshots that were captured before
  /// the theme-aware split + opaque backdrop landed — those files had
  /// white gutters baked in and looked wrong when the theme switched
  /// against them.
  static const String _version = 'v2';

  /// Precision of the lat/lng bucket in the filename. 3 decimal
  /// places ≈ 110 m — plenty tight for a preview thumbnail; changing
  /// home coordinates below this threshold reuses the cached PNG,
  /// which is fine because the user visually can't tell.
  static const int _coordPrecision = 3;

  /// Directory that holds all snapshot PNGs. Cached on the first
  /// call because [getApplicationDocumentsDirectory] is async and
  /// we'd otherwise pay it on every read.
  static Directory? _cachedDir;

  /// Deterministic filename for a (lat, lng, theme). Encoded so a
  /// user moving house — or toggling light/dark — triggers a fresh
  /// capture without a manual invalidate, and the two themes' PNGs
  /// coexist so switching back doesn't re-capture.
  static String _filenameFor(
    double lat,
    double lng,
    ui.Brightness brightness,
  ) {
    final la = lat.toStringAsFixed(_coordPrecision);
    final ln = lng.toStringAsFixed(_coordPrecision);
    final t = brightness == ui.Brightness.dark ? 'dark' : 'light';
    // `_` separator keeps filenames grep-friendly and avoids the
    // period-in-name pitfalls that break some file listings.
    return 'home_map_${_version}_${t}_${la}_$ln.png';
  }

  static Future<Directory> _dir() async {
    final cached = _cachedDir;
    if (cached != null) return cached;
    final d = await getApplicationDocumentsDirectory();
    return _cachedDir = d;
  }

  /// Returns the on-disk file for the given coordinates + theme if it
  /// exists, or `null` if nothing has been captured yet for that
  /// combination. Light and dark are cached separately because the
  /// OSM tile source itself differs by brightness (see `osmTileLayer`
  /// in `lib/widgets/map_tile_layer.dart`) — a dark-tile PNG shown
  /// under a light card border looks obviously wrong.
  static Future<File?> readCached(
    double lat,
    double lng,
    ui.Brightness brightness,
  ) async {
    try {
      final dir = await _dir();
      final f = File('${dir.path}/${_filenameFor(lat, lng, brightness)}');
      if (await f.exists()) return f;
      return null;
    } catch (e) {
      AppLogger.geo.w('homeMapSnapshot:readFailed',
          fields: {'err': e.toString()});
      return null;
    }
  }

  /// Capture pixels from the widget behind [boundaryKey] and persist
  /// them as PNG for the given (lat, lng, theme) triple. Returns the
  /// saved file, or `null` on failure.
  ///
  /// Call this AFTER the FlutterMap has had time to fetch its tiles —
  /// a few seconds after mount on a normal connection. Capturing too
  /// early yields a mostly-empty tile grid, which we'd then cache and
  /// keep showing forever.
  ///
  /// [pixelRatio] should be `MediaQuery.of(context).devicePixelRatio`
  /// so the PNG is sharp on 3× screens; higher values just balloon
  /// the file for no visible benefit.
  static Future<File?> capture({
    required GlobalKey boundaryKey,
    required double lat,
    required double lng,
    required ui.Brightness brightness,
    required double pixelRatio,
  }) async {
    try {
      final boundary = boundaryKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return null;
      // If the paint pass hasn't flushed yet (very first frame) the
      // boundary reports `debugNeedsPaint`. Skip and let the caller
      // retry on the next tick rather than saving a mid-paint frame.
      //
      // GUARD: `debugNeedsPaint` is `late bool` populated inside an
      // `assert(() { … }())`. In RELEASE the assert is stripped, the
      // late is never assigned, and reading it throws
      // `LateInitializationError: Local 'result' has not been
      // initialized.` — which is exactly the crash prod hit in 1.1.3.
      // Only check the flag in debug; release relies on the caller's
      // post-frame retry to catch the mid-paint case.
      if (kDebugMode && boundary.debugNeedsPaint) return null;

      final ui.Image image = await boundary.toImage(pixelRatio: pixelRatio);
      final ByteData? bytes =
          await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (bytes == null) return null;

      final dir = await _dir();
      final f = File('${dir.path}/${_filenameFor(lat, lng, brightness)}');
      // Write to a temp file first, then rename — a mid-write kill
      // (foreground service crash, OOM) can never leave a truncated
      // PNG at the canonical filename, which would then be read as
      // corrupt every load until manual invalidation.
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
      await tmp.rename(f.path);

      AppLogger.geo.d('homeMapSnapshot:captured', fields: {
        'path': f.path,
        'bytes': bytes.lengthInBytes,
        'brightness': brightness.name,
      });
      return f;
    } catch (e, s) {
      AppLogger.geo
          .e('homeMapSnapshot:captureFailed', error: e, stack: s);
      return null;
    }
  }
}
