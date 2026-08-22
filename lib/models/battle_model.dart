class BattleParticipant {
  final String userId;
  final String displayName;

  /// Snapshot of the user's `profiles.preferred_name` at the moment
  /// they joined this battle. Nullable — legacy rows created before
  /// migration 0025 leave it null, and users who never set a preferred
  /// name also leave it null; the [friendlyName] getter falls back to
  /// [displayName] in both cases.
  final String? preferredName;

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

  /// For daily-series instances only (migration 0046): the LOCAL DATE
  /// (in this participant's timezone) that they are competing on for
  /// this specific instance. YYYY-MM-DD. Server settlement looks up
  /// `step_logs` by (user_id, date) using this value.
  ///
  /// Null on non-daily battles AND on invitees whose day-1 hasn't
  /// arrived yet in their tz (they entered the series after the
  /// creator's day 1 started — per the "late joiners skip day 1" rule).
  /// The UI reads it to disambiguate "competing today, 0 steps" from
  /// "not competing today, waiting for local midnight".
  final String? competingDate;

  const BattleParticipant({
    required this.userId,
    required this.displayName,
    this.preferredName,
    this.avatarURL,
    this.currentSteps = 0,
    this.startStepsBaseline,
    this.endStepsBaseline,
    this.isWinner = false,
    this.inviteStatus = ParticipantInviteStatus.pending,
    this.teamLabel,
    this.battleAvatarId,
    this.competingDate,
  });

  /// Rendered name — prefers [preferredName] when the user set a
  /// nickname at battle-creation time, otherwise falls back to
  /// [displayName]. Same fallback contract as `UserModel.friendlyName`.
  String get friendlyName {
    final trimmed = preferredName?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    return displayName;
  }

  /// Nested-map deserializer — used only by the client-side battle
  /// deep-copy path; server payloads take the `fromSupabaseRow` route.
  factory BattleParticipant.fromMap(Map<String, dynamic> map) {
    return BattleParticipant(
      userId: map['userId'] as String? ?? '',
      displayName: map['displayName'] as String? ?? '',
      preferredName: map['preferredName'] as String?,
      avatarURL: map['avatarURL'] as String?,
      currentSteps: map['currentSteps'] as int? ?? 0,
      isWinner: map['isWinner'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() => {
        'userId': userId,
        'displayName': displayName,
        'preferredName': preferredName,
        'avatarURL': avatarURL,
        'currentSteps': currentSteps,
        'isWinner': isWinner,
      };

  /// Build from a Supabase `public.battle_participants` row (snake_case).
  factory BattleParticipant.fromSupabaseRow(Map<String, dynamic> d) {
    return BattleParticipant(
      userId: d['user_id'] as String? ?? '',
      displayName: d['display_name'] as String? ?? '',
      preferredName: d['preferred_name'] as String?,
      avatarURL: d['avatar_url'] as String?,
      currentSteps: (d['current_steps'] as num?)?.toInt() ?? 0,
      startStepsBaseline: (d['start_steps_baseline'] as num?)?.toInt(),
      endStepsBaseline: (d['end_steps_baseline'] as num?)?.toInt(),
      isWinner: d['is_winner'] as bool? ?? false,
      inviteStatus: ParticipantInviteStatus.fromString(
          d['invite_status'] as String? ?? 'pending'),
      teamLabel: d['team_label'] as String?,
      battleAvatarId: d['battle_avatar_id'] as String?,
      competingDate: d['competing_date'] as String?,
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

  /// When a pending battle auto-resolves (auto-start or auto-cancel).
  /// Populated by the server trigger in Migration 0040:
  ///   • Immediate mode (start_time ≤ createdAt + 1h) → createdAt + 24h
  ///   • Scheduled mode (start_time  > createdAt + 1h) → start_time
  /// Null for non-pending rows and for rows written before Migration 0040
  /// landed (client tolerates absence — UI just skips the countdown).
  final DateTime? pendingExpiresAt;

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
    this.pendingExpiresAt,
  });

  /// True when the creator picked a start time more than 1h out from
  /// creation — i.e. "start next Sunday" rather than "start now". The
  /// threshold matches [setPendingExpiresAt] on the server (Migration 0040).
  /// Used by the pending-card countdown widget to pick the display flavour
  /// ("Expires in Xh" vs "Starts in Xh" / an absolute date) and by
  /// [battleService] to decide whether a 1v1 acceptance should snap the
  /// window to now vs honour the scheduled slot.
  bool get isScheduled =>
      startTime.isAfter(createdAt.add(const Duration(hours: 1)));

  bool get isImmediate => !isScheduled;

  /// Remaining time until the pending deadline fires. Null when the
  /// battle isn't pending or the server hasn't stamped the column
  /// (pre-Migration-0040 row).
  Duration? get timeUntilPendingExpiry {
    final t = pendingExpiresAt;
    if (t == null) return null;
    return t.difference(DateTime.now());
  }

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
    // Team battles: the authoritative team count is `battles.team_count`
    // (2..4). Derive labels A..N from it so freshly-created teams show
    // up even before anyone is assigned to them. Falls back to
    // participant-derived labels only when team_count is missing (older
    // battle rows / non-team battles that got here somehow).
    final tc = teamCount;
    if (tc != null && tc >= 2 && tc <= 4) {
      return List.generate(
        tc,
        (i) => String.fromCharCode('A'.codeUnitAt(0) + i),
      );
    }
    final set = <String>{
      for (final p in participants)
        if (p.teamLabel != null) p.teamLabel!,
    };
    return set.toList()..sort();
  }

  /// Net XP change for [userId] from the stake pot on a completed
  /// battle. Every accepted participant paid [stakeXp] at accept time
  /// (see `battle_service._chargeStake`); the winner (or winning-team
  /// members split) takes the pot back via `settle_stake_battle()`.
  /// This returns what that user's total_xp ACTUALLY moved by:
  ///   • non-participant / free-play (stakeXp = 0)        → 0
  ///   • TIED battle (no winner selected)                 → 0 (server
  ///     refunds everyone via `battle_refund` credit — net movement
  ///     is 0 per user)
  ///   • solo winner (1v1 / group)                        → pot − stake
  ///   • team winner (member of winning team)             → (pot / teamSize) − stake
  ///   • anyone else who paid a stake                     → −stake
  ///
  /// UI reads this so completed-battle cards can show the honest delta
  /// (e.g. `-100 XP LOST` on a loss instead of the misleading `+0 XP`
  /// that made the tester think stakes weren't being deducted, or
  /// `-100 XP LOST` on a tie which is also wrong).
  int netStakeXpFor(String userId) {
    if (stakeXp <= 0) return 0;
    final accepted = participants
        .where((p) => p.inviteStatus == ParticipantInviteStatus.accepted)
        .toList();
    if (accepted.isEmpty) return 0;
    final me = accepted.where((p) => p.userId == userId);
    if (me.isEmpty) return 0;
    final pot = stakeXp * accepted.length;

    // Tie detection. Server (`settle_stake_battle`, migration 0017)
    // leaves winner_id NULL for 1v1/group ties and marks no
    // `is_winner` participant on team ties, then refunds every staker
    // via a `battle_refund` credit. Net movement is 0 for everyone —
    // we surface that as `+0 XP` on the card, not `-stake XP LOST`.
    final anyoneWon = accepted.any((p) => p.isWinner) || winnerId != null;
    if (!anyoneWon) return 0;

    if (type == BattleType.team) {
      // Team ties handled above. For team wins, `is_winner` is stamped
      // per-member of the winning team (server-side) even though
      // battles.winner_id stays NULL for team battles. Pot is split
      // equally among winning-team members.
      final winners = accepted.where((p) => p.isWinner).toList();
      if (winners.isEmpty) return 0; // shouldn't happen given anyoneWon
      final iAmWinner = winners.any((p) => p.userId == userId);
      if (iAmWinner) {
        return (pot ~/ winners.length) - stakeXp;
      }
      return -stakeXp;
    }

    // 1v1 / group: single winner takes the whole pot.
    if (winnerId == userId) return pot - stakeXp;
    return -stakeXp;
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
      pendingExpiresAt: d['pending_expires_at'] == null
          ? null
          : DateTime.tryParse(d['pending_expires_at'].toString()),
    );
  }
  /// True if this is a pending invite for the given user and they haven't responded.
  bool isPendingInviteFor(String userId) {
    if (status != BattleStatus.pending) return false;
    final p = participantFor(userId);
    return p != null && p.inviteStatus == ParticipantInviteStatus.pending;
  }

  /// True when this battle is part of a recurring daily series.
  /// Post migration 0046, `series_id != null` is the authoritative
  /// signal. The old start/end-time heuristic was replaced because
  /// daily-series instances now use nominal UTC start/end and per-user
  /// `competing_date` for the actual window — the heuristic was
  /// unreliable across timezones.
  bool get isDaily => seriesId != null;

  /// True if the invite has expired (>24h old and still pending).
  bool get isExpired {
    if (status != BattleStatus.pending) return false;
    return DateTime.now().difference(createdAt).inHours >= 24;
  }

  /// Get this user's participant entry.
  BattleParticipant? participantFor(String userId) {
    // Guard against empty string (auth still hydrating on cold-start).
    // Without this, callers could accidentally search for empty-id
    // participants and get null even when data is present.
    if (userId.isEmpty) return null;
    try {
      return participants.firstWhere((p) => p.userId == userId);
    } catch (_) {
      return null;
    }
  }

  /// Get the opponent in a 1v1 battle.
  ///
  /// Guards against `userId == ''` — otherwise `firstWhere((p) =>
  /// p.userId != '')` would match the FIRST participant (since every
  /// real userId is non-empty), i.e. the current user's own row would
  /// be returned as their "opponent". That produced the transient
  /// "You vs [own first name]" render on battle cards during the
  /// ~200ms auth-hydration window on cold-start (reported 2026-08-17).
  /// Empty-uid callers now get `null` → the card falls through to the
  /// `'Opponent'` placeholder in `_shortName`, which is at least
  /// truthful during the brief window.
  BattleParticipant? opponentFor(String userId) {
    if (userId.isEmpty) return null;
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
