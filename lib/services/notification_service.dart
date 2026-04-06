import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

/// Handles FCM push notifications: permissions, token, foreground/background.
class NotificationService {
  final FirebaseMessaging _messaging;
  final FirebaseFirestore _firestore;

  NotificationService({
    FirebaseMessaging? messaging,
    FirebaseFirestore? firestore,
  })  : _messaging = messaging ?? FirebaseMessaging.instance,
        _firestore = firestore ?? FirebaseFirestore.instance;

  // ---------------------------------------------------------------------------
  // Permissions
  // ---------------------------------------------------------------------------

  Future<bool> requestPermission() async {
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      provisional: false,
    );
    return settings.authorizationStatus == AuthorizationStatus.authorized;
  }

  // ---------------------------------------------------------------------------
  // Token management
  // ---------------------------------------------------------------------------

  /// Save the FCM token to the user's Firestore document.
  Future<void> saveToken(String userId) async {
    final token = await _messaging.getToken();
    if (token != null) {
      await _firestore.collection('users').doc(userId).update({
        'fcmToken': token,
      });
    }

    // Listen for token refresh
    _messaging.onTokenRefresh.listen((newToken) {
      _firestore.collection('users').doc(userId).update({
        'fcmToken': newToken,
      });
    });
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
      'mission_reset' => '/missions',
      'friend_request' => '/leaderboard',
      _ => null,
    };
  }
}
