import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../utils/app_logger.dart';

/// Two extra persistent notifications that layer on top of the foreground-
/// service summary:
///
///   • Battle  — only while a battle is active. Shows your steps vs opponent's
///               with an ahead/behind delta (1v1) or rank + leader gap
///               (group), plus time remaining. Action: "Open battle".
///   • Track   — only while a Track session is active. Shows elapsed time
///               + run stats.
///
/// Track is set to a higher channel importance than Battle so it always
/// renders ABOVE Battle in the shade. Both sit above the LOW-importance
/// daily summary that the foreground service owns.
///
/// Tap a notification → opens the app to the right route. The plugin's tap
/// callback runs in the main isolate, writes the route into
/// [pendingDeepLinkNotifier], and `MainShell` consumes it via context.go.
class PersistentNotifications {
  PersistentNotifications._();
  static final instance = PersistentNotifications._();

  static const String _battleChannelId = 'stepbattle_battle_status';
  static const String _trackChannelId = 'stepbattle_track_status';

  /// FCM incoming-push channel — the "default" channel Firebase Messaging
  /// looks up via the `default_notification_channel_id` meta-data in
  /// AndroidManifest.xml. Without a real channel with IMPORTANCE_HIGH,
  /// the SDK falls back to a system "Miscellaneous" channel that some
  /// OEMs (Xiaomi/OnePlus/Realme) silently drop or deprioritize —
  /// which is why battle-invite pushes weren't landing pre-1.1.6+23.
  /// HIGH importance ensures heads-up popup on modern Android.
  static const String _fcmAlertsChannelId = 'stepbattle_alerts';

  /// Stable notification ids — the same id from `show()` always replaces
  /// the previous post for that channel.
  static const int _battleNotifId = 7301;
  static const int _trackNotifId = 7302;

  /// Action button id for "Open battle". `MainShell._onNotifResponse` parses
  /// the payload to route to the specific battle's arena.
  static const String _btnOpenBattle = 'open_battle';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  int _lastBattleHash = 0;
  int _lastTrackHash = 0;

  /// Whether the battle notification is currently posted. The
  /// last-hash field doubles as this signal — a non-zero value means
  /// a show() call went through without a subsequent cancel().
  /// Read from the FGS isolate to decide whether polling for
  /// battle/track updates is worth it right now.
  bool get isBattlePosted => _lastBattleHash != 0;

  /// Whether the track notification is currently posted. Same
  /// contract as [isBattlePosted].
  bool get isTrackPosted => _lastTrackHash != 0;

  Future<void> init({
    required void Function(String? payload) onTap,
  }) async {
    try {
      const androidInit =
          AndroidInitializationSettings('@drawable/ic_stat_logo');
      const initSettings = InitializationSettings(android: androidInit);
      await _plugin.initialize(
        initSettings,
        onDidReceiveNotificationResponse: (response) {
          onTap(response.payload);
        },
      );

      // Create channels up-front so Android Settings shows them grouped under
      // the app with predictable names even before they're used.
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) {
        await android.createNotificationChannel(
          const AndroidNotificationChannel(
            _battleChannelId,
            'Active battle',
            description:
                'Live score, time remaining, and how far ahead/behind you are.',
            importance: Importance.defaultImportance,
          ),
        );
        await android.createNotificationChannel(
          const AndroidNotificationChannel(
            _trackChannelId,
            'Run / walk tracking',
            description:
                'Live distance, steps, and calories while a Track session is recording.',
            importance: Importance.high,
          ),
        );
        // FCM incoming-alert channel — battle invites, battle results,
        // friend requests, etc. Referenced by
        // `default_notification_channel_id` meta-data in
        // AndroidManifest.xml. IMPORTANCE_HIGH so incoming pushes
        // display as heads-up popup on modern Android and aren't
        // silently dropped by OEM battery-savers.
        await android.createNotificationChannel(
          const AndroidNotificationChannel(
            _fcmAlertsChannelId,
            'Alerts',
            description:
                'Battle invites, battle results, friend requests, and other real-time app alerts.',
            importance: Importance.high,
          ),
        );
      }
      AppLogger.notification.i('persistentNotifs:init_done');
    } catch (e, s) {
      AppLogger.notification
          .e('persistentNotifs:init_failed', error: e, stack: s);
    }
  }

  /// Render or refresh the battle notification. [force] = true bypasses the
  /// hash dedupe (used after a dismissal forces a re-show even if text is
  /// identical to the last post).
  Future<void> showBattle({
    required String battleId,
    required String title,
    required String body,
    required String bigText,
    bool force = false,
  }) async {
    final hash = Object.hash(battleId, title, body, bigText);
    if (!force && hash == _lastBattleHash) return;
    _lastBattleHash = hash;
    try {
      final details = AndroidNotificationDetails(
        _battleChannelId,
        'Active battle',
        channelDescription:
            'Live score, time remaining, and how far ahead/behind you are.',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        ongoing: true,
        onlyAlertOnce: true,
        autoCancel: false,
        showWhen: false,
        styleInformation: BigTextStyleInformation(
          bigText,
          contentTitle: title,
          summaryText: body,
        ),
        actions: const <AndroidNotificationAction>[
          AndroidNotificationAction(
            _btnOpenBattle,
            'Open battle',
            cancelNotification: false,
          ),
        ],
      );
      await _plugin.show(
        _battleNotifId,
        title,
        body,
        NotificationDetails(android: details),
        payload: 'battle:$battleId',
      );
    } catch (e, s) {
      AppLogger.notification
          .e('battleNotif:postFailed', error: e, stack: s);
    }
  }

  Future<void> cancelBattle() async {
    if (_lastBattleHash == 0) return;
    _lastBattleHash = 0;
    try {
      await _plugin.cancel(_battleNotifId);
    } catch (_) {}
  }

  Future<void> showTrack({
    required String title,
    required String body,
    required String bigText,
    bool force = false,
  }) async {
    final hash = Object.hash(title, body, bigText);
    if (!force && hash == _lastTrackHash) return;
    _lastTrackHash = hash;
    try {
      final details = AndroidNotificationDetails(
        _trackChannelId,
        'Run / walk tracking',
        channelDescription:
            'Live distance, steps, and calories while a Track session is recording.',
        importance: Importance.high,
        priority: Priority.high,
        ongoing: true,
        onlyAlertOnce: true,
        autoCancel: false,
        showWhen: false,
        styleInformation: BigTextStyleInformation(
          bigText,
          contentTitle: title,
          summaryText: body,
        ),
      );
      await _plugin.show(
        _trackNotifId,
        title,
        body,
        NotificationDetails(android: details),
        payload: 'track:live',
      );
    } catch (e, s) {
      AppLogger.notification
          .e('trackNotif:postFailed', error: e, stack: s);
    }
  }

  Future<void> cancelTrack() async {
    if (_lastTrackHash == 0) return;
    _lastTrackHash = 0;
    try {
      await _plugin.cancel(_trackNotifId);
    } catch (_) {}
  }
}

/// Set by the plugin's tap callback (top-level fn registered in main.dart),
/// consumed by `MainShell` to do `context.go(<route>)`. Stored as a notifier
/// so the route survives a cold launch — main.dart writes it from
/// `getNotificationAppLaunchDetails()` before the shell mounts.
final ValueNotifier<String?> pendingDeepLinkNotifier =
    ValueNotifier<String?>(null);

/// Parse a notification payload into a route. Returns null if the payload
/// doesn't match any known persistent-notification format.
String? routeForNotifPayload(String? payload) {
  if (payload == null) return null;
  if (payload.startsWith('battle:')) {
    final id = payload.substring(7);
    if (id.isNotEmpty) return '/battle-ground/$id';
  }
  if (payload == 'track:live') return '/track/live';
  return null;
}
