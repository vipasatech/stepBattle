import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/notification_model.dart';
import '../services/notification_service.dart';
import 'auth_provider.dart';

final notificationServiceProvider =
    Provider<NotificationService>((ref) => NotificationService());

/// Whether push notification permission has been granted.
final notificationPermissionProvider = FutureProvider<bool>((ref) {
  return ref.read(notificationServiceProvider).requestPermission();
});

/// Stream of in-app notifications for the current user, newest first.
final notificationsProvider =
    StreamProvider<List<NotificationModel>>((ref) {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return Stream.value([]);

  return Supabase.instance.client
      .from('notifications')
      .stream(primaryKey: ['id'])
      .eq('user_id', user.id)
      .order('created_at', ascending: false)
      .limit(50)
      .map((rows) =>
          rows.map(NotificationModel.fromSupabaseRow).toList());
});

/// Unread notification count (for bell badge).
final unreadNotificationCountProvider = Provider<int>((ref) {
  final list = ref.watch(notificationsProvider).valueOrNull ?? [];
  return list.where((n) => !n.read).length;
});

/// Mark a single notification as read.
Future<void> markNotificationRead(String notificationId) async {
  await Supabase.instance.client
      .from('notifications')
      .update({'read': true}).eq('id', notificationId);
}

/// Mark all of a user's notifications as read.
Future<void> markAllNotificationsRead(String userId) async {
  await Supabase.instance.client
      .from('notifications')
      .update({'read': true})
      .eq('user_id', userId)
      .eq('read', false);
}
