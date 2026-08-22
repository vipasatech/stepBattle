import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/clan_battle_model.dart';
import '../models/clan_model.dart';
import '../utils/app_logger.dart';

/// Clans + clan_members + clan_invites + clan_battles on Supabase.
///
/// Schema in 0001_init.sql:
///   • clans                — captain + scalar metadata
///   • clan_members         — junction (clan_id, user_id, role, steps_today)
///   • clan_invites         — junction (clan_id, user_id, invited_by)
///   • clan_battles         — top-level battle row
///   • clan_battle_teams    — junction (battle, clan, team_label A|B)
///
/// Additional columns added in 0003_clans_extras.sql:
///   • clans.total_clan_xp, active_battle_id, max_members
///   • clan_battles.duration_days, xp_per_member, winner_clan_id
///
/// We keep [ClanModel.memberIds] / [adminIds] / [pendingInviteIds] as
/// denormalized arrays the UI already consumes; they're populated by
/// [ClanModel.fromSupabaseRow] from embedded `clan_members` and
/// `clan_invites` rows.
class ClanService {
  final SupabaseClient _supabase;

  ClanService({SupabaseClient? supabase})
      : _supabase = supabase ?? Supabase.instance.client;

  /// Generate a short random clan ID code like "#CL7X9".
  static String generateClanCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ0123456789';
    final rng = Random();
    final code = String.fromCharCodes(
      Iterable.generate(5, (_) => chars.codeUnitAt(rng.nextInt(chars.length))),
    );
    return '#$code';
  }

  // ---------------------------------------------------------------------------
  // Clan CRUD
  // ---------------------------------------------------------------------------

  /// Create a clan. The captain is auto-added to clan_members; invitees go
  /// into clan_invites (no clan_members row yet) and get an in-app
  /// notification.
  Future<String> createClan({
    required String name,
    required String captainId,
    required List<String> invitedUserIds,
  }) async {
    AppLogger.clan.i('createClan', fields: {
      'name': name,
      'captainId': captainId,
      'invitedCount': invitedUserIds.length,
    });

    final code = generateClanCode();
    try {
      // 1. Insert clan.
      final clanRow = await _supabase
          .from('clans')
          .insert({
            'name': name,
            'clan_id_code': code,
            'captain_id': captainId,
          })
          .select('id')
          .single();
      final clanId = clanRow['id'] as String;

      // 2. Insert captain into clan_members. RLS allows insert when
      //    auth.uid() == user_id.
      await _supabase.from('clan_members').insert({
        'clan_id': clanId,
        'user_id': captainId,
        'role': 'captain',
        'steps_today': 0,
      });

      // 3. Mirror clan_id onto the captain's profile row so the home tab
      //    knows which clan to show.
      await _supabase
          .from('profiles')
          .update({'clan_id': clanId}).eq('id', captainId);

      // 4. Pending invites (skip self if accidentally included).
      final pending =
          invitedUserIds.where((id) => id != captainId).toList();
      if (pending.isNotEmpty) {
        await _supabase.from('clan_invites').insert(pending
            .map((uid) => {
                  'clan_id': clanId,
                  'user_id': uid,
                  'invited_by': captainId,
                })
            .toList());

        // 5. Captain name for the notification body.
        final captainProfile = await _supabase
            .from('profiles_public')
            .select('display_name')
            .eq('id', captainId)
            .maybeSingle();
        final captainName =
            captainProfile?['display_name'] as String? ?? 'Someone';

        for (final uid in pending) {
          await _supabase.from('notifications').insert({
            'user_id': uid,
            'type': 'clan_invite',
            'title': 'Clan Invite',
            'body': '$captainName invited you to join "$name"',
            'data': {'clan_id': clanId, 'from_user_id': captainId},
          });
        }
      }

      return clanId;
    } catch (e, s) {
      AppLogger.clan.e('createClan:failed', error: e, stack: s);
      rethrow;
    }
  }

  /// Invite additional users to an existing clan (captain-initiated).
  Future<void> inviteMembers({
    required String clanId,
    required String captainId,
    required List<String> userIds,
  }) async {
    AppLogger.clan
        .i('inviteMembers', fields: {'clanId': clanId, 'count': userIds.length});

    // Drop anyone who's already a member or already invited.
    final existingMembers = await _supabase
        .from('clan_members')
        .select('user_id')
        .eq('clan_id', clanId);
    final existingInvites = await _supabase
        .from('clan_invites')
        .select('user_id')
        .eq('clan_id', clanId);
    final blocked = <String>{
      for (final r in existingMembers as List)
        (r as Map<String, dynamic>)['user_id'] as String,
      for (final r in existingInvites as List)
        (r as Map<String, dynamic>)['user_id'] as String,
    };
    final newInvites =
        userIds.where((id) => !blocked.contains(id)).toList();
    if (newInvites.isEmpty) return;

    await _supabase.from('clan_invites').insert(newInvites
        .map((uid) => {
              'clan_id': clanId,
              'user_id': uid,
              'invited_by': captainId,
            })
        .toList());

    final captain = await _supabase
        .from('profiles_public')
        .select('display_name')
        .eq('id', captainId)
        .maybeSingle();
    final captainName =
        captain?['display_name'] as String? ?? 'Someone';
    final clan = await _supabase
        .from('clans')
        .select('name')
        .eq('id', clanId)
        .maybeSingle();
    final clanName = clan?['name'] as String? ?? 'a clan';

    for (final uid in newInvites) {
      await _supabase.from('notifications').insert({
        'user_id': uid,
        'type': 'clan_invite',
        'title': 'Clan Invite',
        'body': '$captainName invited you to join "$clanName"',
        'data': {'clan_id': clanId, 'from_user_id': captainId},
      });
    }
  }

  /// Accept a clan invite — moves the user from clan_invites to clan_members.
  Future<void> acceptClanInvite({
    required String clanId,
    required String userId,
  }) async {
    AppLogger.clan
        .i('acceptInvite', fields: {'clanId': clanId, 'userId': userId});

    // Verify there is an outstanding invite.
    final invite = await _supabase
        .from('clan_invites')
        .select('user_id')
        .eq('clan_id', clanId)
        .eq('user_id', userId)
        .maybeSingle();
    if (invite == null) return;

    // Check capacity.
    final clan = await _supabase
        .from('clans')
        .select('name, max_members, captain_id')
        .eq('id', clanId)
        .maybeSingle();
    if (clan == null) return;
    final memberCount = await _supabase
        .from('clan_members')
        .select('user_id')
        .eq('clan_id', clanId);
    final max = (clan['max_members'] as num?)?.toInt() ?? 10;
    if ((memberCount as List).length >= max) return;

    // Insert the new member (RLS: auth.uid() == user_id).
    await _supabase.from('clan_members').insert({
      'clan_id': clanId,
      'user_id': userId,
      'role': 'soldier',
      'steps_today': 0,
    });
    // Drop the invite row.
    await _supabase
        .from('clan_invites')
        .delete()
        .eq('clan_id', clanId)
        .eq('user_id', userId);
    // Mirror clan onto profile.
    await _supabase
        .from('profiles')
        .update({'clan_id': clanId}).eq('id', userId);

    // Notify the captain.
    final user = await _supabase
        .from('profiles_public')
        .select('display_name')
        .eq('id', userId)
        .maybeSingle();
    final accepterName = user?['display_name'] as String? ?? 'Someone';
    final captainId = clan['captain_id'] as String;
    final clanName = clan['name'] as String;
    await _supabase.from('notifications').insert({
      'user_id': captainId,
      'type': 'other',
      'title': 'New Clan Member',
      'body': '$accepterName joined "$clanName"',
      'data': {'clan_id': clanId, 'from_user_id': userId},
    });
  }

  Future<void> rejectClanInvite({
    required String clanId,
    required String userId,
  }) async {
    AppLogger.clan
        .i('rejectInvite', fields: {'clanId': clanId, 'userId': userId});
    await _supabase
        .from('clan_invites')
        .delete()
        .eq('clan_id', clanId)
        .eq('user_id', userId);
  }

  /// Captain cancels a pending invite.
  Future<void> cancelInvite({
    required String clanId,
    required String userId,
  }) async {
    await _supabase
        .from('clan_invites')
        .delete()
        .eq('clan_id', clanId)
        .eq('user_id', userId);
  }

  /// Public self-join (no invite needed).
  Future<void> joinClan({
    required String clanId,
    required String userId,
  }) async {
    AppLogger.clan
        .i('joinClan', fields: {'clanId': clanId, 'userId': userId});
    // Idempotent: if already a member, skip.
    final existing = await _supabase
        .from('clan_members')
        .select('user_id')
        .eq('clan_id', clanId)
        .eq('user_id', userId)
        .maybeSingle();
    if (existing != null) return;

    await _supabase.from('clan_members').insert({
      'clan_id': clanId,
      'user_id': userId,
      'role': 'soldier',
      'steps_today': 0,
    });
    await _supabase
        .from('clan_invites')
        .delete()
        .eq('clan_id', clanId)
        .eq('user_id', userId);
    await _supabase
        .from('profiles')
        .update({'clan_id': clanId}).eq('id', userId);
  }

  /// Leave a clan. Captain must transfer/delete first.
  Future<void> leaveClan({
    required String clanId,
    required String userId,
  }) async {
    AppLogger.clan
        .i('leaveClan', fields: {'clanId': clanId, 'userId': userId});
    final clan = await _supabase
        .from('clans')
        .select('captain_id')
        .eq('id', clanId)
        .maybeSingle();
    if (clan == null) return;
    if (clan['captain_id'] == userId) {
      throw StateError(
          'Captain cannot leave the clan. Transfer captaincy first.');
    }

    await _supabase
        .from('clan_members')
        .delete()
        .eq('clan_id', clanId)
        .eq('user_id', userId);
    await _supabase
        .from('profiles')
        .update({'clan_id': null}).eq('id', userId);
  }

  /// Kick a member. Captain → kicks anyone. Admin → kicks soldiers only.
  Future<void> kickMember({
    required String clanId,
    required String actorId,
    required String targetId,
  }) async {
    AppLogger.clan.i('kickMember', fields: {
      'clanId': clanId,
      'actorId': actorId,
      'targetId': targetId,
    });
    if (actorId == targetId) {
      throw StateError('Use leaveClan to remove yourself.');
    }

    final clan = await _supabase
        .from('clans')
        .select('captain_id, name')
        .eq('id', clanId)
        .maybeSingle();
    if (clan == null) return;
    if (clan['captain_id'] == targetId) {
      throw StateError('Cannot kick the captain.');
    }

    final actor = await _supabase
        .from('clan_members')
        .select('role')
        .eq('clan_id', clanId)
        .eq('user_id', actorId)
        .maybeSingle();
    final target = await _supabase
        .from('clan_members')
        .select('role')
        .eq('clan_id', clanId)
        .eq('user_id', targetId)
        .maybeSingle();
    if (actor == null || target == null) return;

    final actorIsCaptain = clan['captain_id'] == actorId;
    final actorIsAdmin = actor['role'] == 'admin';
    final targetIsAdmin = target['role'] == 'admin';

    if (!actorIsCaptain && !actorIsAdmin) {
      throw StateError('Only captain or admins can kick members.');
    }
    if (actorIsAdmin && !actorIsCaptain && targetIsAdmin) {
      throw StateError('Admins cannot kick other admins.');
    }

    await _supabase
        .from('clan_members')
        .delete()
        .eq('clan_id', clanId)
        .eq('user_id', targetId);
    await _supabase
        .from('profiles')
        .update({'clan_id': null}).eq('id', targetId);

    await _supabase.from('notifications').insert({
      'user_id': targetId,
      'type': 'other',
      'title': 'Removed from Clan',
      'body': 'You were removed from "${clan['name']}"',
      'data': {'clan_id': clanId, 'from_user_id': actorId},
    });
  }

  /// Promote a soldier to admin. Captain only.
  Future<void> promoteToAdmin({
    required String clanId,
    required String captainId,
    required String userId,
  }) async {
    AppLogger.clan
        .i('promoteToAdmin', fields: {'clanId': clanId, 'userId': userId});
    final clan = await _supabase
        .from('clans')
        .select('captain_id')
        .eq('id', clanId)
        .maybeSingle();
    if (clan == null || clan['captain_id'] != captainId) {
      throw StateError('Only the captain can promote members.');
    }
    await _supabase
        .from('clan_members')
        .update({'role': 'admin'})
        .eq('clan_id', clanId)
        .eq('user_id', userId);
  }

  Future<void> demoteAdmin({
    required String clanId,
    required String captainId,
    required String userId,
  }) async {
    AppLogger.clan
        .i('demoteAdmin', fields: {'clanId': clanId, 'userId': userId});
    final clan = await _supabase
        .from('clans')
        .select('captain_id')
        .eq('id', clanId)
        .maybeSingle();
    if (clan == null || clan['captain_id'] != captainId) {
      throw StateError('Only the captain can demote admins.');
    }
    await _supabase
        .from('clan_members')
        .update({'role': 'soldier'})
        .eq('clan_id', clanId)
        .eq('user_id', userId);
  }

  /// Transfer captaincy. The outgoing captain becomes a soldier.
  Future<void> transferCaptaincy({
    required String clanId,
    required String currentCaptainId,
    required String newCaptainId,
  }) async {
    AppLogger.clan.i('transferCaptaincy', fields: {
      'clanId': clanId,
      'from': currentCaptainId,
      'to': newCaptainId,
    });
    if (currentCaptainId == newCaptainId) return;

    final clan = await _supabase
        .from('clans')
        .select('captain_id, name')
        .eq('id', clanId)
        .maybeSingle();
    if (clan == null) return;
    if (clan['captain_id'] != currentCaptainId) {
      throw StateError('Only the current captain can transfer captaincy.');
    }
    // New captain must be a member.
    final newMember = await _supabase
        .from('clan_members')
        .select('user_id')
        .eq('clan_id', clanId)
        .eq('user_id', newCaptainId)
        .maybeSingle();
    if (newMember == null) {
      throw StateError('New captain must be a current clan member.');
    }

    await _supabase
        .from('clans')
        .update({'captain_id': newCaptainId}).eq('id', clanId);
    await _supabase
        .from('clan_members')
        .update({'role': 'captain'})
        .eq('clan_id', clanId)
        .eq('user_id', newCaptainId);
    await _supabase
        .from('clan_members')
        .update({'role': 'soldier'})
        .eq('clan_id', clanId)
        .eq('user_id', currentCaptainId);

    await _supabase.from('notifications').insert({
      'user_id': newCaptainId,
      'type': 'other',
      'title': 'You are now Captain',
      'body': 'You lead "${clan['name']}" now',
      'data': {'clan_id': clanId, 'from_user_id': currentCaptainId},
    });
  }

  /// Delete the clan. Captain only.
  Future<void> deleteClan({
    required String clanId,
    required String captainId,
  }) async {
    AppLogger.clan
        .i('deleteClan', fields: {'clanId': clanId, 'captainId': captainId});

    final clan = await _supabase
        .from('clans')
        .select('captain_id, name')
        .eq('id', clanId)
        .maybeSingle();
    if (clan == null) return;
    if (clan['captain_id'] != captainId) {
      throw StateError('Only the captain can delete the clan.');
    }

    // Clear `clan_id` on every member + invitee.
    final members = await _supabase
        .from('clan_members')
        .select('user_id')
        .eq('clan_id', clanId);
    final invites = await _supabase
        .from('clan_invites')
        .select('user_id')
        .eq('clan_id', clanId);
    final allIds = <String>{
      for (final r in members as List)
        (r as Map<String, dynamic>)['user_id'] as String,
      for (final r in invites as List)
        (r as Map<String, dynamic>)['user_id'] as String,
    };
    for (final uid in allIds) {
      await _supabase
          .from('profiles')
          .update({'clan_id': null})
          .eq('id', uid)
          .eq('clan_id', clanId);
    }

    // Cancel active/pending clan battles where this clan is on either side.
    await _supabase
        .from('clan_battles')
        .update({'status': 'completed'})
        .neq('status', 'completed')
        .or('clan_a.clan_id.eq.$clanId,clan_b.clan_id.eq.$clanId');
    // (The `or` filter above uses the embedded clan_battle_teams shape — if
    // PostgREST can't resolve it, the alternate is two separate updates via
    // explicit ID lookup. Keeping it simple for MVP.)

    // Notify former members.
    final clanName = clan['name'] as String? ?? 'your clan';
    for (final uid in allIds) {
      if (uid == captainId) continue;
      await _supabase.from('notifications').insert({
        'user_id': uid,
        'type': 'other',
        'title': 'Clan Disbanded',
        'body': '"$clanName" was deleted by the captain',
        'data': {'clan_id': clanId, 'from_user_id': captainId},
      });
    }

    // Cascade-delete via FK takes care of clan_members + clan_invites rows.
    await _supabase.from('clans').delete().eq('id', clanId);
  }

  /// Backwards-compat wrapper around [kickMember] using the captain as actor.
  Future<void> removeMember({
    required String clanId,
    required String userId,
  }) async {
    final clan = await _supabase
        .from('clans')
        .select('captain_id')
        .eq('id', clanId)
        .maybeSingle();
    if (clan == null) return;
    await kickMember(
      clanId: clanId,
      actorId: clan['captain_id'] as String,
      targetId: userId,
    );
  }

  // ---------------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------------

  /// Live stream of a single clan with its members + invites embedded.
  /// We listen to the `clans` row for change ticks and re-fetch the full
  /// joined shape on each tick (members and invites change via separate
  /// tables, so the realtime tick triggers a refresh).
  Stream<ClanModel?> watchClan(String clanId) {
    return _supabase
        .from('clans')
        .stream(primaryKey: ['id'])
        .eq('id', clanId)
        .asyncMap((rows) async {
          if (rows.isEmpty) return null;
          return _fetchClan(clanId);
        });
  }

  Future<ClanModel?> _fetchClan(String clanId) async {
    final raw = await _supabase
        .from('clans')
        .select(
            '*, clan_members(user_id, role), clan_invites(user_id)')
        .eq('id', clanId)
        .maybeSingle();
    if (raw == null) return null;
    return ClanModel.fromSupabaseRow(raw);
  }

  /// Stream the clan's members, hydrated with profile display name + avatar.
  Stream<List<ClanMember>> watchMembers(String clanId) {
    return _supabase
        .from('clan_members')
        .stream(primaryKey: ['clan_id', 'user_id'])
        .eq('clan_id', clanId)
        .asyncMap((rows) async {
          if (rows.isEmpty) return <ClanMember>[];
          // Need the profile fields too — re-fetch with the join. PostgREST
          // can't embed when the stream is filtered by a non-FK column on
          // the embed, so we manually fetch the profile rows in a batch.
          final userIds =
              rows.map((r) => r['user_id'] as String).toList();
          final profilesRaw = await _supabase
              .from('profiles_public')
              .select('id, display_name, preferred_name, avatar_url')
              .inFilter('id', userIds);
          final byId = <String, Map<String, dynamic>>{
            for (final p in profilesRaw as List)
              (p as Map<String, dynamic>)['id'] as String: p,
          };
          return rows
              .map((r) => ClanMember.fromSupabaseRow({
                    ...r,
                    'profiles': byId[r['user_id']],
                  }))
              .toList();
        });
  }

  /// Stream clans where the current user has a pending invite.
  Stream<List<ClanModel>> watchIncomingClanInvites(String userId) {
    return _supabase
        .from('clan_invites')
        .stream(primaryKey: ['clan_id', 'user_id'])
        .eq('user_id', userId)
        .asyncMap((rows) async {
          final clanIds =
              rows.map((r) => r['clan_id'] as String).toList();
          if (clanIds.isEmpty) return <ClanModel>[];
          final clansRaw = await _supabase
              .from('clans')
              .select(
                  '*, clan_members(user_id, role), clan_invites(user_id)')
              .inFilter('id', clanIds);
          return (clansRaw as List)
              .map((c) =>
                  ClanModel.fromSupabaseRow(c as Map<String, dynamic>))
              .toList();
        });
  }

  Future<List<ClanModel>> searchClans(String query) async {
    final q = query.trim().toUpperCase();
    final supaQ = _supabase
        .from('clans')
        .select('*, clan_members(user_id, role), clan_invites(user_id)');

    final rows = q.startsWith('#')
        ? await supaQ.eq('clan_id_code', q).limit(5)
        : await supaQ.ilike('name', '$query%').limit(10);
    return (rows as List)
        .map((c) =>
            ClanModel.fromSupabaseRow(c as Map<String, dynamic>))
        .toList();
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
    AppLogger.clan.i('createClanBattle', fields: {
      'clanAId': clanAId,
      'clanBId': clanBId,
      'days': durationDays,
      'battleType': battleType,
    });
    final now = DateTime.now();
    final battleRow = await _supabase
        .from('clan_battles')
        .insert({
          'status': 'active',
          'battle_type': battleType,
          'start_time': now.toUtc().toIso8601String(),
          'end_time':
              now.add(Duration(days: durationDays)).toUtc().toIso8601String(),
          'duration_days': durationDays,
        })
        .select('id')
        .single();
    final battleId = battleRow['id'] as String;

    await _supabase.from('clan_battle_teams').insert([
      {
        'clan_battle_id': battleId,
        'clan_id': clanAId,
        'clan_name': clanAName,
        'team_label': 'A',
        'total_steps': 0,
      },
      {
        'clan_battle_id': battleId,
        'clan_id': clanBId,
        'clan_name': clanBName,
        'team_label': 'B',
        'total_steps': 0,
      },
    ]);

    // Stamp active_battle_id on both clans.
    await _supabase
        .from('clans')
        .update({'active_battle_id': battleId})
        .inFilter('id', [clanAId, clanBId]);

    return battleId;
  }

  Stream<ClanBattleModel?> watchClanBattle(String battleId) {
    return _supabase
        .from('clan_battles')
        .stream(primaryKey: ['id'])
        .eq('id', battleId)
        .asyncMap((rows) async {
          if (rows.isEmpty) return null;
          final raw = await _supabase
              .from('clan_battles')
              .select('*, clan_battle_teams(*)')
              .eq('id', battleId)
              .maybeSingle();
          if (raw == null) return null;
          return ClanBattleModel.fromSupabaseRow(raw);
        });
  }

  Future<List<ClanBattleModel>> getAvailableClanBattles() async {
    final rows = await _supabase
        .from('clan_battles')
        .select('*, clan_battle_teams(*)')
        .eq('status', 'pending')
        .order('start_time', ascending: false)
        .limit(20);
    return (rows as List)
        .map((c) =>
            ClanBattleModel.fromSupabaseRow(c as Map<String, dynamic>))
        .toList();
  }
}
