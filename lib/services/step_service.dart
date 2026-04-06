import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../config/constants.dart';
import '../models/step_log_model.dart';

/// Syncs step data between local health store and Firestore.
/// Handles writing step_logs, updating user totals, and querying history.
class StepService {
  final FirebaseFirestore _firestore;

  StepService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _stepLogs =>
      _firestore.collection('step_logs');

  CollectionReference<Map<String, dynamic>> get _users =>
      _firestore.collection('users');

  // ---------------------------------------------------------------------------
  // Write / sync
  // ---------------------------------------------------------------------------

  /// Sync today's step count from device to Firestore.
  /// Uses upsert pattern — one document per user per day.
  Future<void> syncSteps({
    required String userId,
    required int steps,
    required String source,
  }) async {
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final docId = '${userId}_$today';
    final calories = (steps * AppConstants.caloriesPerStep).round();

    final logData = StepLogModel(
      logId: docId,
      userId: userId,
      date: today,
      stepCount: steps,
      calories: calories,
      source: source,
      syncedAt: DateTime.now(),
    );

    // Upsert the daily step log
    await _stepLogs.doc(docId).set(
          logData.toFirestore(),
          SetOptions(merge: true),
        );

    // Update user's totalStepsAllTime + lastActiveAt
    // We need to compute the delta from previous sync
    await _updateUserStepTotals(userId, steps, today);
  }

  /// Compute delta and update user totals.
  Future<void> _updateUserStepTotals(
      String userId, int currentSteps, String today) async {
    final docRef = _stepLogs.doc('${userId}_$today');
    final existing = await docRef.get();

    int previousSteps = 0;
    if (existing.exists) {
      previousSteps = existing.data()?['stepCount'] as int? ?? 0;
    }

    final delta = currentSteps - previousSteps;
    if (delta > 0) {
      await _users.doc(userId).update({
        'totalStepsAllTime': FieldValue.increment(delta),
        'lastActiveAt': Timestamp.now(),
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Read
  // ---------------------------------------------------------------------------

  /// Stream today's step log for a user (real-time updates from syncs).
  Stream<StepLogModel?> watchTodaySteps(String userId) {
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final docId = '${userId}_$today';
    return _stepLogs.doc(docId).snapshots().map((doc) {
      if (!doc.exists) return null;
      return StepLogModel.fromFirestore(doc);
    });
  }

  /// Get step logs for a date range (for weekly/monthly stats).
  Future<List<StepLogModel>> getStepHistory({
    required String userId,
    required DateTime from,
    required DateTime to,
  }) async {
    final fmt = DateFormat('yyyy-MM-dd');
    final fromStr = fmt.format(from);
    final toStr = fmt.format(to);

    final query = await _stepLogs
        .where('userId', isEqualTo: userId)
        .where('date', isGreaterThanOrEqualTo: fromStr)
        .where('date', isLessThanOrEqualTo: toStr)
        .orderBy('date', descending: true)
        .get();

    return query.docs.map((doc) => StepLogModel.fromFirestore(doc)).toList();
  }

  /// Get total steps for a specific date from Firestore.
  Future<int> getDailyTotal({
    required String userId,
    required DateTime date,
  }) async {
    final dateStr = DateFormat('yyyy-MM-dd').format(date);
    final docId = '${userId}_$dateStr';
    final doc = await _stepLogs.doc(docId).get();
    if (!doc.exists) return 0;
    return doc.data()?['stepCount'] as int? ?? 0;
  }

  /// Get the total steps for this week (Mon–Sun).
  Future<int> getWeeklyTotal(String userId) async {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final start = DateTime(monday.year, monday.month, monday.day);

    final logs = await getStepHistory(userId: userId, from: start, to: now);
    return logs.fold<int>(0, (total, log) => total + log.stepCount);
  }
}
