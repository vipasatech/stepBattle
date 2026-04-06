import 'package:cloud_firestore/cloud_firestore.dart';

class ClanMember {
  final String userId;
  final String displayName;
  final String? avatarURL;
  final String role; // "captain" | "soldier"
  final int stepsToday;

  const ClanMember({
    required this.userId,
    required this.displayName,
    this.avatarURL,
    this.role = 'soldier',
    this.stepsToday = 0,
  });

  bool get isCaptain => role == 'captain';

  factory ClanMember.fromMap(Map<String, dynamic> m) => ClanMember(
        userId: m['userId'] as String? ?? '',
        displayName: m['displayName'] as String? ?? '',
        avatarURL: m['avatarURL'] as String?,
        role: m['role'] as String? ?? 'soldier',
        stepsToday: m['stepsToday'] as int? ?? 0,
      );

  Map<String, dynamic> toMap() => {
        'userId': userId,
        'displayName': displayName,
        'avatarURL': avatarURL,
        'role': role,
        'stepsToday': stepsToday,
      };
}

class ClanModel {
  final String clanId;
  final String name;
  final String clanIdCode; // e.g. "#CL7X9"
  final String captainId;
  final List<String> memberIds;
  final int totalClanXP;
  final String? activeBattleId;
  final DateTime createdAt;
  final int maxMembers;

  const ClanModel({
    required this.clanId,
    required this.name,
    required this.clanIdCode,
    required this.captainId,
    required this.memberIds,
    this.totalClanXP = 0,
    this.activeBattleId,
    required this.createdAt,
    this.maxMembers = 10,
  });

  bool get isFull => memberIds.length >= maxMembers;
  int get memberCount => memberIds.length;

  factory ClanModel.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    return ClanModel(
      clanId: doc.id,
      name: d['name'] as String? ?? '',
      clanIdCode: d['clanIdCode'] as String? ?? '',
      captainId: d['captainId'] as String? ?? '',
      memberIds: List<String>.from(d['memberIds'] as List? ?? []),
      totalClanXP: d['totalClanXP'] as int? ?? 0,
      activeBattleId: d['activeBattleId'] as String?,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      maxMembers: d['maxMembers'] as int? ?? 10,
    );
  }

  Map<String, dynamic> toFirestore() => {
        'name': name,
        'clanIdCode': clanIdCode,
        'captainId': captainId,
        'memberIds': memberIds,
        'totalClanXP': totalClanXP,
        'activeBattleId': activeBattleId,
        'createdAt': Timestamp.fromDate(createdAt),
        'maxMembers': maxMembers,
      };
}
