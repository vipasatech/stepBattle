import 'package:cloud_firestore/cloud_firestore.dart';

class BattleParticipant {
  final String userId;
  final String displayName;
  final String? avatarURL;
  final int currentSteps;
  final bool isWinner;

  const BattleParticipant({
    required this.userId,
    required this.displayName,
    this.avatarURL,
    this.currentSteps = 0,
    this.isWinner = false,
  });

  factory BattleParticipant.fromMap(Map<String, dynamic> map) {
    return BattleParticipant(
      userId: map['userId'] as String? ?? '',
      displayName: map['displayName'] as String? ?? '',
      avatarURL: map['avatarURL'] as String?,
      currentSteps: map['currentSteps'] as int? ?? 0,
      isWinner: map['isWinner'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() => {
        'userId': userId,
        'displayName': displayName,
        'avatarURL': avatarURL,
        'currentSteps': currentSteps,
        'isWinner': isWinner,
      };
}

enum BattleType { oneVsOne, group }

enum BattleStatus { pending, active, completed, cancelled }

class BattleModel {
  final String battleId;
  final BattleType type;
  final BattleStatus status;
  final List<BattleParticipant> participants;

  /// User IDs invited but not yet responded (creator + recipients).
  /// Creator's UID is always in `acceptedUserIds` by default.
  final List<String> invitedUserIds;

  /// User IDs who accepted the invite. Battle becomes active when all match invitedUserIds.
  final List<String> acceptedUserIds;

  final DateTime startTime;
  final DateTime endTime;
  final int durationDays;
  final int xpReward;
  final String? winnerId;
  final String createdBy;

  /// When the invite was created. Used for 24h auto-expire check.
  final DateTime createdAt;

  const BattleModel({
    required this.battleId,
    required this.type,
    required this.status,
    required this.participants,
    this.invitedUserIds = const [],
    this.acceptedUserIds = const [],
    required this.startTime,
    required this.endTime,
    required this.durationDays,
    required this.xpReward,
    this.winnerId,
    required this.createdBy,
    required this.createdAt,
  });

  factory BattleModel.fromFirestore(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return BattleModel(
      battleId: doc.id,
      type: _parseType(data['type'] as String? ?? '1v1'),
      status: _parseStatus(data['status'] as String? ?? 'pending'),
      participants: (data['participants'] as List<dynamic>? ?? [])
          .map((p) => BattleParticipant.fromMap(p as Map<String, dynamic>))
          .toList(),
      invitedUserIds:
          List<String>.from(data['invitedUserIds'] as List? ?? []),
      acceptedUserIds:
          List<String>.from(data['acceptedUserIds'] as List? ?? []),
      startTime:
          (data['startTime'] as Timestamp?)?.toDate() ?? DateTime.now(),
      endTime: (data['endTime'] as Timestamp?)?.toDate() ?? DateTime.now(),
      durationDays: data['durationDays'] as int? ?? 1,
      xpReward: data['xpReward'] as int? ?? 200,
      winnerId: data['winnerId'] as String?,
      createdBy: data['createdBy'] as String? ?? '',
      createdAt:
          (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() => {
        'type': type == BattleType.oneVsOne ? '1v1' : 'group',
        'status': status.name,
        'participants': participants.map((p) => p.toMap()).toList(),
        'invitedUserIds': invitedUserIds,
        'acceptedUserIds': acceptedUserIds,
        'startTime': Timestamp.fromDate(startTime),
        'endTime': Timestamp.fromDate(endTime),
        'durationDays': durationDays,
        'xpReward': xpReward,
        'winnerId': winnerId,
        'createdBy': createdBy,
        'createdAt': Timestamp.fromDate(createdAt),
      };

  /// True if this is a pending invite for the given user and they haven't responded.
  bool isPendingInviteFor(String userId) =>
      status == BattleStatus.pending &&
      invitedUserIds.contains(userId) &&
      !acceptedUserIds.contains(userId);

  /// True if the invite has expired (>24h old and still pending).
  bool get isExpired {
    if (status != BattleStatus.pending) return false;
    return DateTime.now().difference(createdAt).inHours >= 24;
  }

  /// Get this user's participant entry.
  BattleParticipant? participantFor(String userId) {
    try {
      return participants.firstWhere((p) => p.userId == userId);
    } catch (_) {
      return null;
    }
  }

  /// Get the opponent in a 1v1 battle.
  BattleParticipant? opponentFor(String userId) {
    try {
      return participants.firstWhere((p) => p.userId != userId);
    } catch (_) {
      return null;
    }
  }

  /// Time remaining from now. Returns Duration.zero if past.
  Duration get timeRemaining {
    final remaining = endTime.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Format remaining time as "Xh Ym" or "X days left".
  String get timeRemainingLabel {
    final r = timeRemaining;
    if (r == Duration.zero) return 'Ended';
    if (r.inDays > 0) return '${r.inDays}d ${r.inHours % 24}h left';
    if (r.inHours > 0) return '${r.inHours}h ${r.inMinutes % 60}m left';
    return '${r.inMinutes}m left';
  }

  /// Short battle ID for display (e.g. "#8402").
  String get shortId {
    if (battleId.length >= 4) {
      return '#${battleId.substring(0, 4).toUpperCase()}';
    }
    return '#${battleId.toUpperCase()}';
  }

  static BattleType _parseType(String s) =>
      s == 'group' ? BattleType.group : BattleType.oneVsOne;

  static BattleStatus _parseStatus(String s) => switch (s) {
        'active' => BattleStatus.active,
        'completed' => BattleStatus.completed,
        'cancelled' => BattleStatus.cancelled,
        _ => BattleStatus.pending,
      };
}
