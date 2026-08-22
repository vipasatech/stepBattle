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
///
/// **Not `.autoDispose`** — the AppBar bell derives its unread count
/// from this stream and must survive across screens.
///
/// The earlier split-stream design (this + a lean `.eq('read', false)`
/// stream) was subtly wrong: Supabase realtime applies filters to the
/// NEW record of an UPDATE. When a row transitions from `read=false`
/// → `read=true`, the new record no longer matches the `read=false`
/// filter, so the client's realtime handler NEVER receives the
/// update. The cached row stays in local `_streamData` at
/// `read=false` forever, and the unread badge shows a phantom count.
/// Scoping only by `user_id` (which never changes) means every
/// state transition of every user-owned row is delivered.
final notificationsProvider = StreamProvider<List<NotificationModel>>((ref) {
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

/// Unread notification count (for bell badge). Derived from
/// [notificationsProvider] with a client-side `!n.read` filter — the
/// full-row watch guarantees read-state transitions are seen.
final unreadNotificationCountProvider = Provider<int>((ref) {
  final list = ref.watch(notificationsProvider).valueOrNull ?? const [];
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
