class StepLogModel {
  final String logId;
  final String userId;
  final String date; // yyyy-MM-dd
  final int stepCount;
  final int calories;
  final String source; // "healthkit" | "healthconnect"
  final DateTime syncedAt;

  const StepLogModel({
    required this.logId,
    required this.userId,
    required this.date,
    required this.stepCount,
    required this.calories,
    required this.source,
    required this.syncedAt,
  });
  /// Build from a Supabase `public.step_logs` row.
  factory StepLogModel.fromSupabaseRow(Map<String, dynamic> data) {
    return StepLogModel(
      logId: data['id'] as String? ?? '',
      userId: data['user_id'] as String? ?? '',
      date: data['date'] as String? ?? '',
      stepCount: (data['step_count'] as num?)?.toInt() ?? 0,
      calories: (data['calories'] as num?)?.toInt() ?? 0,
      source: data['source'] as String? ?? '',
      syncedAt: DateTime.tryParse(data['synced_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }

  /// Payload for `public.step_logs` upsert (snake_case columns; ISO timestamps).
  /// Caller supplies user_id since it isn't on the model unless we set it.
  Map<String, dynamic> toSupabaseRow() => {
        'user_id': userId,
        'date': date,
        'step_count': stepCount,
        'calories': calories,
        'source': source,
        'synced_at': syncedAt.toUtc().toIso8601String(),
      };
  StepLogModel copyWith({
    int? stepCount,
    int? calories,
    DateTime? syncedAt,
  }) {
    return StepLogModel(
      logId: logId,
      userId: userId,
      date: date,
      stepCount: stepCount ?? this.stepCount,
      calories: calories ?? this.calories,
      source: source,
      syncedAt: syncedAt ?? this.syncedAt,
    );
  }
}
