import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/notification_service.dart';

final notificationServiceProvider =
    Provider<NotificationService>((ref) => NotificationService());

/// Whether push notification permission has been granted.
final notificationPermissionProvider = FutureProvider<bool>((ref) {
  return ref.read(notificationServiceProvider).requestPermission();
});
