import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../config/constants.dart';
import '../models/battle_model.dart';

class BattleService {
  final FirebaseFirestore _firestore;

  BattleService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _battles =>
      _firestore.collection('battles');

  // ---------------------------------------------------------------------------
  // Create
  // ---------------------------------------------------------------------------

  /// Create a new battle. Returns the created battle document ID.
  Future<String> createBattle({
    required BattleType type,
    required List<BattleParticipant> participants,
    required int durationDays,
    required String createdBy,
  }) async {
    final now = DateTime.now();
    final xp = type == BattleType.oneVsOne
        ? AppConstants.xpWin1v1
        : AppConstants.xpWinGroup;

    final battle = BattleModel(
      battleId: '', // Firestore auto-ID
      type: type,
      status: BattleStatus.pending,
      participants: participants,
      startTime: now,
      endTime: now.add(Duration(days: durationDays)),
      durationDays: durationDays,
      xpReward: xp,
      createdBy: createdBy,
    );

    final docRef = await _battles.add(battle.toFirestore());
    return docRef.id;
  }

  /// Generate a short random battle ID for display.
  static String generateBattleCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ0123456789';
    final rng = Random();
    return String.fromCharCodes(
      Iterable.generate(4, (_) => chars.codeUnitAt(rng.nextInt(chars.length))),
    );
  }

  // ---------------------------------------------------------------------------
  // Accept / Cancel
  // ---------------------------------------------------------------------------

  /// Accept a pending battle — sets status to active and resets startTime.
  Future<void> acceptBattle(String battleId) async {
    final now = DateTime.now();
    final doc = await _battles.doc(battleId).get();
    if (!doc.exists) return;

    final battle = BattleModel.fromFirestore(doc);
    final newEnd = now.add(Duration(days: battle.durationDays));

    await _battles.doc(battleId).update({
      'status': 'active',
      'startTime': Timestamp.fromDate(now),
      'endTime': Timestamp.fromDate(newEnd),
    });
  }

  /// Cancel a pending battle (only before it starts).
  Future<void> cancelBattle(String battleId) async {
    final doc = await _battles.doc(battleId).get();
    if (!doc.exists) return;
    final data = doc.data()!;
    if (data['status'] == 'pending') {
      await _battles.doc(battleId).delete();
    }
  }

  // ---------------------------------------------------------------------------
  // Update steps
  // ---------------------------------------------------------------------------

  /// Update a participant's step count during an active battle.
  Future<void> updateParticipantSteps({
    required String battleId,
    required String userId,
    required int steps,
  }) async {
    final doc = await _battles.doc(battleId).get();
    if (!doc.exists) return;

    final participants =
        (doc.data()!['participants'] as List<dynamic>)
            .map((p) => Map<String, dynamic>.from(p as Map))
            .toList();

    for (final p in participants) {
      if (p['userId'] == userId) {
        p['currentSteps'] = steps;
        break;
      }
    }

    await _battles.doc(battleId).update({'participants': participants});
  }

  // ---------------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------------

  /// Stream a single battle (real-time for live battle view).
  Stream<BattleModel?> watchBattle(String battleId) {
    return _battles.doc(battleId).snapshots().map((doc) {
      if (!doc.exists) return null;
      return BattleModel.fromFirestore(doc);
    });
  }

  /// Get battles for a user filtered by status.
  Future<List<BattleModel>> getBattles({
    required String userId,
    required BattleStatus status,
  }) async {
    final query = await _battles
        .where('status', isEqualTo: status.name)
        .orderBy('startTime', descending: true)
        .get();

    return query.docs
        .map((doc) => BattleModel.fromFirestore(doc))
        .where((b) => b.participants.any((p) => p.userId == userId))
        .toList();
  }

  /// Stream active battles for a user (real-time list).
  Stream<List<BattleModel>> watchActiveBattles(String userId) {
    return _battles
        .where('status', isEqualTo: 'active')
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => BattleModel.fromFirestore(doc))
            .where((b) => b.participants.any((p) => p.userId == userId))
            .toList());
  }

  /// Stream all battles for a user (all statuses).
  Stream<List<BattleModel>> watchAllBattles(String userId) {
    return _battles
        .orderBy('startTime', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => BattleModel.fromFirestore(doc))
            .where((b) => b.participants.any((p) => p.userId == userId))
            .toList());
  }
}
