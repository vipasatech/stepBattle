import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/app_logger.dart';

/// Handles FCM push notifications: permissions, token, foreground/background.
class NotificationService {
  final FirebaseMessaging _messaging;
  final SupabaseClient _supabase;

  NotificationService({
    FirebaseMessaging? messaging,
    SupabaseClient? supabase,
  })  : _messaging = messaging ?? FirebaseMessaging.instance,
        _supabase = supabase ?? Supabase.instance.client;

  // ---------------------------------------------------------------------------
  // Permissions
  // ---------------------------------------------------------------------------

  Future<bool> requestPermission() async {
    AppLogger.notification.i('requestPermission:start');
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
    final granted =
        settings.authorizationStatus == AuthorizationStatus.authorized;
    AppLogger.notification.i('requestPermission:done',
        fields: {'status': settings.authorizationStatus.name, 'granted': granted});
    return granted;
  }

  // ---------------------------------------------------------------------------
  // Token management
  // ---------------------------------------------------------------------------

  /// Save the FCM token to the user's profile row.
  Future<void> saveToken(String userId) async {
    try {
      final token = await _messaging.getToken();
      AppLogger.notification.i('saveToken', fields: {
        'userId': userId,
        'hasToken': token != null,
        'tokenPrefix': token != null && token.length > 8
            ? '${token.substring(0, 8)}...'
            : null,
      });
      if (token != null) {
        await _supabase
            .from('profiles')
            .update({'fcm_token': token}).eq('id', userId);
      }

      // Listen for token refresh and persist the new one.
      _messaging.onTokenRefresh.listen((newToken) {
        AppLogger.notification.i('tokenRefresh', fields: {'userId': userId});
        _supabase
            .from('profiles')
            .update({'fcm_token': newToken}).eq('id', userId);
      });
    } catch (e, s) {
      AppLogger.notification.e('saveToken:failed',
          fields: {'userId': userId}, error: e, stack: s);
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Topic subscriptions
  // ---------------------------------------------------------------------------

  Future<void> subscribeToTopic(String topic) async {
    await _messaging.subscribeToTopic(topic);
  }

  Future<void> unsubscribeFromTopic(String topic) async {
    await _messaging.unsubscribeFromTopic(topic);
  }

  // ---------------------------------------------------------------------------
  // Message handling
  // ---------------------------------------------------------------------------

  /// Set up foreground message handler. Call this at app startup.
  void setupForegroundHandler({
    required void Function(RemoteMessage message) onMessage,
  }) {
    FirebaseMessaging.onMessage.listen(onMessage);
  }

  /// Handle notification tap when app was in background/terminated.
  void setupBackgroundTapHandler({
    required void Function(RemoteMessage message) onMessageOpenedApp,
  }) {
    FirebaseMessaging.onMessageOpenedApp.listen(onMessageOpenedApp);
  }

  /// Check if app was opened from a terminated state via notification.
  Future<RemoteMessage?> getInitialMessage() async {
    return _messaging.getInitialMessage();
  }

  // ---------------------------------------------------------------------------
  // Notification types (for deep linking)
  // ---------------------------------------------------------------------------

  /// Extract deep link route from notification data payload.
  static String? extractRoute(Map<String, dynamic> data) {
    final type = data['type'] as String?;

    return switch (type) {
      'battle_invite' => '/battles',
      'battle_result' => '/battles',
      'level_up' => '/home',
      'clan_battle_result' => '/clan',
      // Missions tab retired (migration 0016) — surface mission resets
      // on Home where the new daily target card lives.
      'mission_reset' => '/home',
      'friend_request' => '/leaderboard',
      _ => null,
    };
  }
}
