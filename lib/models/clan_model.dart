import 'package:cloud_firestore/cloud_firestore.dart';

class ClanMember {
  final String userId;
  final String displayName;
  final String? avatarURL;
  final String role; // "captain" | "admin" | "soldier"
  final int stepsToday;

  const ClanMember({
    required this.userId,
    required this.displayName,
    this.avatarURL,
    this.role = 'soldier',
    this.stepsToday = 0,
  });

  bool get isCaptain => role == 'captain';
  bool get isAdmin => role == 'admin';
  bool get isSoldier => role == 'soldier';

  /// Human-readable role label.
  String get roleLabel => switch (role) {
        'captain' => 'Captain',
        'admin' => 'Admin',
        _ => 'Soldier',
      };

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

  /// User IDs with admin privileges (invite/kick soldiers). Captain is NOT
  /// listed here — captain powers are a superset of admin and derived from
  /// `captainId`. Never contains `captainId`.
  final List<String> adminIds;

  /// User IDs that have accepted and are full members (show on dashboard).
  final List<String> memberIds;

  /// User IDs invited but haven't accepted yet.
  final List<String> pendingInviteIds;

  final int totalClanXP;
  final String? activeBattleId;
  final DateTime createdAt;
  final int maxMembers;

  const ClanModel({
    required this.clanId,
    required this.name,
    required this.clanIdCode,
    required this.captainId,
    this.adminIds = const [],
    required this.memberIds,
    this.pendingInviteIds = const [],
    this.totalClanXP = 0,
    this.activeBattleId,
    required this.createdAt,
    this.maxMembers = 10,
  });

  bool get isFull => memberIds.length >= maxMembers;
  int get memberCount => memberIds.length;
  int get pendingInviteCount => pendingInviteIds.length;

  bool hasPendingInviteFor(String userId) =>
      pendingInviteIds.contains(userId);

  /// True if the user is the captain.
  bool isCaptain(String userId) => captainId == userId;

  /// True if the user has admin privileges (captain OR explicit admin).
  bool isAdminOrCaptain(String userId) =>
      captainId == userId || adminIds.contains(userId);

  /// Derive role string for a given user in this clan.
  /// Returns 'captain', 'admin', 'soldier', or 'none' (not a member).
  String roleOf(String userId) {
    if (captainId == userId) return 'captain';
    if (adminIds.contains(userId)) return 'admin';
    if (memberIds.contains(userId)) return 'soldier';
    return 'none';
  }

  factory ClanModel.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    return ClanModel(
      clanId: doc.id,
      name: d['name'] as String? ?? '',
      clanIdCode: d['clanIdCode'] as String? ?? '',
      captainId: d['captainId'] as String? ?? '',
      adminIds: List<String>.from(d['adminIds'] as List? ?? []),
      memberIds: List<String>.from(d['memberIds'] as List? ?? []),
      pendingInviteIds:
          List<String>.from(d['pendingInviteIds'] as List? ?? []),
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
        'adminIds': adminIds,
        'memberIds': memberIds,
        'pendingInviteIds': pendingInviteIds,
        'totalClanXP': totalClanXP,
        'activeBattleId': activeBattleId,
        'createdAt': Timestamp.fromDate(createdAt),
        'maxMembers': maxMembers,
      };
}
