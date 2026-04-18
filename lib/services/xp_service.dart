import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../config/constants.dart';

/// Handles XP awards and level-up detection.
/// Every award also updates `xpEarnedToday` so the Missions pill + any
/// daily-XP display has a single source of truth.
class XPService {
  final FirebaseFirestore _firestore;

  XPService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  /// Award XP to a user. Returns true if user levelled up.
  Future<bool> awardXP({
    required String userId,
    required int amount,
  }) async {
    if (amount <= 0) return false;

    final userRef = _firestore.collection('users').doc(userId);
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());

    return _firestore.runTransaction<bool>((tx) async {
      final snapshot = await tx.get(userRef);
      if (!snapshot.exists) return false;

      final data = snapshot.data()!;
      final oldXP = data['totalXP'] as int? ?? 0;
      final newXP = oldXP + amount;
      final oldLevel = AppConstants.levelForXP(oldXP);
      final newLevel = AppConstants.levelForXP(newXP);

      // Reset xpEarnedToday if the stored date is stale (new day)
      final storedDate = data['xpEarnedTodayDate'] as String? ?? '';
      final existingToday = storedDate == today
          ? (data['xpEarnedToday'] as int? ?? 0)
          : 0;

      tx.update(userRef, {
        'totalXP': newXP,
        'level': newLevel,
        'xpEarnedToday': existingToday + amount,
        'xpEarnedTodayDate': today,
      });

      return newLevel > oldLevel;
    });
  }

  /// Calculate XP earned from steps (10 XP per 1000 steps).
  int xpFromSteps(int steps) {
    return (steps ~/ 1000) * AppConstants.xpPer1000Steps;
  }

  /// Check if daily step goal was reached and award bonus XP.
  Future<bool> checkDailyGoalXP({
    required String userId,
    required int todaySteps,
    required int dailyGoal,
  }) async {
    if (todaySteps >= dailyGoal) {
      return awardXP(userId: userId, amount: AppConstants.xpDailyGoalReached);
    }
    return false;
  }
}
