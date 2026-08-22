import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../utils/app_logger.dart';
import 'battleground_tile.dart';

/// Warm the Flutter asset bundle cache for large media that would
/// otherwise stall the first frame that needs them.
///
/// The arena is now a portrait PNG (~1.4 MB per TOD, rendered from
/// Blender). AssetImage caches by-key, so preloading through rootBundle
/// during splash means the first battle open displays it from memory
/// with no disk hit. The old 3D GLB pipeline (9-10 MB per file with
/// heavy WebView shader compile) was retired — the PNG approach is
/// smaller AND instant.
///
/// Only preload the ONE variant matching the current time-of-day —
/// preloading all four wastes disk I/O for TODs the user won't hit
/// before Home renders.
class MediaWarmup {
  MediaWarmup._();

  /// Fire-and-forget: kick off the preload and return the future so the
  /// caller can await (or ignore) it. Errors are logged but never rethrown
  /// — a warmup failure must not block app boot.
  static Future<void> preloadArenaForNow() async {
    final tod = BattlegroundTimeOfDay.forNow();
    final path = 'assets/images/battleground/cityView/arena_${tod.name}.png';
    final stopwatch = Stopwatch()..start();
    try {
      // Loading through rootBundle populates its ByteData cache. Flutter's
      // AssetImage / Image.asset then find the bytes already in memory
      // on the first render.
      final bytes = await rootBundle.load(path);
      AppLogger.battle.i('mediaWarmup:arenaLoaded', fields: {
        'path': path,
        'bytes': bytes.lengthInBytes,
        'ms': stopwatch.elapsedMilliseconds,
      });
    } catch (e, s) {
      AppLogger.battle.w('mediaWarmup:arenaFailed',
          fields: {'path': path, 'err': e.toString()});
      // Log at .e too so Sentry captures it (via the AppLogger hook) —
      // repeated warmup failures indicate a build config issue (asset
      // not bundled, or a bad path after a refactor).
      AppLogger.battle
          .e('mediaWarmup:arenaFailed', fields: {'path': path}, error: e, stack: s);
    }
  }

  /// Force the Android/iOS system WebView provider to initialize before
  /// the corner character viewer (Flutter3DViewer) mounts.
  ///
  /// The arena went 2D but the small corner character tile still uses
  /// Flutter3DViewer to render an animated GLB. Priming the WebView
  /// provider at boot means that tile's first paint is instant instead
  /// of paying the ~500-1000 ms Chromium/V8 cold-start cost.
  ///
  /// `getDefaultUserAgent()` is the smallest safe API on
  /// flutter_inappwebview that forces provider init. Silent failure —
  /// warmup is best-effort.
  static Future<void> primeWebViewEngine() async {
    final stopwatch = Stopwatch()..start();
    try {
      final ua = await InAppWebViewController.getDefaultUserAgent();
      AppLogger.battle.i('mediaWarmup:webViewPrimed', fields: {
        'ms': stopwatch.elapsedMilliseconds,
        'uaLen': ua.length,
      });
    } catch (e) {
      AppLogger.battle.w('mediaWarmup:webViewPrimeFailed',
          fields: {'ms': stopwatch.elapsedMilliseconds, 'err': e.toString()});
    }
  }
}
