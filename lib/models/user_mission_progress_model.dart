class UserMissionProgress {
  final String id; // document ID: "{userId}_{missionId}_{periodStart}"
  final String userId;
  final String missionId;
  final int currentValue;
  final int targetValue;
  final bool isCompleted;
  final DateTime? completedAt;
  final String periodStart; // yyyy-MM-dd

  const UserMissionProgress({
    required this.id,
    required this.userId,
    required this.missionId,
    this.currentValue = 0,
    required this.targetValue,
    this.isCompleted = false,
    this.completedAt,
    required this.periodStart,
  });

  double get progressFraction {
    if (targetValue <= 0) return 0;
    return (currentValue / targetValue).clamp(0.0, 1.0);
  }

  String get progressLabel {
    if (targetValue >= 1000) {
      return '${_fmt(currentValue)} / ${_fmt(targetValue)}';
    }
    return '$currentValue / $targetValue';
  }

  String get percentLabel => '${(progressFraction * 100).round()}%';
  /// Build from a Supabase `public.user_mission_progress` row. The composite
  /// primary key (user_id, mission_id, period_start) is mirrored into [id]
  /// using the same "{uid}_{mission}_{period}" convention the Firestore
  /// path used — so the rest of the UI keeps working unchanged.
  factory UserMissionProgress.fromSupabaseRow(Map<String, dynamic> d) {
    final userId = d['user_id'] as String? ?? '';
    final missionId = d['mission_id'] as String? ?? '';
    final periodStart = d['period_start'] as String? ?? '';
    return UserMissionProgress(
      id: '${userId}_${missionId}_$periodStart',
      userId: userId,
      missionId: missionId,
      currentValue: (d['current_value'] as num?)?.toInt() ?? 0,
      targetValue: (d['target_value'] as num?)?.toInt() ?? 0,
      isCompleted: d['is_completed'] as bool? ?? false,
      completedAt:
          DateTime.tryParse(d['completed_at']?.toString() ?? ''),
      periodStart: periodStart,
    );
  }
  /// Payload for `public.user_mission_progress` upsert.
  Map<String, dynamic> toSupabaseRow() => {
        'user_id': userId,
        'mission_id': missionId,
        'period_start': periodStart,
        'current_value': currentValue,
        'target_value': targetValue,
        'is_completed': isCompleted,
        'completed_at': completedAt?.toUtc().toIso8601String(),
      };

  /// Empty progress placeholder for a mission with no document yet.
  factory UserMissionProgress.empty({
    required String userId,
    required String missionId,
    required int targetValue,
    required String periodStart,
  }) {
    return UserMissionProgress(
      id: '${userId}_${missionId}_$periodStart',
      userId: userId,
      missionId: missionId,
      targetValue: targetValue,
      periodStart: periodStart,
    );
  }

  static String _fmt(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}
