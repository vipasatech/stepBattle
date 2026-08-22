import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/family_membership_model.dart';
import '../services/family_service.dart';
import 'auth_provider.dart';

/// Service singleton for the write path (invite / accept / decline /
/// leave / boot).
final familyServiceProvider = Provider<FamilyService>((ref) {
  return FamilyService();
});

/// Live stream of every `family_memberships` row the current user is
/// party to — either as `owner_id` or `member_id`.
///
/// Supabase realtime `.stream()` supports only ONE filter per
/// subscription, so we open two subs (one per role) and merge them
/// client-side. Two `.eq()`-scoped subscriptions cost less than the
/// previous filter-less table-wide stream, and the payload is
/// bounded to rows the current user is party to instead of relying
/// on realtime RLS filtering to drop every foreign row.
///
/// `.autoDispose` — most users never open Family Pass; the previous
/// non-autoDispose stream held the channels open for the whole
/// session even for signed-in users who never touch the feature.
/// The three downstream views (family members / pending-sent /
/// incoming) are also derived and inherit disposal.
final _familyMembershipsStreamProvider =
    StreamProvider.autoDispose<List<FamilyMembership>>((ref) {
  final uid = ref.watch(authStateProvider).valueOrNull?.id;
  if (uid == null || uid.isEmpty) {
    return Stream.value(const <FamilyMembership>[]);
  }
  final supabase = Supabase.instance.client;
  final controller = StreamController<List<FamilyMembership>>();
  List<Map<String, dynamic>> latestAsOwner = const [];
  List<Map<String, dynamic>> latestAsMember = const [];

  void emit() {
    // Dedupe by primary key — a row can't legitimately match both
    // filters (`owner_id` and `member_id` are distinct columns), but
    // the map preserves the last-write-wins semantic if it ever did.
    final merged = <String, FamilyMembership>{
      for (final r in latestAsOwner)
        r['id'] as String: FamilyMembership.fromSupabaseRow(r),
      for (final r in latestAsMember)
        r['id'] as String: FamilyMembership.fromSupabaseRow(r),
    };
    controller.add(merged.values.toList());
  }

  final subOwner = supabase
      .from('family_memberships')
      .stream(primaryKey: ['id'])
      .eq('owner_id', uid)
      .listen((rows) {
    latestAsOwner = rows;
    emit();
  });

  final subMember = supabase
      .from('family_memberships')
      .stream(primaryKey: ['id'])
      .eq('member_id', uid)
      .listen((rows) {
    latestAsMember = rows;
    emit();
  });

  ref.onDispose(() {
    subOwner.cancel();
    subMember.cancel();
    controller.close();
  });

  return controller.stream;
});

/// Active members OF the current user's family — the owner-side view.
/// Empty when the current user isn't a family owner OR has no
/// accepted members yet. `.autoDispose` because the base stream is
/// autoDispose — Riverpod requires downstream dependents to inherit.
final familyMembersProvider =
    Provider.autoDispose<List<FamilyMembership>>((ref) {
  final uid = ref.watch(authStateProvider).valueOrNull?.id;
  final all =
      ref.watch(_familyMembershipsStreamProvider).valueOrNull ??
          const <FamilyMembership>[];
  return all
      .where((m) => m.ownerId == uid && m.isActive)
      .toList();
});

/// Pending invites the current user has SENT that haven't been
/// answered yet — shows on the owner's Manage-Family screen.
final pendingSentInvitesProvider =
    Provider.autoDispose<List<FamilyMembership>>((ref) {
  final uid = ref.watch(authStateProvider).valueOrNull?.id;
  final all =
      ref.watch(_familyMembershipsStreamProvider).valueOrNull ??
          const <FamilyMembership>[];
  return all
      .where((m) => m.ownerId == uid && m.isPending)
      .toList();
});

/// Pending invites the current user has RECEIVED (member view) —
/// surfaces as an "Incoming Family Invite" card on the Battles tab.
final incomingFamilyInvitesProvider =
    Provider.autoDispose<List<FamilyMembership>>((ref) {
  final uid = ref.watch(authStateProvider).valueOrNull?.id;
  final all =
      ref.watch(_familyMembershipsStreamProvider).valueOrNull ??
          const <FamilyMembership>[];
  return all
      .where((m) => m.memberId == uid && m.isPending)
      .toList();
});
