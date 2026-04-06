import 'package:cloud_firestore/cloud_firestore.dart';

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

  factory StepLogModel.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    return StepLogModel(
      logId: doc.id,
      userId: data['userId'] as String? ?? '',
      date: data['date'] as String? ?? '',
      stepCount: data['stepCount'] as int? ?? 0,
      calories: data['calories'] as int? ?? 0,
      source: data['source'] as String? ?? '',
      syncedAt: (data['syncedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'userId': userId,
      'date': date,
      'stepCount': stepCount,
      'calories': calories,
      'source': source,
      'syncedAt': Timestamp.fromDate(syncedAt),
    };
  }

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
