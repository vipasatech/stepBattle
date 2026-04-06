import 'package:cloud_firestore/cloud_firestore.dart';

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

  factory UserMissionProgress.fromFirestore(
      DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data()!;
    return UserMissionProgress(
      id: doc.id,
      userId: d['userId'] as String? ?? '',
      missionId: d['missionId'] as String? ?? '',
      currentValue: d['currentValue'] as int? ?? 0,
      targetValue: d['targetValue'] as int? ?? 0,
      isCompleted: d['isCompleted'] as bool? ?? false,
      completedAt: (d['completedAt'] as Timestamp?)?.toDate(),
      periodStart: d['periodStart'] as String? ?? '',
    );
  }

  Map<String, dynamic> toFirestore() => {
        'userId': userId,
        'missionId': missionId,
        'currentValue': currentValue,
        'targetValue': targetValue,
        'isCompleted': isCompleted,
        'completedAt':
            completedAt != null ? Timestamp.fromDate(completedAt!) : null,
        'periodStart': periodStart,
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
