import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/app_logger.dart';

/// Family Pass management — invite / accept / decline / leave / boot.
///
/// The row shape lives in `public.family_memberships` (migration
/// 0031). Owner is `owner_id`; member is `member_id`; `status`
/// transitions:
///   `pending` → `active` (member accepts)
///   `pending` → `declined` (member declines)
///   `active`  → `removed` (member leaves or owner boots)
///
/// Server-side trigger `enforce_family_max_members` caps active seats
/// at 3 per owner (4 total including the owner) — a 4th accept
/// throws and this service re-raises so the UI can show a friendly
/// error.
class FamilyService {
  final SupabaseClient _supabase;

  FamilyService({SupabaseClient? supabase})
      : _supabase = supabase ?? Supabase.instance.client;

  /// Owner invites another user by their `#USERCODE`. Creates a
  /// `pending` row that the invitee sees in their Battles tab.
  ///
  /// Throws [StateError] with a UI-friendly message on:
  ///   * unknown user code
  ///   * inviting yourself
  ///   * already-invited (duplicate `(owner_id, member_id)`)
  Future<void> inviteByUserCode({
    required String ownerId,
    required String memberUserCode,
  }) async {
    final normalizedCode = memberUserCode.trim().toUpperCase();
    if (normalizedCode.isEmpty) {
      throw StateError('Enter a user code');
    }
    final memberRow = await _supabase
        .from('profiles_public')
        .select('id')
        .eq('user_code', normalizedCode)
        .maybeSingle();
    if (memberRow == null) {
      throw StateError('No user found with code $normalizedCode');
    }
    final memberId = memberRow['id'] as String;
    if (memberId == ownerId) {
      throw StateError('You can\'t invite yourself');
    }
    try {
      await _supabase.from('family_memberships').insert({
        'owner_id': ownerId,
        'member_id': memberId,
        'status': 'pending',
        'invited_via': 'user_code',
      });
      AppLogger.session.i('family.invite:sent', fields: {
        'ownerId': ownerId,
        'memberId': memberId,
        'via': 'user_code',
      });
    } on PostgrestException catch (e) {
      // 23505 = unique_violation on (owner_id, member_id)
      if (e.code == '23505') {
        throw StateError('You\'ve already invited this user');
      }
      rethrow;
    }
  }

  /// Invitee accepts an invite. Two DB writes:
  ///   1. Membership row goes `pending` → `active` (trigger enforces
  ///      the 3-active-member cap).
  ///   2. Member's profile is bumped to `subscription_tier = 'family'`,
  ///      inheriting the owner's `expires_at` + billing period, and
  ///      `family_owner_id` is set.
  ///
  /// NOTE: if the accepting user was previously on Pro (their own
  /// paid subscription), that state is OVERWRITTEN — accepting a
  /// family invite replaces any prior subscription. For v1 the UI
  /// should warn before firing this if the user is on a paid tier.
  Future<void> acceptInvite({
    required String membershipId,
    required String memberId,
    required String ownerId,
  }) async {
    // 1. Update membership row.
    await _supabase.from('family_memberships').update({
      'status': 'active',
      'accepted_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', membershipId).eq('member_id', memberId);

    // 2. Inherit the owner's subscription window.
    final ownerRow = await _supabase
        .from('profiles_public')
        .select(
            'subscription_expires_at, subscription_billing_period')
        .eq('id', ownerId)
        .maybeSingle();
    await _supabase.from('profiles').update({
      'subscription_tier': 'family',
      'subscription_expires_at':
          ownerRow?['subscription_expires_at'],
      'subscription_billing_period':
          ownerRow?['subscription_billing_period'],
      'family_owner_id': ownerId,
    }).eq('id', memberId);

    AppLogger.session.i('family.invite:accepted',
        fields: {'membershipId': membershipId, 'memberId': memberId});
  }

  /// Invitee declines. Row goes `pending` → `declined`. Owner can
  /// re-invite later (they'd hit the "already invited" guard first,
  /// which they can bypass by deleting the declined row — v2
  /// enhancement).
  Future<void> declineInvite({
    required String membershipId,
    required String memberId,
  }) async {
    await _supabase.from('family_memberships').update({
      'status': 'declined',
    }).eq('id', membershipId).eq('member_id', memberId);
    AppLogger.session.i('family.invite:declined',
        fields: {'membershipId': membershipId, 'memberId': memberId});
  }

  /// Member leaves the family. Reverts to Free.
  Future<void> leaveFamily({required String memberId}) async {
    final row = await _supabase
        .from('family_memberships')
        .select('id')
        .eq('member_id', memberId)
        .eq('status', 'active')
        .maybeSingle();
    if (row == null) return;
    final id = row['id'] as String;

    await _supabase.from('family_memberships').update({
      'status': 'removed',
      'removed_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', id);

    await _supabase.from('profiles').update({
      'subscription_tier': 'free',
      'subscription_expires_at': null,
      'subscription_billing_period': null,
      'family_owner_id': null,
    }).eq('id', memberId);

    AppLogger.session
        .i('family.leave:done', fields: {'memberId': memberId});
  }

  /// Owner boots a member from the family. Same DB effect as
  /// [leaveFamily] but keyed on the owner's uid (RLS enforces owner
  /// authority via the family_memberships_owner_update policy).
  Future<void> bootMember({
    required String membershipId,
    required String memberId,
    required String ownerId,
  }) async {
    await _supabase.from('family_memberships').update({
      'status': 'removed',
      'removed_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', membershipId).eq('owner_id', ownerId);

    await _supabase.from('profiles').update({
      'subscription_tier': 'free',
      'subscription_expires_at': null,
      'subscription_billing_period': null,
      'family_owner_id': null,
    }).eq('id', memberId);

    AppLogger.session.i('family.boot:done', fields: {
      'ownerId': ownerId,
      'memberId': memberId,
    });
  }

  /// Owner cancels a still-pending invite. Fully deletes the row so
  /// the "unique(owner_id, member_id)" guard doesn't block a
  /// re-invite. Idempotent — no-op if the row doesn't exist.
  Future<void> cancelPendingInvite({
    required String membershipId,
    required String ownerId,
  }) async {
    await _supabase
        .from('family_memberships')
        .delete()
        .eq('id', membershipId)
        .eq('owner_id', ownerId)
        .eq('status', 'pending');
    AppLogger.session.i('family.invite:cancelled', fields: {
      'membershipId': membershipId,
      'ownerId': ownerId,
    });
  }
}
