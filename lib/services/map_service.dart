import '../models/user_model.dart';

/// Map service — stubbed for v1 (no Google Maps / Geolocator).
/// Full implementation with live map in v2.
class MapService {
  Future<bool> checkPermission() async => false;
  Future<bool> requestPermission() async => false;

  Future<List<UserModel>> getNearbyUsers({
    required double lat,
    required double lng,
    double radiusKm = 5.0,
  }) async => [];
}
