import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../config/constants.dart';
import '../models/mission_model.dart';
import '../models/step_log_model.dart';
import 'mission_service.dart';
import 'xp_service.dart';

/// Syncs step data between local health store and Firestore.
/// When steps change, propagates to:
///   - step_logs                        (source of truth)
///   - users.totalStepsAllTime          (lifetime counter)
///   - user_mission_progress (step)     (daily + weekly step missions)
///   - battles.participants[me].currentSteps  (live battle score)
///   - clans/members/{uid}.stepsToday   (clan dashboard)
class StepService {
  final FirebaseFirestore _firestore;
  final MissionService _missionService;
  final XPService _xpService;

  StepService({
    FirebaseFirestore? firestore,
    MissionService? missionService,
    XPService? xpService,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _missionService = missionService ?? MissionService(),
        _xpService = xpService ?? XPService();

  CollectionReference<Map<String, dynamic>> get _stepLogs =>
      _firestore.collection('step_logs');

  CollectionReference<Map<String, dynamic>> get _users =>
      _firestore.collection('users');

  CollectionReference<Map<String, dynamic>> get _progress =>
      _firestore.collection('user_mission_progress');

  CollectionReference<Map<String, dynamic>> get _battles =>
      _firestore.collection('battles');

  CollectionReference<Map<String, dynamic>> get _clans =>
      _firestore.collection('clans');

  // ---------------------------------------------------------------------------
  // MAIN SYNC — writes step_logs + propagates to all dependents
  // ---------------------------------------------------------------------------

  Future<void> syncSteps({
    required String userId,
    required int steps,
    required String source,
  }) async {
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final docId = '${userId}_$today';
    final calories = (steps * AppConstants.caloriesPerStep).round();

    // 1. Upsert step_logs and update users.totalStepsAllTime (delta-based)
    await _writeStepLog(
      userId: userId,
      docId: docId,
      today: today,
      steps: steps,
      calories: calories,
      source: source,
    );

    // 2. Award XP for step milestones (drip + daily goal)
    await _awardStepXP(userId: userId, todaySteps: steps, today: today);

    // 3. Fan out to dependents (safe to run in parallel)
    await Future.wait([
      _propagateToMissions(userId, steps),
      _propagateToActiveBattles(userId, steps),
      _propagateToClan(userId, steps),
    ]);
  }

  // ---------------------------------------------------------------------------
  // XP drip: +10 XP per 1000 steps crossed today + daily goal bonus
  // ---------------------------------------------------------------------------

  Future<void> _awardStepXP({
    required String userId,
    required int todaySteps,
    required String today,
  }) async {
    final userDoc = await _users.doc(userId).get();
    if (!userDoc.exists) return;
    final data = userDoc.data()!;

    final lastDate = data['lastStepXPDate'] as String? ?? '';
    final lastThreshold =
        lastDate == today ? (data['lastStepXPThreshold'] as int? ?? 0) : 0;
    final dailyGoal = data['dailyStepGoal'] as int? ?? 8000;
    final goalAwardedDate = data['dailyGoalXPAwardedDate'] as String?;

    final currentThreshold = todaySteps ~/ 1000; // e.g. 1158 → 1
    int xpToAward = 0;

    // Drip XP: award for each new 1000-step threshold crossed today
    if (currentThreshold > lastThreshold) {
      final newThresholds = currentThreshold - lastThreshold;
      xpToAward += newThresholds * AppConstants.xpPer1000Steps;
    }

    // Daily goal bonus: +75 XP once when crossing the daily goal
    final shouldAwardGoal =
        todaySteps >= dailyGoal && goalAwardedDate != today;
    if (shouldAwardGoal) {
      xpToAward += AppConstants.xpDailyGoalReached;
    }

    if (xpToAward == 0 && lastDate == today) return;

    // Update user doc with new threshold + goal-awarded marker
    final updates = <String, dynamic>{
      'lastStepXPThreshold': currentThreshold,
      'lastStepXPDate': today,
    };
    if (shouldAwardGoal) {
      updates['dailyGoalXPAwardedDate'] = today;
    }
    await _users.doc(userId).update(updates);

    // Award XP (atomic increment + level recalc inside XPService)
    if (xpToAward > 0) {
      await _xpService.awardXP(userId: userId, amount: xpToAward);
    }
  }

  Future<void> _writeStepLog({
    required String userId,
    required String docId,
    required String today,
    required int steps,
    required int calories,
    required String source,
  }) async {
    // Read existing to compute delta
    final existing = await _stepLogs.doc(docId).get();
    final previousSteps =
        existing.exists ? (existing.data()?['stepCount'] as int? ?? 0) : 0;
    final delta = steps - previousSteps;

    final log = StepLogModel(
      logId: docId,
      userId: userId,
      date: today,
      stepCount: steps,
      calories: calories,
      source: source,
      syncedAt: DateTime.now(),
    );

    await _stepLogs.doc(docId).set(log.toFirestore(), SetOptions(merge: true));

    if (delta > 0) {
      await _users.doc(userId).update({
        'totalStepsAllTime': FieldValue.increment(delta),
        'lastActiveAt': Timestamp.now(),
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Propagation: missions
  // ---------------------------------------------------------------------------

  Future<void> _propagateToMissions(String userId, int todaySteps) async {
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final weekStart = _weekStart();

    // Fetch mission definitions
    final daily = await _missionService.getDailyMissions();
    final weekly = await _missionService.getWeeklyMissions();

    final weeklyTotal = await getWeeklyTotal(userId);

    // Daily step missions
    for (final m in daily.where((m) => m.category == MissionCategory.steps)) {
      await _upsertProgress(
        userId: userId,
        mission: m,
        currentValue: todaySteps,
        periodStart: today,
      );
    }

    // Weekly step missions
    for (final m in weekly.where((m) => m.category == MissionCategory.steps)) {
      await _upsertProgress(
        userId: userId,
        mission: m,
        currentValue: weeklyTotal,
        periodStart: weekStart,
      );
    }
  }

  /// Upsert progress doc. If mission newly completes, award XP.
  Future<void> _upsertProgress({
    required String userId,
    required MissionModel mission,
    required int currentValue,
    required String periodStart,
  }) async {
    final docId = '${userId}_${mission.missionId}_$periodStart';
    final ref = _progress.doc(docId);

    final existing = await ref.get();
    final wasCompleted = existing.exists
        ? (existing.data()?['isCompleted'] as bool? ?? false)
        : false;
    final nowCompleted = currentValue >= mission.targetValue;

    await ref.set({
      'userId': userId,
      'missionId': mission.missionId,
      'currentValue': currentValue,
      'targetValue': mission.targetValue,
      'isCompleted': nowCompleted,
      'completedAt': nowCompleted ? Timestamp.now() : null,
      'periodStart': periodStart,
    }, SetOptions(merge: true));

    // Award XP on transition false → true
    if (!wasCompleted && nowCompleted) {
      await _xpService.awardXP(userId: userId, amount: mission.xpReward);
    }
  }

  // ---------------------------------------------------------------------------
  // Propagation: active battles
  // ---------------------------------------------------------------------------

  Future<void> _propagateToActiveBattles(String userId, int steps) async {
    final snap = await _battles
        .where('status', isEqualTo: 'active')
        .get();

    for (final doc in snap.docs) {
      final data = doc.data();
      final participants = (data['participants'] as List<dynamic>? ?? [])
          .map((p) => Map<String, dynamic>.from(p as Map))
          .toList();

      final myIndex = participants.indexWhere((p) => p['userId'] == userId);
      if (myIndex == -1) continue;

      participants[myIndex]['currentSteps'] = steps;
      await doc.reference.update({'participants': participants});
    }
  }

  // ---------------------------------------------------------------------------
  // Propagation: clan member stepsToday
  // ---------------------------------------------------------------------------

  Future<void> _propagateToClan(String userId, int steps) async {
    final userDoc = await _users.doc(userId).get();
    if (!userDoc.exists) return;
    final clanId = userDoc.data()?['clanId'] as String?;
    if (clanId == null || clanId.isEmpty) return;

    // Use set + merge so this works even if the member subdoc somehow got out of sync.
    await _clans
        .doc(clanId)
        .collection('members')
        .doc(userId)
        .set({'stepsToday': steps}, SetOptions(merge: true));
  }

  // ---------------------------------------------------------------------------
  // Read helpers
  // ---------------------------------------------------------------------------

  Stream<StepLogModel?> watchTodaySteps(String userId) {
    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    final docId = '${userId}_$today';
    return _stepLogs.doc(docId).snapshots().map((doc) {
      if (!doc.exists) return null;
      return StepLogModel.fromFirestore(doc);
    });
  }

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

  Future<int> getWeeklyTotal(String userId) async {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final start = DateTime(monday.year, monday.month, monday.day);

    final logs = await getStepHistory(userId: userId, from: start, to: now);
    return logs.fold<int>(0, (total, log) => total + log.stepCount);
  }

  static String _weekStart() {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    return DateFormat('yyyy-MM-dd').format(monday);
  }
}
