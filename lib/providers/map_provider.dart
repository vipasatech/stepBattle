import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/map_service.dart';

/// Map providers — stubbed for v1. Full implementation in v2.
final mapServiceProvider = Provider<MapService>((ref) => MapService());

final locationPermissionProvider = FutureProvider<bool>((ref) {
  return ref.read(mapServiceProvider).checkPermission();
});
