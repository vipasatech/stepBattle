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

  CollectionReference<Map<String, dynamic>> get _notifications =>
      _firestore.collection('notifications');

  /// Generate a short random battle ID for display.
  static String generateBattleCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ0123456789';
    final rng = Random();
    return String.fromCharCodes(
      Iterable.generate(4, (_) => chars.codeUnitAt(rng.nextInt(chars.length))),
    );
  }

  // ---------------------------------------------------------------------------
  // Create — with invite-based flow
  // ---------------------------------------------------------------------------

  /// Create a new battle with pending invites.
  /// Creator is auto-accepted. Recipients receive in-app notifications
  /// and must Accept before battle becomes active.
  ///
  /// The battle ends at [endTime]. Whoever leads on steps at that moment
  /// wins — no target step count. `startTime` is set to `now` as a placeholder
  /// and replaced with the actual activation moment when all invitees accept.
  ///
  /// Returns the created battle document ID.
  Future<String> createBattle({
    required BattleType type,
    required List<BattleParticipant> participants,
    required DateTime endTime,
    required String createdBy,
  }) async {
    final now = DateTime.now();
    if (!endTime.isAfter(now)) {
      throw ArgumentError('endTime must be in the future');
    }
    final xp = type == BattleType.oneVsOne
        ? AppConstants.xpWin1v1
        : AppConstants.xpWinGroup;

    final allIds = participants.map((p) => p.userId).toList();
    // Creator is pre-accepted; everyone else needs to accept
    final acceptedIds = [createdBy];

    // Derived duration (kept on the doc for back-compat with cards that
    // still read `durationDays`). Rounded up to 1 day minimum so UI that
    // formats "N-day battle" reads sensibly for short battles too.
    final diff = endTime.difference(now);
    final durationDays = diff.inHours >= 24 ? diff.inDays : 1;

    final battle = BattleModel(
      battleId: '',
      type: type,
      status: BattleStatus.pending,
      participants: participants,
      invitedUserIds: allIds,
      acceptedUserIds: acceptedIds,
      startTime: now,
      endTime: endTime,
      durationDays: durationDays,
      xpReward: xp,
      createdBy: createdBy,
      createdAt: now,
    );

    final docRef = await _battles.add(battle.toFirestore());

    // Get creator's name for the notification body
    final creator = participants.firstWhere((p) => p.userId == createdBy);
    final creatorName = creator.displayName;

    // Fan out in-app notifications to each invitee (except creator)
    for (final id in allIds) {
      if (id == createdBy) continue;
      await _notifications.add({
        'userId': id,
        'type': 'battle_invite',
        'title': 'Battle Invite',
        'body':
            '$creatorName challenged you to ${type == BattleType.oneVsOne ? "a 1v1" : "a group"} battle',
        'data': {
          'battleId': docRef.id,
          'fromUserId': createdBy,
        },
        'read': false,
        'createdAt': Timestamp.now(),
      });
    }

    return docRef.id;
  }

  // ---------------------------------------------------------------------------
  // Invite responses
  // ---------------------------------------------------------------------------

  /// Accept a battle invite. If all invitees accept, battle becomes active.
  Future<void> acceptInvite({
    required String battleId,
    required String userId,
  }) async {
    final doc = await _battles.doc(battleId).get();
    if (!doc.exists) return;
    final battle = BattleModel.fromFirestore(doc);

    if (battle.status != BattleStatus.pending) return;
    if (!battle.invitedUserIds.contains(userId)) return;
    if (battle.acceptedUserIds.contains(userId)) return;

    final newAccepted = [...battle.acceptedUserIds, userId];
    final allAccepted =
        battle.invitedUserIds.every((id) => newAccepted.contains(id));

    final now = DateTime.now();
    final updates = <String, dynamic>{
      'acceptedUserIds': newAccepted,
    };

    if (allAccepted) {
      // Preserve the original duration (picked at creation) from the moment
      // the battle actually activates — opponent acceptance delay doesn't
      // eat into the battle window. `endTime - createdAt` captures the
      // user-chosen length at sub-day precision.
      final duration = battle.endTime.difference(battle.createdAt);
      updates['status'] = 'active';
      updates['startTime'] = Timestamp.fromDate(now);
      updates['endTime'] = Timestamp.fromDate(now.add(duration));

      // Notify creator that battle started
      await _notifications.add({
        'userId': battle.createdBy,
        'type': 'battle_started',
        'title': 'Battle Started',
        'body': 'All participants accepted. Your battle is live!',
        'data': {'battleId': battleId},
        'read': false,
        'createdAt': Timestamp.now(),
      });
    }

    await _battles.doc(battleId).update(updates);
  }

  /// Reject a battle invite. If 1v1, battle is cancelled.
  /// If group, user is removed from invited/participants.
  Future<void> rejectInvite({
    required String battleId,
    required String userId,
  }) async {
    final doc = await _battles.doc(battleId).get();
    if (!doc.exists) return;
    final battle = BattleModel.fromFirestore(doc);
    if (battle.status != BattleStatus.pending) return;

    if (battle.type == BattleType.oneVsOne) {
      // 1v1 — reject cancels the whole battle
      await _battles.doc(battleId).update({'status': 'cancelled'});

      // Notify creator
      if (battle.createdBy != userId) {
        await _notifications.add({
          'userId': battle.createdBy,
          'type': 'battle_rejected',
          'title': 'Battle Declined',
          'body': 'Your opponent declined the battle',
          'data': {'battleId': battleId},
          'read': false,
          'createdAt': Timestamp.now(),
        });
      }
    } else {
      // Group — remove the user from participants + invited list
      final newParticipants =
          battle.participants.where((p) => p.userId != userId).toList();
      final newInvited =
          battle.invitedUserIds.where((id) => id != userId).toList();
      final newAccepted =
          battle.acceptedUserIds.where((id) => id != userId).toList();

      await _battles.doc(battleId).update({
        'participants': newParticipants.map((p) => p.toMap()).toList(),
        'invitedUserIds': newInvited,
        'acceptedUserIds': newAccepted,
      });

      // If all remaining have accepted, activate the battle
      if (newInvited.every((id) => newAccepted.contains(id)) &&
          newParticipants.length >= 2) {
        final now = DateTime.now();
        final duration = battle.endTime.difference(battle.createdAt);
        await _battles.doc(battleId).update({
          'status': 'active',
          'startTime': Timestamp.fromDate(now),
          'endTime': Timestamp.fromDate(now.add(duration)),
        });
      }
    }
  }

  /// Creator cancels their own pending battle before anyone accepts.
  Future<void> cancelBattle(String battleId) async {
    final doc = await _battles.doc(battleId).get();
    if (!doc.exists) return;
    final data = doc.data()!;
    if (data['status'] == 'pending') {
      await _battles.doc(battleId).update({'status': 'cancelled'});
    }
  }

  /// Delete a pending battle (creator only). Marks the battle cancelled and
  /// removes any unread pending-invite notifications for this battle so it
  /// disappears from invitees' notification trays too.
  /// Throws [StateError] if the actor isn't the creator or the battle isn't
  /// in a pending state.
  Future<void> deletePendingBattle({
    required String battleId,
    required String actorId,
  }) async {
    final doc = await _battles.doc(battleId).get();
    if (!doc.exists) return;
    final data = doc.data()!;
    if (data['createdBy'] != actorId) {
      throw StateError('Only the creator can delete a pending battle.');
    }
    if (data['status'] != 'pending') {
      throw StateError('Only pending battles can be deleted.');
    }

    await _battles.doc(battleId).update({'status': 'cancelled'});

    // Clean up pending battle_invite notifications for this battle.
    final notifSnap = await _notifications
        .where('type', isEqualTo: 'battle_invite')
        .where('data.battleId', isEqualTo: battleId)
        .get();
    for (final n in notifSnap.docs) {
      await n.reference.delete();
    }
  }

  /// Auto-cancel all pending battles older than 24h for any user the creator
  /// is involved in. Called on Battles tab open.
  Future<void> cancelExpiredPendingBattles(String userId) async {
    final cutoff = DateTime.now().subtract(const Duration(hours: 24));
    final snap = await _battles
        .where('status', isEqualTo: 'pending')
        .where('createdBy', isEqualTo: userId)
        .get();

    for (final doc in snap.docs) {
      final data = doc.data();
      final createdAt = (data['createdAt'] as Timestamp?)?.toDate();
      if (createdAt != null && createdAt.isBefore(cutoff)) {
        await doc.reference.update({'status': 'cancelled'});
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Update steps
  // ---------------------------------------------------------------------------

  Future<void> updateParticipantSteps({
    required String battleId,
    required String userId,
    required int steps,
  }) async {
    final doc = await _battles.doc(battleId).get();
    if (!doc.exists) return;

    final participants = (doc.data()!['participants'] as List<dynamic>)
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

  Stream<BattleModel?> watchBattle(String battleId) {
    return _battles.doc(battleId).snapshots().map((doc) {
      if (!doc.exists) return null;
      return BattleModel.fromFirestore(doc);
    });
  }

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

  Stream<List<BattleModel>> watchActiveBattles(String userId) {
    return _battles
        .where('status', isEqualTo: 'active')
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => BattleModel.fromFirestore(doc))
            .where((b) => b.participants.any((p) => p.userId == userId))
            .toList());
  }

  /// Stream of all battles (any status) this user is a participant in.
  Stream<List<BattleModel>> watchAllBattles(String userId) {
    return _battles
        .orderBy('startTime', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => BattleModel.fromFirestore(doc))
            .where((b) => b.participants.any((p) => p.userId == userId))
            .toList());
  }

  /// Stream of pending battles where the user is invited but hasn't accepted.
  Stream<List<BattleModel>> watchIncomingInvites(String userId) {
    return _battles
        .where('status', isEqualTo: 'pending')
        .where('invitedUserIds', arrayContains: userId)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => BattleModel.fromFirestore(d))
            .where((b) => !b.acceptedUserIds.contains(userId))
            .toList());
  }
}
