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

  CollectionReference<Map<String, dynamic>> get _notifications =>
      _firestore.collection('notifications');

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

  /// Create a new clan. Captain is auto-added as a full member.
  /// Invited users become pending invites + get a notification; they don't
  /// become members until they accept.
  Future<String> createClan({
    required String name,
    required String captainId,
    required List<String> invitedUserIds,
  }) async {
    final code = generateClanCode();

    // Captain is pre-accepted. Invitees go into pendingInviteIds.
    final pendingInvites =
        invitedUserIds.where((id) => id != captainId).toList();

    final clan = ClanModel(
      clanId: '',
      name: name,
      clanIdCode: code,
      captainId: captainId,
      memberIds: [captainId],
      pendingInviteIds: pendingInvites,
      createdAt: DateTime.now(),
    );

    final docRef = await _clans.add(clan.toFirestore());

    // Captain joins immediately
    await _users.doc(captainId).update({'clanId': docRef.id});
    final captainDoc = await _users.doc(captainId).get();
    final captainData = captainDoc.data() ?? {};
    await docRef.collection('members').doc(captainId).set({
      'userId': captainId,
      'displayName': captainData['displayName'] ?? '',
      'avatarURL': captainData['avatarURL'],
      'role': 'captain',
      'stepsToday': 0,
    });

    // Fan out invite notifications
    final captainName = captainData['displayName'] as String? ?? 'Someone';
    for (final uid in pendingInvites) {
      await _notifications.add({
        'userId': uid,
        'type': 'clan_invite',
        'title': 'Clan Invite',
        'body': '$captainName invited you to join "$name"',
        'data': {
          'clanId': docRef.id,
          'fromUserId': captainId,
        },
        'read': false,
        'createdAt': Timestamp.now(),
      });
    }

    return docRef.id;
  }

  /// Invite additional users to an existing clan (captain-initiated).
  Future<void> inviteMembers({
    required String clanId,
    required String captainId,
    required List<String> userIds,
  }) async {
    final clanRef = _clans.doc(clanId);
    final clanDoc = await clanRef.get();
    if (!clanDoc.exists) return;
    final clan = ClanModel.fromFirestore(clanDoc);

    // Deduplicate: skip users already in or invited
    final newInvites = userIds
        .where((id) =>
            !clan.memberIds.contains(id) &&
            !clan.pendingInviteIds.contains(id))
        .toList();
    if (newInvites.isEmpty) return;

    await clanRef.update({
      'pendingInviteIds': FieldValue.arrayUnion(newInvites),
    });

    final captainDoc = await _users.doc(captainId).get();
    final captainName =
        captainDoc.data()?['displayName'] as String? ?? 'Someone';

    for (final uid in newInvites) {
      await _notifications.add({
        'userId': uid,
        'type': 'clan_invite',
        'title': 'Clan Invite',
        'body': '$captainName invited you to join "${clan.name}"',
        'data': {
          'clanId': clanId,
          'fromUserId': captainId,
        },
        'read': false,
        'createdAt': Timestamp.now(),
      });
    }
  }

  /// Accept a clan invite — moves user from pendingInviteIds to memberIds.
  Future<void> acceptClanInvite({
    required String clanId,
    required String userId,
  }) async {
    final clanRef = _clans.doc(clanId);
    final doc = await clanRef.get();
    if (!doc.exists) return;
    final clan = ClanModel.fromFirestore(doc);
    if (!clan.pendingInviteIds.contains(userId)) return;
    if (clan.isFull) return;

    await clanRef.update({
      'pendingInviteIds': FieldValue.arrayRemove([userId]),
      'memberIds': FieldValue.arrayUnion([userId]),
    });
    await _users.doc(userId).update({'clanId': clanId});

    // Create member subcollection doc
    final userDoc = await _users.doc(userId).get();
    final userData = userDoc.data() ?? {};
    await clanRef.collection('members').doc(userId).set({
      'userId': userId,
      'displayName': userData['displayName'] ?? '',
      'avatarURL': userData['avatarURL'],
      'role': 'soldier',
      'stepsToday': 0,
    });

    // Notify captain
    final accepterName = userData['displayName'] as String? ?? 'Someone';
    await _notifications.add({
      'userId': clan.captainId,
      'type': 'other',
      'title': 'New Clan Member',
      'body': '$accepterName joined "${clan.name}"',
      'data': {'clanId': clanId},
      'read': false,
      'createdAt': Timestamp.now(),
    });
  }

  /// Reject a clan invite — just removes from pendingInviteIds.
  Future<void> rejectClanInvite({
    required String clanId,
    required String userId,
  }) async {
    await _clans.doc(clanId).update({
      'pendingInviteIds': FieldValue.arrayRemove([userId]),
    });
  }

  /// Cancel a pending invite (captain side).
  Future<void> cancelInvite({
    required String clanId,
    required String userId,
  }) async {
    await _clans.doc(clanId).update({
      'pendingInviteIds': FieldValue.arrayRemove([userId]),
    });
  }

  /// Public self-join via clan code (no invite needed — opt-in).
  /// Used when someone searches for a clan and taps "Join".
  Future<void> joinClan({
    required String clanId,
    required String userId,
  }) async {
    final clanRef = _clans.doc(clanId);
    await clanRef.update({
      'memberIds': FieldValue.arrayUnion([userId]),
      'pendingInviteIds': FieldValue.arrayRemove([userId]),
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

  /// Leave a clan. Captain cannot leave directly — they must
  /// [transferCaptaincy] first, then call this, OR [deleteClan] instead.
  /// Throws [StateError] if the caller is the captain.
  Future<void> leaveClan({
    required String clanId,
    required String userId,
  }) async {
    final clanDoc = await _clans.doc(clanId).get();
    if (!clanDoc.exists) return;
    final clan = ClanModel.fromFirestore(clanDoc);
    if (clan.captainId == userId) {
      throw StateError(
          'Captain cannot leave the clan. Transfer captaincy first.');
    }

    await _clans.doc(clanId).update({
      'memberIds': FieldValue.arrayRemove([userId]),
      'adminIds': FieldValue.arrayRemove([userId]),
    });
    await _users.doc(userId).update({'clanId': null});
    await _clans.doc(clanId).collection('members').doc(userId).delete();
  }

  /// Kick a member. Captain can kick admins and soldiers. Admins can only
  /// kick soldiers. Throws [StateError] if the actor lacks permission.
  Future<void> kickMember({
    required String clanId,
    required String actorId,
    required String targetId,
  }) async {
    if (actorId == targetId) {
      throw StateError('Use leaveClan to remove yourself.');
    }
    final clanDoc = await _clans.doc(clanId).get();
    if (!clanDoc.exists) return;
    final clan = ClanModel.fromFirestore(clanDoc);

    if (clan.captainId == targetId) {
      throw StateError('Cannot kick the captain.');
    }

    final actorIsCaptain = clan.captainId == actorId;
    final actorIsAdmin = clan.adminIds.contains(actorId);
    final targetIsAdmin = clan.adminIds.contains(targetId);

    if (!actorIsCaptain && !actorIsAdmin) {
      throw StateError('Only captain or admins can kick members.');
    }
    if (actorIsAdmin && !actorIsCaptain && targetIsAdmin) {
      throw StateError('Admins cannot kick other admins.');
    }

    await _clans.doc(clanId).update({
      'memberIds': FieldValue.arrayRemove([targetId]),
      'adminIds': FieldValue.arrayRemove([targetId]),
    });
    await _users.doc(targetId).update({'clanId': null});
    await _clans.doc(clanId).collection('members').doc(targetId).delete();

    // Notify the kicked user
    await _notifications.add({
      'userId': targetId,
      'type': 'other',
      'title': 'Removed from Clan',
      'body': 'You were removed from "${clan.name}"',
      'data': {'clanId': clanId},
      'read': false,
      'createdAt': Timestamp.now(),
    });
  }

  /// Promote a soldier to admin. Captain only.
  Future<void> promoteToAdmin({
    required String clanId,
    required String captainId,
    required String userId,
  }) async {
    final clanDoc = await _clans.doc(clanId).get();
    if (!clanDoc.exists) return;
    final clan = ClanModel.fromFirestore(clanDoc);
    if (clan.captainId != captainId) {
      throw StateError('Only the captain can promote members.');
    }
    if (!clan.memberIds.contains(userId)) {
      throw StateError('Target is not a clan member.');
    }
    if (clan.captainId == userId || clan.adminIds.contains(userId)) return;

    await _clans.doc(clanId).update({
      'adminIds': FieldValue.arrayUnion([userId]),
    });
    await _clans.doc(clanId).collection('members').doc(userId).set(
      {'role': 'admin'},
      SetOptions(merge: true),
    );
  }

  /// Demote an admin back to soldier. Captain only.
  Future<void> demoteAdmin({
    required String clanId,
    required String captainId,
    required String userId,
  }) async {
    final clanDoc = await _clans.doc(clanId).get();
    if (!clanDoc.exists) return;
    final clan = ClanModel.fromFirestore(clanDoc);
    if (clan.captainId != captainId) {
      throw StateError('Only the captain can demote admins.');
    }
    if (!clan.adminIds.contains(userId)) return;

    await _clans.doc(clanId).update({
      'adminIds': FieldValue.arrayRemove([userId]),
    });
    await _clans.doc(clanId).collection('members').doc(userId).set(
      {'role': 'soldier'},
      SetOptions(merge: true),
    );
  }

  /// Transfer captaincy to another member. The outgoing captain becomes a
  /// soldier (not admin — they can re-promote themselves via the new captain).
  /// The new captain is removed from adminIds if present.
  Future<void> transferCaptaincy({
    required String clanId,
    required String currentCaptainId,
    required String newCaptainId,
  }) async {
    if (currentCaptainId == newCaptainId) return;
    final clanDoc = await _clans.doc(clanId).get();
    if (!clanDoc.exists) return;
    final clan = ClanModel.fromFirestore(clanDoc);
    if (clan.captainId != currentCaptainId) {
      throw StateError('Only the current captain can transfer captaincy.');
    }
    if (!clan.memberIds.contains(newCaptainId)) {
      throw StateError('New captain must be a current clan member.');
    }

    await _clans.doc(clanId).update({
      'captainId': newCaptainId,
      'adminIds': FieldValue.arrayRemove([newCaptainId]),
    });
    await _clans.doc(clanId).collection('members').doc(newCaptainId).set(
      {'role': 'captain'},
      SetOptions(merge: true),
    );
    await _clans.doc(clanId).collection('members').doc(currentCaptainId).set(
      {'role': 'soldier'},
      SetOptions(merge: true),
    );

    // Notify new captain
    await _notifications.add({
      'userId': newCaptainId,
      'type': 'other',
      'title': 'You are now Captain',
      'body': 'You lead "${clan.name}" now',
      'data': {'clanId': clanId},
      'read': false,
      'createdAt': Timestamp.now(),
    });
  }

  /// Delete the clan. Captain only. Cascades:
  /// - clears `clanId` on every member + pending-invitee
  /// - deletes all member subcollection docs
  /// - cancels any active/pending clan battles involving this clan
  /// - deletes the clan doc
  /// - notifies former members
  Future<void> deleteClan({
    required String clanId,
    required String captainId,
  }) async {
    final clanRef = _clans.doc(clanId);
    final clanDoc = await clanRef.get();
    if (!clanDoc.exists) return;
    final clan = ClanModel.fromFirestore(clanDoc);
    if (clan.captainId != captainId) {
      throw StateError('Only the captain can delete the clan.');
    }

    // Clear clanId on everyone who has this clan set (members + pending).
    for (final uid in {...clan.memberIds, ...clan.pendingInviteIds}) {
      final userDoc = await _users.doc(uid).get();
      final data = userDoc.data();
      if (data != null && data['clanId'] == clanId) {
        await _users.doc(uid).update({'clanId': null});
      }
    }

    // Cancel clan battles where this clan is on either side and not completed.
    final battlesA = await _clanBattles
        .where('clanA.clanId', isEqualTo: clanId)
        .where('status', whereIn: ['pending', 'active']).get();
    final battlesB = await _clanBattles
        .where('clanB.clanId', isEqualTo: clanId)
        .where('status', whereIn: ['pending', 'active']).get();
    for (final doc in [...battlesA.docs, ...battlesB.docs]) {
      await doc.reference.update({'status': 'completed'});
    }

    // Notify former members (except the captain who initiated).
    for (final uid in clan.memberIds) {
      if (uid == captainId) continue;
      await _notifications.add({
        'userId': uid,
        'type': 'other',
        'title': 'Clan Disbanded',
        'body': '"${clan.name}" was deleted by the captain',
        'data': {'clanId': clanId},
        'read': false,
        'createdAt': Timestamp.now(),
      });
    }

    // Delete member subcollection docs, then the clan doc itself.
    final memberDocs = await clanRef.collection('members').get();
    for (final m in memberDocs.docs) {
      await m.reference.delete();
    }
    await clanRef.delete();
  }

  /// Remove a member (captain only). Kept for backwards-compat; delegates
  /// to [kickMember] with the captain's permissions.
  Future<void> removeMember({
    required String clanId,
    required String userId,
  }) async {
    final clanDoc = await _clans.doc(clanId).get();
    if (!clanDoc.exists) return;
    final clan = ClanModel.fromFirestore(clanDoc);
    await kickMember(
      clanId: clanId,
      actorId: clan.captainId,
      targetId: userId,
    );
  }

  // ---------------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------------

  Stream<ClanModel?> watchClan(String clanId) {
    return _clans.doc(clanId).snapshots().map((doc) {
      if (!doc.exists) return null;
      return ClanModel.fromFirestore(doc);
    });
  }

  Stream<List<ClanMember>> watchMembers(String clanId) {
    return _clans.doc(clanId).collection('members').snapshots().map(
        (snap) => snap.docs.map((d) => ClanMember.fromMap(d.data())).toList());
  }

  /// Stream clans where the given user has a pending invite.
  Stream<List<ClanModel>> watchIncomingClanInvites(String userId) {
    return _clans
        .where('pendingInviteIds', arrayContains: userId)
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => ClanModel.fromFirestore(d)).toList());
  }

  Future<List<ClanModel>> searchClans(String query) async {
    final q = query.trim().toUpperCase();

    if (q.startsWith('#')) {
      final snap =
          await _clans.where('clanIdCode', isEqualTo: q).limit(5).get();
      return snap.docs.map((d) => ClanModel.fromFirestore(d)).toList();
    }

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

    await _clans.doc(clanAId).update({'activeBattleId': docRef.id});
    await _clans.doc(clanBId).update({'activeBattleId': docRef.id});

    return docRef.id;
  }

  Stream<ClanBattleModel?> watchClanBattle(String battleId) {
    return _clanBattles.doc(battleId).snapshots().map((doc) {
      if (!doc.exists) return null;
      return ClanBattleModel.fromFirestore(doc);
    });
  }

  Future<List<ClanBattleModel>> getAvailableClanBattles() async {
    final snap = await _clanBattles
        .where('status', whereIn: ['pending', 'active'])
        .orderBy('startTime', descending: true)
        .limit(20)
        .get();
    return snap.docs.map((d) => ClanBattleModel.fromFirestore(d)).toList();
  }
}
