import 'package:cloud_firestore/cloud_firestore.dart';

/// In-app notification types. Used for rendering the right icon + action.
enum NotificationType {
  friendRequest,
  friendAccepted,
  battleInvite,
  battleStarted,
  battleRejected,
  battleResult,
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

  factory NotificationModel.fromFirestore(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    return NotificationModel(
      id: doc.id,
      userId: d['userId'] as String? ?? '',
      type: _parseType(d['type'] as String? ?? 'other'),
      title: d['title'] as String? ?? '',
      body: d['body'] as String? ?? '',
      data: Map<String, dynamic>.from(d['data'] as Map? ?? {}),
      read: d['read'] as bool? ?? false,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  static NotificationType _parseType(String s) => switch (s) {
        'friend_request' => NotificationType.friendRequest,
        'friend_accepted' => NotificationType.friendAccepted,
        'battle_invite' => NotificationType.battleInvite,
        'battle_started' => NotificationType.battleStarted,
        'battle_rejected' => NotificationType.battleRejected,
        'battle_result' => NotificationType.battleResult,
        'clan_invite' => NotificationType.clanInvite,
        'level_up' => NotificationType.levelUp,
        'mission_reset' => NotificationType.missionReset,
        _ => NotificationType.other,
      };

  /// Is this an actionable request (needs Accept/Reject)?
  bool get isActionable =>
      type == NotificationType.friendRequest ||
      type == NotificationType.battleInvite ||
      type == NotificationType.clanInvite;
}
