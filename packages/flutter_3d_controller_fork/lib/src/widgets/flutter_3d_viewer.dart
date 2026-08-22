import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_3d_controller/src/controllers/flutter_3d_controller.dart';
import 'package:flutter_3d_controller/src/core/modules/obj_viewer/obj_viewer.dart';
import 'package:flutter_3d_controller/src/data/datasources/i_flutter_3d_datasource.dart';
import 'package:flutter_3d_controller/src/data/repositories/flutter_3d_repository.dart';
import 'package:flutter_3d_controller/src/core/modules/model_viewer/model_viewer.dart';
import 'package:flutter_3d_controller/src/utils/utils.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_3d_controller/src/core/modules/obj_viewer/object.dart'
    as obj;
import 'package:vector_math/vector_math_64.dart' hide Colors;

class Flutter3DViewer extends StatefulWidget {
  /// Src address of 3d model, could be asset address, url or file address.
  final String src;

  /// Default progressBar color, use [Colors.transparent] to hide progress bar.
  final Color? progressBarColor;

  /// If true the flutter_3d_controller will add gesture interceptor layer
  /// to prevent breaking gesture recognizer functionality in iOS and some of
  /// android devices. default = true.
  ///
  /// Notably, when testing other available packages, users may experience
  /// gesture malfunctions on iOS and certain Android devices. However,
  /// Flutter 3D Controller is the first and only package to resolve
  /// this issue with its gesture interceptor feature, introduced
  /// in version 2.0.0, released on October 5, 2024.
  final bool activeGestureInterceptor;

  /// This controller will provide full control of 3d model animations, camera,
  /// variants, etc.
  final Flutter3DController? controller;

  /// This callBack will call at every step of loading progress
  /// and will return double progress value between 0 and 1.0
  final Function(double progressValue)? onProgress;

  /// This callBack will call when model loaded successfully
  /// and will return string model address
  final Function(String modelAddress)? onLoad;

  /// This callBack will call when model failed to load
  /// and will return string error
  final Function(String error)? onError;

  /// If set to false, the model cannot be controlled by touch,
  /// the default value is true.
  final bool enableTouch;

  /// Flag to indicate if the .obj constructor was used.
  final bool isObj;

  /// obj model initial camera values
  final double? scale, cameraX, cameraY, cameraZ;

  /// model-viewer's `environment-image` attribute. Baked into the HTML
  /// at first paint (before onLoad fires) so the scene never renders
  /// with model-viewer's default HDR IBL if we don't want it.
  ///
  /// - null (default): model-viewer uses its built-in neutral HDR — the
  ///   traditional behaviour.
  /// - `''` (empty string): NO environment lighting; the GLB's own
  ///   KHR_lights_punctual is the only light source.
  /// - `'neutral'` / `'legacy'`: model-viewer built-in presets.
  /// - Any URL: custom .hdr / .exr file.
  final String? environmentImage;

  /// model-viewer's `tone-mapping` attribute (model-viewer 3.0+).
  /// Baked into the HTML at first paint. Accepted values:
  ///   `neutral` (default), `aces`, `agx`, `commerce`.
  /// Set to `agx` to match a Blender viewport that uses the AgX view
  /// transform (Blender 4.x default) — the app then renders the GLB
  /// with the same color-management curve the artist saw at export.
  final String? toneMapping;

  /// model-viewer's `exposure` attribute. Multiplier on the whole scene
  /// (and skybox if present). Defaults to 1.0 when not set. Lower
  /// values (0.5-0.8) darken; higher (1.5-2.0) brighten. Useful when
  /// baked KHR_lights_punctual intensities in the GLB are hotter than
  /// the app should render — instead of editing the GLB, compensate
  /// here. Set null to accept model-viewer's 1.0 default.
  final num? exposure;

  const Flutter3DViewer({
    super.key,
    required this.src,
    this.controller,
    this.progressBarColor,
    this.activeGestureInterceptor = true,
    this.enableTouch = true,
    this.onProgress,
    this.onLoad,
    this.onError,
    this.environmentImage,
    this.toneMapping,
    this.exposure,
  })  : isObj = false,
        scale = null,
        cameraX = null,
        cameraY = null,
        cameraZ = null;

  const Flutter3DViewer.obj({
    super.key,
    required this.src,
    this.scale,
    this.cameraX,
    this.cameraY,
    this.cameraZ,
    this.onProgress,
    this.onLoad,
    this.onError,
  })  : progressBarColor = null,
        controller = null,
        activeGestureInterceptor = true,
        enableTouch = true,
        environmentImage = null,
        toneMapping = null,
        exposure = null,
        isObj = true;

  @override
  State<Flutter3DViewer> createState() => _Flutter3DViewerState();
}

class _Flutter3DViewerState extends State<Flutter3DViewer> {
  late Flutter3DController _controller;
  late String _id;
  final Utils _utils = Utils();

  @override
  void initState() {
    _id = _utils.generateId();
    _controller = widget.controller ?? Flutter3DController();
    if (kIsWeb) {
      _controller
          .init(Flutter3DRepository(IFlutter3DDatasource(_id, null, false)));
    }
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return widget.isObj
        ? ObjViewer(
            src: widget.src,
            interactive: widget.enableTouch,
            onSceneCreated: (scene, modelName, modelUrl) {
              scene.camera.position.z = widget.cameraZ ?? 10;
              scene.camera.target.y = widget.cameraY ?? 0;
              scene.camera.target.x = widget.cameraX ?? 0;
              scene.world.add(
                obj.Object(
                  scale: Vector3(widget.scale ?? 5.0, widget.scale ?? 5.0,
                      widget.scale ?? 5.0),
                  fileName: modelName,
                  url: modelUrl,
                  onProgress: widget.onProgress,
                  onLoad: (modelAddress) {
                    widget.onLoad?.call(modelAddress);
                  },
                  onError: (error) {
                    widget.onError?.call(error);
                  },
                ),
              );
            },
          )
        : ModelViewer(
            id: _id,
            src: widget.src,
            progressBarColor: widget.progressBarColor,
            environmentImage: widget.environmentImage,
            toneMapping: widget.toneMapping,
            exposure: widget.exposure,
            relatedJs: _utils.injectedJS(_id, 'flutter-3d-controller'),
            interactionPrompt: InteractionPrompt.none,
            activeGestureInterceptor: widget.activeGestureInterceptor,
            cameraControls: widget.enableTouch,
            ar: false,
            autoPlay: false,
            autoRotate: false,
            debugLogging: false,
            disableTap: true,
            onProgress: widget.onProgress,
            onLoad: (modelAddress) {
              _controller.onModelLoaded.value = true;
              widget.onLoad?.call(modelAddress);
            },
            onError: (error) {
              _controller.onModelLoaded.value = false;
              widget.onError?.call(error);
            },
            onWebViewCreated: kIsWeb
                ? null
                : (InAppWebViewController value) {
                    _controller.init(
                      Flutter3DRepository(
                        IFlutter3DDatasource(
                          _id,
                          value,
                          widget.activeGestureInterceptor,
                        ),
                      ),
                    );
                  },
          );
  }

  @override
  void dispose() {
    _controller.onModelLoaded.dispose();
    super.dispose();
  }
}
