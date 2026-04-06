import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/clan_model.dart';
import '../models/clan_battle_model.dart';

class ClanService {
  final FirebaseFirestore _firestore;

  ClanService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _clans =>
      _firestore.collection('clans');

  CollectionReference<Map<String, dynamic>> get _clanBattles =>
      _firestore.collection('clan_battles');

  CollectionReference<Map<String, dynamic>> get _users =>
      _firestore.collection('users');

  // ---------------------------------------------------------------------------
  // Clan CRUD
  // ---------------------------------------------------------------------------

  /// Generate a short random clan ID code like "#CL7X9".
  static String generateClanCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ0123456789';
    final rng = Random();
    final code = String.fromCharCodes(
      Iterable.generate(5, (_) => chars.codeUnitAt(rng.nextInt(chars.length))),
    );
    return '#$code';
  }

  /// Create a new clan. Returns clan document ID.
  Future<String> createClan({
    required String name,
    required String captainId,
    required List<String> initialMemberIds,
  }) async {
    final code = generateClanCode();
    final allMembers = {captainId, ...initialMemberIds}.toList();

    final clan = ClanModel(
      clanId: '',
      name: name,
      clanIdCode: code,
      captainId: captainId,
      memberIds: allMembers,
      createdAt: DateTime.now(),
    );

    final docRef = await _clans.add(clan.toFirestore());

    // Update each member's user doc with clanId
    final batch = _firestore.batch();
    for (final uid in allMembers) {
      batch.update(_users.doc(uid), {'clanId': docRef.id});
    }
    await batch.commit();

    // Create member subcollection docs
    for (final uid in allMembers) {
      final userDoc = await _users.doc(uid).get();
      final userData = userDoc.data() ?? {};
      await docRef.collection('members').doc(uid).set({
        'userId': uid,
        'displayName': userData['displayName'] ?? '',
        'avatarURL': userData['avatarURL'],
        'role': uid == captainId ? 'captain' : 'soldier',
        'stepsToday': 0,
      });
    }

    return docRef.id;
  }

  /// Join an existing clan by ID.
  Future<void> joinClan({
    required String clanId,
    required String userId,
  }) async {
    final clanRef = _clans.doc(clanId);
    await clanRef.update({
      'memberIds': FieldValue.arrayUnion([userId]),
    });
    await _users.doc(userId).update({'clanId': clanId});

    final userDoc = await _users.doc(userId).get();
    final userData = userDoc.data() ?? {};
    await clanRef.collection('members').doc(userId).set({
      'userId': userId,
      'displayName': userData['displayName'] ?? '',
      'avatarURL': userData['avatarURL'],
      'role': 'soldier',
      'stepsToday': 0,
    });
  }

  /// Leave a clan.
  Future<void> leaveClan({
    required String clanId,
    required String userId,
  }) async {
    await _clans.doc(clanId).update({
      'memberIds': FieldValue.arrayRemove([userId]),
    });
    await _users.doc(userId).update({'clanId': null});
    await _clans.doc(clanId).collection('members').doc(userId).delete();
  }

  /// Remove a member (captain only).
  Future<void> removeMember({
    required String clanId,
    required String userId,
  }) async {
    await leaveClan(clanId: clanId, userId: userId);
  }

  // ---------------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------------

  /// Stream the clan document.
  Stream<ClanModel?> watchClan(String clanId) {
    return _clans.doc(clanId).snapshots().map((doc) {
      if (!doc.exists) return null;
      return ClanModel.fromFirestore(doc);
    });
  }

  /// Stream clan members subcollection.
  Stream<List<ClanMember>> watchMembers(String clanId) {
    return _clans.doc(clanId).collection('members').snapshots().map(
        (snap) => snap.docs.map((d) => ClanMember.fromMap(d.data())).toList());
  }

  /// Search clans by name or code.
  Future<List<ClanModel>> searchClans(String query) async {
    final q = query.trim().toUpperCase();

    // Try code match first
    if (q.startsWith('#')) {
      final snap =
          await _clans.where('clanIdCode', isEqualTo: q).limit(5).get();
      return snap.docs.map((d) => ClanModel.fromFirestore(d)).toList();
    }

    // Name prefix search
    final snap = await _clans
        .where('name', isGreaterThanOrEqualTo: query)
        .where('name', isLessThanOrEqualTo: '$query\uf8ff')
        .limit(10)
        .get();
    return snap.docs.map((d) => ClanModel.fromFirestore(d)).toList();
  }

  // ---------------------------------------------------------------------------
  // Clan Battles
  // ---------------------------------------------------------------------------

  /// Create a clan battle.
  Future<String> createClanBattle({
    required String clanAId,
    required String clanAName,
    required String clanBId,
    required String clanBName,
    required int durationDays,
    required String battleType,
  }) async {
    final now = DateTime.now();
    final battle = ClanBattleModel(
      clanBattleId: '',
      status: ClanBattleStatus.active,
      clanA: ClanBattleTeam(clanId: clanAId, clanName: clanAName),
      clanB: ClanBattleTeam(clanId: clanBId, clanName: clanBName),
      startTime: now,
      endTime: now.add(Duration(days: durationDays)),
      durationDays: durationDays,
      battleType: battleType,
    );

    final docRef = await _clanBattles.add(battle.toFirestore());

    // Link battle to both clans
    await _clans.doc(clanAId).update({'activeBattleId': docRef.id});
    await _clans.doc(clanBId).update({'activeBattleId': docRef.id});

    return docRef.id;
  }

  /// Stream a clan battle.
  Stream<ClanBattleModel?> watchClanBattle(String battleId) {
    return _clanBattles.doc(battleId).snapshots().map((doc) {
      if (!doc.exists) return null;
      return ClanBattleModel.fromFirestore(doc);
    });
  }

  /// Get available clan battles to join.
  Future<List<ClanBattleModel>> getAvailableClanBattles() async {
    final snap = await _clanBattles
        .where('status', whereIn: ['pending', 'active'])
        .orderBy('startTime', descending: true)
        .limit(20)
        .get();
    return snap.docs.map((d) => ClanBattleModel.fromFirestore(d)).toList();
  }
}
