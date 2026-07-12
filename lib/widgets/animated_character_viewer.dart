import 'package:flutter/material.dart';
import 'package:flutter_3d_controller/flutter_3d_controller.dart';

import '../utils/app_logger.dart';

/// Thin wrapper around [Flutter3DViewer] that explicitly starts the model's
/// first baked animation as soon as the GLB finishes loading.
///
/// Why: `flutter_3d_controller` v2.x does NOT auto-play animations on
/// mount — it defers to the caller. Without this wrapper, all our
/// characters render in bind pose (T-pose) forever, which looks broken
/// on the Home showcase, the picker, and the battle-arena band.
///
/// One [Flutter3DController] is owned per widget instance and disposed
/// with it. Consumers should still pass a stable [ValueKey] so switching
/// between `men` and `women` forces a fresh WebView (the underlying
/// controller only reliably swaps `src` when the whole widget rebuilds).
class AnimatedCharacterViewer extends StatefulWidget {
  /// Asset path to the `.glb` file (e.g. `Character3D.glbAssetPath`).
  final String glbAssetPath;

  /// Colour of the built-in load progress bar. Pass a transparent colour
  /// to hide it entirely (used by the arena band where the bar would
  /// visually clash with the tile art below).
  final Color progressBarColor;

  const AnimatedCharacterViewer({
    super.key,
    required this.glbAssetPath,
    this.progressBarColor = Colors.transparent,
  });

  @override
  State<AnimatedCharacterViewer> createState() =>
      _AnimatedCharacterViewerState();
}

class _AnimatedCharacterViewerState extends State<AnimatedCharacterViewer> {
  late final Flutter3DController _controller;

  @override
  void initState() {
    super.initState();
    _controller = Flutter3DController();
  }

  @override
  Widget build(BuildContext context) {
    return Flutter3DViewer(
      controller: _controller,
      src: widget.glbAssetPath,
      progressBarColor: widget.progressBarColor,
      onLoad: (String modelAddress) async {
        // Baked animation is our exported Taunt loop. We could name it
        // via a Character3D field, but the GLB only has one animation
        // and glTF spec makes it index 0 — grabbing the first available
        // name is robust to Blender's action-name quirks.
        try {
          final animations = await _controller.getAvailableAnimations();
          AppLogger.battle.i('char3d:onLoad', fields: {
            'src': widget.glbAssetPath,
            'animCount': animations.length,
            'anims': animations,
          });
          if (animations.isEmpty) return;
          _controller.playAnimation(animationName: animations.first);
        } catch (e, s) {
          AppLogger.battle.e('char3d:onLoad:failed',
              fields: {'src': widget.glbAssetPath},
              error: e,
              stack: s);
        }
      },
    );
  }
}
