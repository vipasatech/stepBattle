import 'package:cloud_firestore/cloud_firestore.dart';

class ClanBattleTeam {
  final String clanId;
  final String clanName;
  final int totalSteps;

  const ClanBattleTeam({
    required this.clanId,
    required this.clanName,
    this.totalSteps = 0,
  });

  factory ClanBattleTeam.fromMap(Map<String, dynamic> m) => ClanBattleTeam(
        clanId: m['clanId'] as String? ?? '',
        clanName: m['clanName'] as String? ?? '',
        totalSteps: m['totalSteps'] as int? ?? 0,
      );

  Map<String, dynamic> toMap() => {
        'clanId': clanId,
        'clanName': clanName,
        'totalSteps': totalSteps,
      };
}

enum ClanBattleStatus { pending, active, completed }

class ClanBattleModel {
  final String clanBattleId;
  final ClanBattleStatus status;
  final ClanBattleTeam clanA;
  final ClanBattleTeam clanB;
  final DateTime startTime;
  final DateTime endTime;
  final int durationDays;
  final String battleType; // "total_steps" | "daily_average"
  final int xpPerMember;
  final String? winnerClanId;

  const ClanBattleModel({
    required this.clanBattleId,
    required this.status,
    required this.clanA,
    required this.clanB,
    required this.startTime,
    required this.endTime,
    required this.durationDays,
    required this.battleType,
    this.xpPerMember = 300,
    this.winnerClanId,
  });

  Duration get timeRemaining {
    final r = endTime.difference(DateTime.now());
    return r.isNegative ? Duration.zero : r;
  }

  String get timeRemainingLabel {
    final r = timeRemaining;
    if (r == Duration.zero) return 'Ended';
    if (r.inDays > 0) return '${r.inDays} days left';
    if (r.inHours > 0) return '${r.inHours}h left';
    return '${r.inMinutes}m left';
  }

  factory ClanBattleModel.fromFirestore(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    return ClanBattleModel(
      clanBattleId: doc.id,
      status: _parseStatus(d['status'] as String? ?? 'pending'),
      clanA: ClanBattleTeam.fromMap(d['clanA'] as Map<String, dynamic>? ?? {}),
      clanB: ClanBattleTeam.fromMap(d['clanB'] as Map<String, dynamic>? ?? {}),
      startTime: (d['startTime'] as Timestamp?)?.toDate() ?? DateTime.now(),
      endTime: (d['endTime'] as Timestamp?)?.toDate() ?? DateTime.now(),
      durationDays: d['durationDays'] as int? ?? 3,
      battleType: d['battleType'] as String? ?? 'total_steps',
      xpPerMember: d['xpPerMember'] as int? ?? 300,
      winnerClanId: d['winnerClanId'] as String?,
    );
  }

  Map<String, dynamic> toFirestore() => {
        'status': status.name,
        'clanA': clanA.toMap(),
        'clanB': clanB.toMap(),
        'startTime': Timestamp.fromDate(startTime),
        'endTime': Timestamp.fromDate(endTime),
        'durationDays': durationDays,
        'battleType': battleType,
        'xpPerMember': xpPerMember,
        'winnerClanId': winnerClanId,
      };

  static ClanBattleStatus _parseStatus(String s) => switch (s) {
        'active' => ClanBattleStatus.active,
        'completed' => ClanBattleStatus.completed,
        _ => ClanBattleStatus.pending,
      };
}
