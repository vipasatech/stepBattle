/// In-app notification types. Used for rendering the right icon + action.
///
/// Daily-series lifecycle types (`dailySeriesDropped`, `dailySeriesEnded`)
/// were added when migration 0046 introduced the recurring-daily flow —
/// the server emits these when a user is auto-dropped for insufficient
/// XP or when the series ends because <2 active participants remain.
/// Without them, these notifications fell through to `.other` and
/// silently landed under the generic bell — user couldn't tell why
/// their series stopped.
enum NotificationType {
  friendRequest,
  friendAccepted,
  battleInvite,
  battleStarted,
  battleRejected,
  battleResult,
  dailySeriesDropped,
  dailySeriesEnded,
  clanInvite,
  levelUp,
  missionReset,
  other,
}

class NotificationModel {
  final String id;
  final String userId;
  final NotificationType type;
  final String title;
  final String body;
  final Map<String, dynamic> data;
  final bool read;
  final DateTime createdAt;

  const NotificationModel({
    required this.id,
    required this.userId,
    required this.type,
    required this.title,
    required this.body,
    this.data = const {},
    this.read = false,
    required this.createdAt,
  });
  /// Build from a Supabase `public.notifications` row.
  factory NotificationModel.fromSupabaseRow(Map<String, dynamic> d) {
    return NotificationModel(
      id: d['id'] as String? ?? '',
      userId: d['user_id'] as String? ?? '',
      type: _parseType(d['type'] as String? ?? 'other'),
      title: d['title'] as String? ?? '',
      body: d['body'] as String? ?? '',
      // jsonb is decoded straight to Map<String, dynamic> by the SDK.
      data: Map<String, dynamic>.from(d['data'] as Map? ?? const {}),
      read: d['read'] as bool? ?? false,
      createdAt:
          DateTime.tryParse(d['created_at']?.toString() ?? '') ??
              DateTime.now(),
    );
  }

  static NotificationType _parseType(String s) => switch (s) {
        'friend_request' => NotificationType.friendRequest,
        'friend_accepted' => NotificationType.friendAccepted,
        'battle_invite' => NotificationType.battleInvite,
        'battle_started' => NotificationType.battleStarted,
        'battle_rejected' => NotificationType.battleRejected,
        'battle_result' => NotificationType.battleResult,
        'daily_series_dropped' => NotificationType.dailySeriesDropped,
        'daily_series_ended' => NotificationType.dailySeriesEnded,
        'clan_invite' => NotificationType.clanInvite,
        'level_up' => NotificationType.levelUp,
        'mission_reset' => NotificationType.missionReset,
        _ => NotificationType.other,
      };

  /// Is this an actionable request (needs Accept/Reject)?
  ///
  /// Gated on `!read` — once the user has accepted or declined we
  /// mark the notification as read, so the Accept/Decline buttons
  /// disappear on the next stream emit. Without this gate the
  /// buttons stayed visible even after a successful accept, letting
  /// the user tap them a second time and hitting the
  /// "already resolved" no-op path on the server.
  bool get isActionable =>
      !read &&
      (type == NotificationType.friendRequest ||
          type == NotificationType.battleInvite ||
          type == NotificationType.clanInvite);
}
