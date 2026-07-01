import 'package:cloud_firestore/cloud_firestore.dart';

class BattleParticipant {
  final String userId;
  final String displayName;
  final String? avatarURL;

  /// Steps inside the battle window (derived from lifetime totals).
  /// `total_steps_all_time - start_steps_baseline` when active,
  /// `end_steps_baseline - start_steps_baseline` when frozen.
  final int currentSteps;

  /// `total_steps_all_time` snapshot at battle activation. Set when the
  /// battle flips from pending→active and stays put for the lifetime of
  /// the battle.
  final int? startStepsBaseline;

  /// `total_steps_all_time` snapshot at battle completion. Set when the
  /// battle flips from active→completed; freezes [currentSteps].
  final int? endStepsBaseline;

  final bool isWinner;

  /// Per-participant invite state. Battle is `pending` until every
  /// participant is `accepted`; if any one is `rejected` the battle ends
  /// (1v1) or is removed for that user (group).
  final ParticipantInviteStatus inviteStatus;

  /// Team label for team battles ('A'/'B'/'C'/'D'). Null for 1v1 / group.
  final String? teamLabel;

  /// Snapshot of the user's `profiles.battle_avatar_id` at the moment they
  /// joined this battle. Null for legacy rows from before migration 0019 —
  /// the renderer falls back to the default avatar in that case (see
  /// [Avatar.byId]). Snapshotting prevents a later avatar change from
  /// retroactively swapping the runner on historical battle screens.
  final String? battleAvatarId;

  const BattleParticipant({
    required this.userId,
    required this.displayName,
    this.avatarURL,
    this.currentSteps = 0,
    this.startStepsBaseline,
    this.endStepsBaseline,
    this.isWinner = false,
    this.inviteStatus = ParticipantInviteStatus.pending,
    this.teamLabel,
    this.battleAvatarId,
  });

  /// Firestore-style nested map (still used by [BattleModel.toFirestore]).
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

  /// Build from a Supabase `public.battle_participants` row (snake_case).
  factory BattleParticipant.fromSupabaseRow(Map<String, dynamic> d) {
    return BattleParticipant(
      userId: d['user_id'] as String? ?? '',
      displayName: d['display_name'] as String? ?? '',
      avatarURL: d['avatar_url'] as String?,
      currentSteps: (d['current_steps'] as num?)?.toInt() ?? 0,
      startStepsBaseline: (d['start_steps_baseline'] as num?)?.toInt(),
      endStepsBaseline: (d['end_steps_baseline'] as num?)?.toInt(),
      isWinner: d['is_winner'] as bool? ?? false,
      inviteStatus: ParticipantInviteStatus.fromString(
          d['invite_status'] as String? ?? 'pending'),
      teamLabel: d['team_label'] as String?,
      battleAvatarId: d['battle_avatar_id'] as String?,
    );
  }
}

enum ParticipantInviteStatus {
  pending,
  accepted,
  rejected;

  static ParticipantInviteStatus fromString(String s) => switch (s) {
        'accepted' => ParticipantInviteStatus.accepted,
        'rejected' => ParticipantInviteStatus.rejected,
        _ => ParticipantInviteStatus.pending,
      };
}

/// Battle lifecycle:
///   • pending   — at least one invitee hasn't responded
///   • scheduled — all accepted, waiting for [BattleModel.startTime] to arrive
///   • active    — start_time has arrived, steps are being counted
///   • completed — end_time has passed, scores are frozen
///   • cancelled — aborted before activation (1v1 reject, creator delete)
enum BattleStatus { pending, scheduled, active, completed, cancelled }

/// Battle visibility. Public battles surface in Battles → Discover and can be
/// joined by anyone using the join code (no invite required). Private battles
/// are invite-or-code-only.
enum BattleVisibility { private, public }

/// Battle topology.
///   • oneVsOne — exactly 2 individuals.
///   • group    — 2–10 individuals, free-for-all (the user-facing label is
///                "Multi-player" now; the enum value is kept stable for
///                schema compatibility).
///   • team     — 2–4 teams, up to 10 participants total. Scoring sums each
///                team's `current_steps`; winning team's members all get
///                `xp_reward × team_size` XP.
enum BattleType { oneVsOne, group, team }

class BattleModel {
  final String battleId;
  final BattleType type;
  final BattleStatus status;
  final List<BattleParticipant> participants;

  /// User IDs invited but not yet rejected — derived from
  /// `battle_participants` rows where `invite_status != 'rejected'`. Kept
  /// as a denormalised getter so existing UI keeps compiling unchanged.
  List<String> get invitedUserIds => participants
      .where((p) => p.inviteStatus != ParticipantInviteStatus.rejected)
      .map((p) => p.userId)
      .toList();

  /// User IDs who accepted the invite — derived (was a top-level field
  /// in the Firestore schema).
  List<String> get acceptedUserIds => participants
      .where((p) => p.inviteStatus == ParticipantInviteStatus.accepted)
      .map((p) => p.userId)
      .toList();

  final DateTime startTime;
  final DateTime endTime;
  final int durationDays;
  final int xpReward;

  /// Per-participant XP stake (migration 0016). Zero for legacy
  /// free-play battles, ≥100 for stake battles. Total pot is
  /// `stakeXp × acceptedParticipantCount` and is split by
  /// `settle_stake_battle()` on the server.
  final int stakeXp;

  final String? winnerId;
  final String createdBy;

  /// When the invite was created. Used for 24h auto-expire check.
  final DateTime createdAt;

  /// Non-null when this battle is one instance of a recurring **Daily**
  /// series (see `battle_series` table + migration 0014). The cron spawns
  /// the next day's instance with the same series_id; the creator can stop
  /// the series via `BattleService.stopSeries`.
  final String? seriesId;

  /// Visibility (migration 0015). Public battles surface in Battles →
  /// Discover and can be joined by anyone via the join code; private battles
  /// are invite-or-code-only.
  final BattleVisibility visibility;

  /// 6-char shareable code (e.g. `A4X9KP`). Anyone with the code can join a
  /// public battle and pasting it works for private too. Set on every battle
  /// going forward (migration 0015 backfilled existing rows).
  final String? joinCode;

  /// For team battles: how many teams (2–4). Null otherwise.
  final int? teamCount;

  /// For team battles: label → display name override (creator-set).
  /// Defaults to "Team A" / "Team B" if missing.
  final Map<String, String> teamNames;

  const BattleModel({
    required this.battleId,
    required this.type,
    required this.status,
    required this.participants,
    required this.startTime,
    required this.endTime,
    required this.durationDays,
    required this.xpReward,
    this.stakeXp = 0,
    this.winnerId,
    required this.createdBy,
    required this.createdAt,
    this.seriesId,
    this.visibility = BattleVisibility.private,
    this.joinCode,
    this.teamCount,
    this.teamNames = const {},
  });

  /// Display name for a team label (e.g. 'A' → 'Crimson Wolves' or 'Team A').
  String teamDisplayName(String label) =>
      teamNames[label] ?? 'Team $label';

  /// Sum of `currentSteps` for all accepted participants in [label].
  int teamSteps(String label) {
    var sum = 0;
    for (final p in participants) {
      if (p.teamLabel != label) continue;
      if (p.inviteStatus != ParticipantInviteStatus.accepted) continue;
      sum += p.currentSteps;
    }
    return sum;
  }

  /// Distinct team labels in this battle, sorted ('A','B','C','D').
  List<String> get teamLabels {
    final set = <String>{
      for (final p in participants)
        if (p.teamLabel != null) p.teamLabel!,
    };
    final out = set.toList()..sort();
    return out;
  }

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
      createdAt:
          (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  /// Build from a Supabase `public.battles` row joined with its
  /// `battle_participants` rows (via a nested PostgREST select).
  factory BattleModel.fromSupabaseRow(Map<String, dynamic> d) {
    DateTime parseTs(Object? raw) =>
        DateTime.tryParse(raw?.toString() ?? '') ?? DateTime.now();

    final partsRaw =
        (d['battle_participants'] as List<dynamic>? ?? const []);
    final participants = partsRaw
        .map((p) => BattleParticipant.fromSupabaseRow(
            p as Map<String, dynamic>))
        .toList();

    final teamsRaw =
        (d['battle_teams'] as List<dynamic>? ?? const []);
    final teamNames = <String, String>{};
    for (final t in teamsRaw) {
      final m = t as Map<String, dynamic>;
      final label = m['team_label'] as String?;
      final name = m['team_name'] as String?;
      if (label != null && name != null && name.isNotEmpty) {
        teamNames[label] = name;
      }
    }

    final start = parseTs(d['start_time']);
    final end = parseTs(d['end_time']);
    final duration = end.difference(start);

    return BattleModel(
      battleId: d['id'] as String? ?? '',
      type: _parseType(d['type'] as String? ?? '1v1'),
      status: _parseStatus(d['status'] as String? ?? 'pending'),
      participants: participants,
      startTime: start,
      endTime: end,
      durationDays:
          duration.inHours >= 24 ? duration.inDays : 1,
      xpReward: (d['xp_reward'] as num?)?.toInt() ?? 200,
      stakeXp: (d['stake_xp'] as num?)?.toInt() ?? 0,
      winnerId: d['winner_id'] as String?,
      createdBy: d['created_by'] as String? ?? '',
      createdAt: parseTs(d['created_at']),
      seriesId: d['series_id'] as String?,
      visibility: (d['visibility'] as String?) == 'public'
          ? BattleVisibility.public
          : BattleVisibility.private,
      joinCode: d['join_code'] as String?,
      teamCount: (d['team_count'] as num?)?.toInt(),
      teamNames: teamNames,
    );
  }

  Map<String, dynamic> toFirestore() => {
        'type': BattleModel.typeToString(type),
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
  bool isPendingInviteFor(String userId) {
    if (status != BattleStatus.pending) return false;
    final p = participantFor(userId);
    return p != null && p.inviteStatus == ParticipantInviteStatus.pending;
  }

  /// True when this battle is the "Daily • Today" shape: ends at the local
  /// 23:59 of the same day it started. Used by the UI to badge daily battles.
  bool get isDaily {
    final s = startTime.toLocal();
    final e = endTime.toLocal();
    return s.year == e.year &&
        s.month == e.month &&
        s.day == e.day &&
        e.hour == 23 &&
        e.minute >= 59;
  }

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

  static BattleType _parseType(String s) => switch (s) {
        'group' => BattleType.group,
        'team' => BattleType.team,
        _ => BattleType.oneVsOne,
      };

  /// Inverse of [_parseType]; used by writers that need the DB string.
  static String typeToString(BattleType t) => switch (t) {
        BattleType.oneVsOne => '1v1',
        BattleType.group => 'group',
        BattleType.team => 'team',
      };

  static BattleStatus _parseStatus(String s) => switch (s) {
        'scheduled' => BattleStatus.scheduled,
        'active' => BattleStatus.active,
        'completed' => BattleStatus.completed,
        'cancelled' => BattleStatus.cancelled,
        _ => BattleStatus.pending,
      };
}
