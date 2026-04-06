import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../models/mission_model.dart';
import '../models/user_mission_progress_model.dart';

class MissionService {
  final FirebaseFirestore _firestore;

  MissionService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _missions =>
      _firestore.collection('missions');

  CollectionReference<Map<String, dynamic>> get _progress =>
      _firestore.collection('user_mission_progress');

  // ---------------------------------------------------------------------------
  // Mission definitions
  // ---------------------------------------------------------------------------

  /// Fetch daily mission definitions. Falls back to defaults if empty.
  Future<List<MissionModel>> getDailyMissions() async {
    final query =
        await _missions.where('type', isEqualTo: 'daily').get();
    if (query.docs.isEmpty) return MissionModel.defaultDaily;
    return query.docs.map((d) => MissionModel.fromFirestore(d)).toList();
  }

  /// Fetch weekly mission definitions. Falls back to defaults if empty.
  Future<List<MissionModel>> getWeeklyMissions() async {
    final query =
        await _missions.where('type', isEqualTo: 'weekly').get();
    if (query.docs.isEmpty) return MissionModel.defaultWeekly;
    return query.docs.map((d) => MissionModel.fromFirestore(d)).toList();
  }

  // ---------------------------------------------------------------------------
  // Progress
  // ---------------------------------------------------------------------------

  String _todayPeriod() => DateFormat('yyyy-MM-dd').format(DateTime.now());

  String _weekPeriod() {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    return DateFormat('yyyy-MM-dd').format(monday);
  }

  /// Stream all progress docs for a user for a given period.
  Stream<List<UserMissionProgress>> watchProgress({
    required String userId,
    required String periodStart,
  }) {
    return _progress
        .where('userId', isEqualTo: userId)
        .where('periodStart', isEqualTo: periodStart)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => UserMissionProgress.fromFirestore(d))
            .toList());
  }

  /// Stream daily mission progress for today.
  Stream<List<UserMissionProgress>> watchDailyProgress(String userId) {
    return watchProgress(userId: userId, periodStart: _todayPeriod());
  }

  /// Stream weekly mission progress for this week.
  Stream<List<UserMissionProgress>> watchWeeklyProgress(String userId) {
    return watchProgress(userId: userId, periodStart: _weekPeriod());
  }

  /// Get or create a progress doc for a specific mission + period.
  Future<UserMissionProgress> getOrCreateProgress({
    required String userId,
    required MissionModel mission,
  }) async {
    final period = mission.type == MissionType.daily
        ? _todayPeriod()
        : _weekPeriod();
    final docId = '${userId}_${mission.missionId}_$period';
    final doc = await _progress.doc(docId).get();

    if (doc.exists) return UserMissionProgress.fromFirestore(doc);

    final empty = UserMissionProgress.empty(
      userId: userId,
      missionId: mission.missionId,
      targetValue: mission.targetValue,
      periodStart: period,
    );
    await _progress.doc(docId).set(empty.toFirestore());
    return empty;
  }

  /// Update progress value. Marks complete if target reached.
  Future<void> updateProgress({
    required String docId,
    required int newValue,
    required int targetValue,
  }) async {
    final isComplete = newValue >= targetValue;
    await _progress.doc(docId).update({
      'currentValue': newValue,
      'isCompleted': isComplete,
      if (isComplete) 'completedAt': Timestamp.now(),
    });
  }

  /// Check how many daily missions are completed today.
  Future<int> completedDailyCount(String userId) async {
    final snap = await _progress
        .where('userId', isEqualTo: userId)
        .where('periodStart', isEqualTo: _todayPeriod())
        .where('isCompleted', isEqualTo: true)
        .get();
    return snap.docs.length;
  }
}
