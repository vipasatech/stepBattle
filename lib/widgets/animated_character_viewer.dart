// [3D-DISABLED-2026-08-21] — See lib/models/character_3d.dart header
// for the full disable rationale and re-enable checklist.
//
// This entire file is temporarily disabled. When re-enabling the 3D
// character system:
//   1. Uncomment the block below.
//   2. Restore `flutter_3d_controller` in pubspec.yaml (see marker there).
//   3. Restore `flutter_inappwebview` in pubspec.yaml.
//   4. Restore GLB assets under `assets/images/3dAvatars/` from git
//      history (they were deleted to save AAB size).
//   5. Uncomment sibling files: character_3d.dart, character_3d_provider
//      .dart, character_3d_picker_sheet.dart.
//   6. Uncomment field / method blocks marked [3D-DISABLED-2026-08-21]
//      in user_model.dart, supabase_auth_service.dart, media_warmup.dart,
//      battles_screen.dart.

/*
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

  DateTime? _mountedAt;

  @override
  void initState() {
    super.initState();
    _mountedAt = DateTime.now();
    _controller = Flutter3DController();
  }

  @override
  Widget build(BuildContext context) {
    return Flutter3DViewer(
      controller: _controller,
      src: widget.glbAssetPath,
      progressBarColor: widget.progressBarColor,
      onLoad: (String modelAddress) async {
        final msSinceMount = _mountedAt == null
            ? -1
            : DateTime.now().difference(_mountedAt!).inMilliseconds;
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
            'msSinceMount': msSinceMount,
          });
          if (animations.isEmpty) return;
          _controller.playAnimation(animationName: animations.first);
        } catch (e, s) {
          AppLogger.battle.e('char3d:onLoad:failed',
              fields: {'src': widget.glbAssetPath, 'msSinceMount': msSinceMount},
              error: e,
              stack: s);
        }
      },
    );
  }
}
*/
