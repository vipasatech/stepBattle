import 'package:flutter_3d_controller/src/data/repositories/i_flutter_3d_repository.dart';
import 'package:flutter_3d_controller/src/data/datasources/i_flutter_3d_datasource.dart';

class Flutter3DRepository extends IFlutter3DRepository {
  final IFlutter3DDatasource _datasource;

  Flutter3DRepository(this._datasource);

  @override
  void playAnimation({String? animationName, int loopCount = 0}) {
    _datasource.playAnimation(
      animationName: animationName,
      loopCount: loopCount,
    );
  }

  @override
  void pauseAnimation() {
    _datasource.pauseAnimation();
  }

  @override
  void resetAnimation() {
    _datasource.resetAnimation();
  }

  @override
  void stopAnimation() {
    _datasource.stopAnimation();
  }

  @override
  Future<List<String>> getAvailableAnimations() async {
    return await _datasource.getAvailableAnimations();
  }

  @override
  void setTexture({required String textureName}) {
    _datasource.setTexture(textureName: textureName);
  }

  @override
  Future<List<String>> getAvailableTextures() async {
    return await _datasource.getAvailableTextures();
  }

  @override
  void setCameraTarget(double x, double y, double z) {
    _datasource.setCameraTarget(x, y, z);
  }

  @override
  void resetCameraTarget() {
    _datasource.resetCameraTarget();
  }

  @override
  void setCameraOrbit(double theta, double phi, double radius) {
    _datasource.setCameraOrbit(theta, phi, radius);
  }

  @override
  void resetCameraOrbit() {
    _datasource.resetCameraOrbit();
  }

  @override
  void setCameraOrbitBounds({required double minRadius, required double maxRadius}) {
    // Fork-local method. Datasource is a Flutter3DDatasource which we
    // patched to expose this; the datasource interface doesn't declare it,
    // hence the dynamic cast.
    (_datasource as dynamic).setCameraOrbitBounds(
      minRadius: minRadius,
      maxRadius: maxRadius,
    );
  }

  @override
  void setShadowConfig({
    required double shadowIntensity,
    required double shadowSoftness,
    required double exposure,
    String environmentImage = 'neutral',
    double environmentIntensity = 1.0,
  }) {
    (_datasource as dynamic).setShadowConfig(
      shadowIntensity: shadowIntensity,
      shadowSoftness: shadowSoftness,
      exposure: exposure,
      environmentImage: environmentImage,
      environmentIntensity: environmentIntensity,
    );
  }

  @override
  void startRotation({int rotationSpeed = 10}) {
    _datasource.startRotation(rotationSpeed: rotationSpeed);
  }

  @override
  void pauseRotation() {
    _datasource.pauseRotation();
  }

  @override
  void stopRotation() {
    _datasource.stopRotation();
  }
}
