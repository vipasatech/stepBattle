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

enum BattleStatus { pending, active, completed }

class BattleModel {
  final String battleId;
  final BattleType type;
  final BattleStatus status;
  final List<BattleParticipant> participants;
  final DateTime startTime;
  final DateTime endTime;
  final int durationDays;
  final int xpReward;
  final String? winnerId;
  final String createdBy;

  const BattleModel({
    required this.battleId,
    required this.type,
    required this.status,
    required this.participants,
    required this.startTime,
    required this.endTime,
    required this.durationDays,
    required this.xpReward,
    this.winnerId,
    required this.createdBy,
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
      startTime:
          (data['startTime'] as Timestamp?)?.toDate() ?? DateTime.now(),
      endTime: (data['endTime'] as Timestamp?)?.toDate() ?? DateTime.now(),
      durationDays: data['durationDays'] as int? ?? 1,
      xpReward: data['xpReward'] as int? ?? 200,
      winnerId: data['winnerId'] as String?,
      createdBy: data['createdBy'] as String? ?? '',
    );
  }

  Map<String, dynamic> toFirestore() => {
        'type': type == BattleType.oneVsOne ? '1v1' : 'group',
        'status': status.name,
        'participants': participants.map((p) => p.toMap()).toList(),
        'startTime': Timestamp.fromDate(startTime),
        'endTime': Timestamp.fromDate(endTime),
        'durationDays': durationDays,
        'xpReward': xpReward,
        'winnerId': winnerId,
        'createdBy': createdBy,
      };

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
        _ => BattleStatus.pending,
      };
}
