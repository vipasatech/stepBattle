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

  /// Build from a Supabase `clan_battles` row joined with its
  /// `clan_battle_teams` rows (PostgREST nested select).
  ///
  /// Expected select shape:
  ///   `select('*, clan_battle_teams(*)')`
  factory ClanBattleModel.fromSupabaseRow(Map<String, dynamic> d) {
    DateTime parseTs(Object? raw) =>
        DateTime.tryParse(raw?.toString() ?? '') ?? DateTime.now();

    final teams =
        (d['clan_battle_teams'] as List<dynamic>? ?? const []).cast<Map>();
    ClanBattleTeam teamFor(String label) {
      final t = teams.firstWhere(
        (t) => (t as Map<String, dynamic>)['team_label'] == label,
        orElse: () => <String, dynamic>{},
      );
      if (t.isEmpty) {
        return const ClanBattleTeam(clanId: '', clanName: '');
      }
      final m = t as Map<String, dynamic>;
      return ClanBattleTeam(
        clanId: m['clan_id'] as String? ?? '',
        clanName: m['clan_name'] as String? ?? '',
        totalSteps: (m['total_steps'] as num?)?.toInt() ?? 0,
      );
    }

    return ClanBattleModel(
      clanBattleId: d['id'] as String? ?? '',
      status: _parseStatus(d['status'] as String? ?? 'pending'),
      clanA: teamFor('A'),
      clanB: teamFor('B'),
      startTime: parseTs(d['start_time']),
      endTime: parseTs(d['end_time']),
      durationDays: (d['duration_days'] as num?)?.toInt() ?? 3,
      battleType: d['battle_type'] as String? ?? 'steps',
      xpPerMember: (d['xp_per_member'] as num?)?.toInt() ?? 300,
      winnerClanId: d['winner_clan_id'] as String?,
    );
  }
  static ClanBattleStatus _parseStatus(String s) => switch (s) {
        'active' => ClanBattleStatus.active,
        'completed' => ClanBattleStatus.completed,
        _ => ClanBattleStatus.pending,
      };
}
