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

/// Whether the user is in a clan.
final hasClanProvider = Provider<bool>((ref) {
  return ref.watch(currentClanProvider).valueOrNull != null;
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
  final uid = ref.watch(authStateProvider).valueOrNull?.uid;
  final clan = ref.watch(currentClanProvider).valueOrNull;
  if (uid == null || clan == null) return false;
  return clan.captainId == uid;
});
