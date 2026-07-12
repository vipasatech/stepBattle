import 'package:flutter_3d_controller/src/core/exception/flutter_3d_controller_exception.dart';
import 'package:flutter_3d_controller/src/data/datasources/i_flutter_3d_datasource.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class Flutter3DDatasource implements IFlutter3DDatasource {
  final InAppWebViewController? _webViewController;
  final bool _activeGestureInterceptor;
  final String _viewerId;

  Flutter3DDatasource(
    this._viewerId, [
    this._webViewController,
    this._activeGestureInterceptor = false,
  ]);

  @override
  void playAnimation({
    String? animationName,
    int loopCount = 0,
  }) {
    String loopValue = loopCount <= 0 ? 'Infinity' : loopCount.toString();
    animationName == null
        ? executeCustomJsCode(
            "const modelViewer = document.getElementById(\"$_viewerId\");"
            "modelViewer.updateComplete.then(() => {"
            "modelViewer.play({repetitions: \"$loopValue\"});"
            "});")
        : executeCustomJsCode(
            "const modelViewer = document.getElementById(\"$_viewerId\");"
            "modelViewer.pause();"
            "modelViewer.animationName = \"\";"
            "modelViewer.animationName = \"$animationName\";"
            "modelViewer.updateComplete.then(() => {"
            "modelViewer.play({repetitions: \"$loopValue\"});"
            "});");
  }

  @override
  void pauseAnimation() {
    executeCustomJsCode(
      "const modelViewer = document.getElementById(\"$_viewerId\");"
      "modelViewer.pause();",
    );
  }

  @override
  void resetAnimation() {
    executeCustomJsCode(
      "const modelViewer = document.getElementById(\"$_viewerId\");"
      "modelViewer.pause();"
      "modelViewer.currentTime = 0;"
      "modelViewer.play();",
    );
  }

  @override
  void stopAnimation() {
    executeCustomJsCode(
      "const modelViewer = document.getElementById(\"$_viewerId\");"
      "modelViewer.pause();"
      "modelViewer.currentTime = 0;",
    );
  }

  @override
  Future<List<String>> getAvailableAnimations() async {
    try {
      final List<Object?> rawAnimations = await executeCustomJsCodeWithResult(
        "document.getElementById(\"$_viewerId\").availableAnimations;",
      );
      List<String> animations = [];
      for (final animItem in rawAnimations) {
        if (animItem != null) {
          animations.add(animItem.toString());
        }
      }
      return animations;
    } catch (e) {
      throw Flutter3dControllerFormatException(
          message: 'Failed to retrieve animation list, ${e.toString()}');
    }
  }

  @override
  void setTexture({required String textureName}) {
    executeCustomJsCode(
      "const modelViewer = document.getElementById(\"$_viewerId\");"
      "modelViewer.variantName = \"$textureName\";",
    );
  }

  @override
  Future<List<String>> getAvailableTextures() async {
    try {
      final List<Object?> rawVariants = await executeCustomJsCodeWithResult(
        "document.getElementById(\"$_viewerId\").availableVariants;",
      );
      List<String> variants = [];
      for (final variantItem in rawVariants) {
        if (variantItem != null) {
          variants.add(variantItem.toString());
        }
      }
      return variants;
    } catch (e) {
      throw Flutter3dControllerFormatException(
          message: 'Failed to retrieve texture list, ${e.toString()}');
    }
  }

  @override
  void setCameraTarget(double x, double y, double z) {
    // Zero delay so drag-pan can update the target at ~60 fps. The 100 ms
    // upstream delay makes the pan feel like it moves in ~10 fps steps.
    executeCustomJsCode(
      "const modelViewer = document.getElementById(\"$_viewerId\");"
      "modelViewer.cameraTarget = \"${x}m ${y}m ${z}m\";",
      0,
      300,
      _activeGestureInterceptor,
    );
  }

  @override
  void resetCameraTarget() {
    executeCustomJsCode(
      "const modelViewer = document.getElementById(\"$_viewerId\");"
      "modelViewer.cameraTarget = \"auto auto auto\";",
      100,
      300,
      _activeGestureInterceptor,
    );
  }

  @override
  void setCameraOrbit(double theta, double phi, double radius) {
    // Set ONLY the orbit — no bounds/interactionPrompt/autoRotate. Callers
    // should call setCameraOrbitBounds() first (on mode entry) to install
    // clamps. This split lets gesture-driven zoom updates fire many times
    // per second without each call re-locking the max radius.
    executeCustomJsCode(
      "const modelViewer = document.getElementById(\"$_viewerId\");"
      "modelViewer.cameraOrbit = \"${theta}deg ${phi}deg ${radius}m\";",
      0,
      400,
      _activeGestureInterceptor,
    );
  }

  /// Install clamp bounds on the camera orbit's radius, plus kill model-
  /// viewer's auto-reset behaviours (interaction-prompt animation, auto-
  /// rotate). Call this ONCE per camera mode entry; then use
  /// [setCameraOrbit] for the actual per-frame orbit updates.
  void setCameraOrbitBounds({required double minRadius, required double maxRadius}) {
    executeCustomJsCode(
      "const modelViewer = document.getElementById(\"$_viewerId\");"
      "modelViewer.minCameraOrbit = \"auto auto ${minRadius}m\";"
      "modelViewer.maxCameraOrbit = \"auto auto ${maxRadius}m\";"
      "modelViewer.interactionPrompt = \"none\";"
      "modelViewer.autoRotate = false;",
      0,
      400,
      _activeGestureInterceptor,
    );
  }

  /// Fork-local: install ground contact shadow + tone-map exposure so the
  /// arena reads as a proper daytime scene instead of a flat unlit render.
  /// Call once after the model loads.
  ///
  /// - [shadowIntensity] 0..1  (0 = no ground shadow, 1 = fully opaque black).
  /// - [shadowSoftness]  0..1  (0 = crisp hard-edge shadow, 1 = maximally soft).
  /// - [exposure]        0..2  (1.0 = neutral; >1 brightens the whole scene).
  /// - [environmentImage] Optional model-viewer preset name like "neutral"
  ///   or an HDR URL. Empty string uses the default HDR environment shipped
  ///   with model-viewer (a subtle overcast).
  void setShadowConfig({
    required double shadowIntensity,
    required double shadowSoftness,
    required double exposure,
    String environmentImage = 'neutral',
    double environmentIntensity = 1.0,
  }) {
    final env = environmentImage.isEmpty
        ? ''
        : 'modelViewer.environmentImage = \\"$environmentImage\\";';
    executeCustomJsCode(
      "const modelViewer = document.getElementById(\"$_viewerId\");"
      "modelViewer.shadowIntensity = $shadowIntensity;"
      "modelViewer.shadowSoftness = $shadowSoftness;"
      "modelViewer.exposure = $exposure;"
      "modelViewer.environmentIntensity = $environmentIntensity;"
      "$env",
      0,
      400,
      _activeGestureInterceptor,
    );
  }

  @override
  void resetCameraOrbit() {
    executeCustomJsCode(
      "const modelViewer = document.getElementById(\"$_viewerId\");"
      "modelViewer.cameraOrbit = \"0deg 75deg 105%\" ;",
      100,
      400,
      _activeGestureInterceptor,
    );
  }

  @override
  void startRotation({int? rotationSpeed = 10}) {
    executeCustomJsCode(
      "const modelViewer = document.getElementById(\"$_viewerId\");"
      "modelViewer.autoRotateDelay = \"500\";"
      "modelViewer.autoRotate = \"true\";"
      "modelViewer.rotationPerSecond = \"${rotationSpeed}deg\";",
    );
  }

  @override
  void pauseRotation() {
    executeCustomJsCode(
      "const modelViewer = document.getElementById(\"$_viewerId\");"
      "modelViewer.autoRotate = \"false\";"
      "modelViewer.rotationPerSecond = \"0deg\";",
    );
  }

  @override
  void stopRotation() {
    executeCustomJsCode(
      "const modelViewer = document.getElementById(\"$_viewerId\");"
      "modelViewer.autoRotate = \"false\";"
      "modelViewer.rotationPerSecond = \"0deg\";"
      "modelViewer.resetTurntableRotation(0);",
    );
  }

  @override
  void executeCustomJsCode(String code,
      [int codeDelay = 0,
      int refresherDelay = 0,
      bool refreshGestureInterceptor = false]) async {
    await Future.delayed(Duration(milliseconds: codeDelay));

    _webViewController?.evaluateJavascript(source: '''
        (() => {
          customEvaluate('$code');
        })();
    ''');

    if (refreshGestureInterceptor) {
      Future.delayed(Duration(milliseconds: refresherDelay), () {
        _webViewController?.evaluateJavascript(source: """
          cloneGestureData(modelViewer, modelViewerInterceptor);
        """);
      });
    }
  }

  @override
  Future<dynamic> executeCustomJsCodeWithResult(String code) async {
    final result = await _webViewController?.evaluateJavascript(source: code);
    return result;
  }
}
