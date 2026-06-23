import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/clan_model.dart';
import '../models/clan_battle_model.dart';
import '../services/clan_service.dart';
import 'auth_provider.dart';

final clanServiceProvider = Provider<ClanService>((ref) => ClanService());

/// The current user's clan (from their profile clanId).
final currentClanProvider = StreamProvider<ClanModel?>((ref) {
  final user = ref.watch(currentUserProvider).valueOrNull;
  if (user == null || user.clanId == null) return Stream.value(null);
  return ref.read(clanServiceProvider).watchClan(user.clanId!);
});

/// Whether the user is in a clan. Tri-state:
///   • `null`  — profile still loading; UI should show a spinner, NOT the
///               "create a clan" screen. Reading from [currentClanProvider]
///               (a derived stream) caused a brief flash of the create
///               screen on tab open because `valueOrNull` is null while
///               the stream is in `AsyncLoading`.
///   • `true`  — profile resolved, clanId is set.
///   • `false` — profile resolved, clanId is null (truly clan-less).
///
/// Derived from the cached profile so we know the answer the instant the
/// user opens the Clan tab — no second async hop through [currentClanProvider].
final hasClanProvider = Provider<bool?>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user.isLoading) return null;
  return user.valueOrNull?.clanId != null;
});

/// Clan members stream.
final clanMembersProvider = StreamProvider<List<ClanMember>>((ref) {
  final clan = ref.watch(currentClanProvider).valueOrNull;
  if (clan == null) return Stream.value([]);
  return ref.read(clanServiceProvider).watchMembers(clan.clanId);
});

/// Active clan battle stream (if any).
final activeClanBattleProvider = StreamProvider<ClanBattleModel?>((ref) {
  final clan = ref.watch(currentClanProvider).valueOrNull;
  if (clan == null || clan.activeBattleId == null) return Stream.value(null);
  return ref.read(clanServiceProvider).watchClanBattle(clan.activeBattleId!);
});

/// Whether the current user is the clan captain.
final isClanCaptainProvider = Provider<bool>((ref) {
  final uid = ref.watch(authStateProvider).valueOrNull?.id;
  final clan = ref.watch(currentClanProvider).valueOrNull;
  if (uid == null || clan == null) return false;
  return clan.captainId == uid;
});

/// Stream of clans where the current user has a pending invite.
final incomingClanInvitesProvider = StreamProvider<List<ClanModel>>((ref) {
  final uid = ref.watch(authStateProvider).valueOrNull?.id;
  if (uid == null) return Stream.value([]);
  return ref.read(clanServiceProvider).watchIncomingClanInvites(uid);
});

/// Count of incoming clan invites for badge display.
final incomingClanInviteCountProvider = Provider<int>((ref) {
  return ref.watch(incomingClanInvitesProvider).valueOrNull?.length ?? 0;
});
