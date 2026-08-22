class ClanMember {
  final String userId;
  final String displayName;

  /// Live-joined from `profiles.preferred_name` at read time (see
  /// `ClanService.watchMembers`). Null when unset; `friendlyName`
  /// falls back to `displayName`. Same contract as
  /// `UserModel.friendlyName` and `BattleParticipant.friendlyName`.
  final String? preferredName;

  final String? avatarURL;
  final String role; // "captain" | "admin" | "soldier"
  final int stepsToday;

  const ClanMember({
    required this.userId,
    required this.displayName,
    this.preferredName,
    this.avatarURL,
    this.role = 'soldier',
    this.stepsToday = 0,
  });

  bool get isCaptain => role == 'captain';
  bool get isAdmin => role == 'admin';
  bool get isSoldier => role == 'soldier';

  /// Nickname if set at join time, otherwise the full display name.
  String get friendlyName {
    final trimmed = preferredName?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    return displayName;
  }

  /// Human-readable role label.
  String get roleLabel => switch (role) {
        'captain' => 'Captain',
        'admin' => 'Admin',
        _ => 'Soldier',
      };

  factory ClanMember.fromMap(Map<String, dynamic> m) => ClanMember(
        userId: m['userId'] as String? ?? '',
        displayName: m['displayName'] as String? ?? '',
        preferredName: m['preferredName'] as String?,
        avatarURL: m['avatarURL'] as String?,
        role: m['role'] as String? ?? 'soldier',
        stepsToday: m['stepsToday'] as int? ?? 0,
      );

  /// Build from a `clan_members` row with a joined `profiles(...)` embed.
  /// PostgREST nested-select shape used by `ClanService.watchMembers`:
  ///   `select('user_id, role, steps_today, profiles!inner(display_name, preferred_name, avatar_url)')`
  factory ClanMember.fromSupabaseRow(Map<String, dynamic> d) {
    final profile = d['profiles'] as Map<String, dynamic>?;
    return ClanMember(
      userId: d['user_id'] as String? ?? '',
      displayName: profile?['display_name'] as String? ?? '',
      preferredName: profile?['preferred_name'] as String?,
      avatarURL: profile?['avatar_url'] as String?,
      role: d['role'] as String? ?? 'soldier',
      stepsToday: (d['steps_today'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
        'userId': userId,
        'displayName': displayName,
        'preferredName': preferredName,
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

  /// Spendable Clan XP treasury (migration 0016). Funded by:
  ///   • +100 per clan member, per clan battle played
  ///   • Pot transfer when this clan wins a clan battle
  ///   • Captain-initiated Razorpay top-up
  /// Spent by the captain when creating a clan battle (the stake).
  final int clanXp;

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
    this.clanXp = 0,
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

  /// Build from a Supabase `clans` row joined with `clan_members` (for
  /// memberIds + adminIds) and `clan_invites` (for pendingInviteIds).
  ///
  /// Expected PostgREST select:
  ///   `select('*, clan_members(user_id, role), clan_invites(user_id)')`
  ///
  /// Both arrays are derived client-side from the embedded rows — the
  /// Postgres source of truth is normalized, the model is denormalized to
  /// match the existing UI's contract.
  factory ClanModel.fromSupabaseRow(Map<String, dynamic> d) {
    DateTime parseTs(Object? raw) =>
        DateTime.tryParse(raw?.toString() ?? '') ?? DateTime.now();

    final members =
        (d['clan_members'] as List<dynamic>? ?? const []).cast<Map>();
    final invites =
        (d['clan_invites'] as List<dynamic>? ?? const []).cast<Map>();

    final memberIds = members
        .map((m) => (m as Map<String, dynamic>)['user_id'] as String? ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
    final adminIds = members
        .where((m) => (m as Map<String, dynamic>)['role'] == 'admin')
        .map((m) => (m as Map<String, dynamic>)['user_id'] as String? ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
    final pendingInviteIds = invites
        .map((i) => (i as Map<String, dynamic>)['user_id'] as String? ?? '')
        .where((id) => id.isNotEmpty)
        .toList();

    return ClanModel(
      clanId: d['id'] as String? ?? '',
      name: d['name'] as String? ?? '',
      clanIdCode: d['clan_id_code'] as String? ?? '',
      captainId: d['captain_id'] as String? ?? '',
      adminIds: adminIds,
      memberIds: memberIds,
      pendingInviteIds: pendingInviteIds,
      totalClanXP: (d['total_clan_xp'] as num?)?.toInt() ?? 0,
      clanXp: (d['clan_xp'] as num?)?.toInt() ?? 0,
      activeBattleId: d['active_battle_id'] as String?,
      createdAt: parseTs(d['created_at']),
      maxMembers: (d['max_members'] as num?)?.toInt() ?? 10,
    );
  }}
