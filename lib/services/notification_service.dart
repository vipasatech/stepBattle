import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/app_logger.dart';
import '../utils/permission_coordinator.dart';

/// Handles FCM push notifications: permissions, token, foreground/background.
class NotificationService {
  final FirebaseMessaging _messaging;
  final SupabaseClient _supabase;

  /// The single active token-refresh subscription. FCM's
  /// [FirebaseMessaging.onTokenRefresh] is a broadcast stream — every
  /// `.listen()` stacks another subscriber. Previously the listener
  /// was subscribed from `saveToken`, which fires on every fresh
  /// `MainShell.initState`; navigating to a root-level route that
  /// tears down the shell (like `/battle-ground/:id`) recreated it,
  /// stacking another listener each time and causing N concurrent
  /// Supabase writes on token refresh. Guarding on this field
  /// ensures at most one active listener process-wide.
  ///
  /// Static so `SupabaseAuthService.signOut` — which instantiates
  /// its own `NotificationService()` for the dispose call — targets
  /// the same subscription that `saveToken` opened via the Riverpod
  /// singleton.
  static StreamSubscription<String>? _tokenRefreshSub;

  NotificationService({
    FirebaseMessaging? messaging,
    SupabaseClient? supabase,
  })  : _messaging = messaging ?? FirebaseMessaging.instance,
        _supabase = supabase ?? Supabase.instance.client;

  // ---------------------------------------------------------------------------
  // Permissions
  // ---------------------------------------------------------------------------

  /// Ask the OS for notification permission (Android 13+ / iOS).
  ///
  /// Short-circuits if the app already has permission — no dialog,
  /// no duplicate work. Otherwise routes through [PermissionCoordinator]
  /// so it can't fire concurrently with any other permission dialog
  /// (Android's "one permission flow at a time" rule was the cause of
  /// the login-hang bug where the main-shell's notif request collided
  /// with the permission-gate's `requestAll()`).
  Future<bool> requestPermission() async {
    AppLogger.notification.i('requestPermission:start');
    // Fast path — already authorized. Skip the OS dialog entirely.
    final existing = await _messaging.getNotificationSettings();
    if (existing.authorizationStatus == AuthorizationStatus.authorized) {
      AppLogger.notification.i('requestPermission:alreadyGranted');
      return true;
    }
    final settings = await PermissionCoordinator.instance.enqueue(
      tag: 'notification',
      priority: PermissionPriority.notification,
      action: () => _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      ),
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

  /// Save the FCM token to the user's profile row and attach a
  /// singleton refresh listener that persists any future rotations.
  ///
  /// Cancels any prior refresh subscription before creating a new one
  /// — the shell's `_runInitialSync` can call this multiple times
  /// across its lifetime (root-navigator route pushes recreate the
  /// shell), and stacking listeners meant N concurrent Supabase
  /// writes on every real token rotation.
  Future<void> saveToken(String userId) async {
    // getToken can throw IOException `SERVICE_NOT_AVAILABLE` when
    // Google Play Services is starting up, temporarily unreachable,
    // or absent altogether (some Xiaomi/HyperOS builds). Previous
    // version failed once, logged as ERROR (Sentry), and rethrew —
    // producing the two "saveToken:failed" entries testers see in
    // Diagnostics on Xiaomi devices. Retry with backoff (250ms →
    // 1s → 3s) and swallow the final failure: FCM push is a nice-
    // to-have here and shouldn't crash the shell init.
    String? token;
    Object? lastError;
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        token = await _messaging.getToken();
        lastError = null;
        break;
      } catch (e) {
        lastError = e;
        if (attempt < 2) {
          final backoffMs = 250 * (1 << attempt); // 250, 500, 1000
          AppLogger.notification.w('saveToken:getTokenRetry', fields: {
            'attempt': attempt + 1,
            'nextDelayMs': backoffMs,
            'err': e.toString(),
          });
          await Future<void>.delayed(Duration(milliseconds: backoffMs));
        }
      }
    }
    if (lastError != null) {
      // Final failure — WARN, not ERROR. Missing FCM token means the
      // user won't receive push notifications until a later save
      // attempt succeeds (main_shell retries on resume); everything
      // else works. No Sentry noise for this class of device.
      AppLogger.notification.w('saveToken:unavailable', fields: {
        'userId': userId,
        'err': lastError.toString(),
      });
      return;
    }

    try {
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

      // Replace any prior subscription — see `_tokenRefreshSub` doc
      // for why guarding is required.
      await _tokenRefreshSub?.cancel();
      _tokenRefreshSub = _messaging.onTokenRefresh.listen((newToken) {
        AppLogger.notification.i('tokenRefresh', fields: {'userId': userId});
        _supabase
            .from('profiles')
            .update({'fcm_token': newToken}).eq('id', userId);
      });
    } catch (e) {
      // Supabase write / listener attach failed — WARN, non-fatal.
      AppLogger.notification.w('saveToken:persistFailed', fields: {
        'userId': userId,
        'err': e.toString(),
      });
    }
  }

  /// Cancel the token-refresh listener. Called from the sign-out path
  /// so a fresh sign-in as a different user doesn't inherit the prior
  /// account's listener writing tokens under the wrong uid.
  Future<void> disposeTokenRefreshListener() async {
    await _tokenRefreshSub?.cancel();
    _tokenRefreshSub = null;
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
  ///
  /// For "battle just activated" types (`battle_started`,
  /// `battle_auto_started`) we deep-link straight into the arena at
  /// `/battle-ground/{battle_id}` when the payload carries a battle_id.
  /// The foreground path already navigates automatically via
  /// [BattleActivationDetector] in app.dart — this covers the
  /// background / cold-launch tap case where FCM opens the app from
  /// a killed state.
  static String? extractRoute(Map<String, dynamic> data) {
    final type = data['type'] as String?;
    final battleId = data['battle_id'] as String?;

    switch (type) {
      case 'battle_started':
      case 'battle_auto_started':
        return battleId != null && battleId.isNotEmpty
            ? '/battle-ground/$battleId'
            : '/battles';
      case 'battle_invite':
      case 'battle_result':
      case 'battle_expired':
      case 'battle_invite_expiring':
      case 'battle_rejected':
      case 'daily_series_dropped':
      case 'daily_series_ended':
        return '/battles';
      case 'level_up':
      case 'mission_reset':
        return '/home';
      case 'clan_battle_result':
        return '/clan';
      case 'friend_request':
        return '/leaderboard';
      default:
        return null;
    }
  }
}
