import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/battle_model.dart';
import '../services/battle_service.dart';
import 'auth_provider.dart';

/// Battle service singleton.
final battleServiceProvider = Provider<BattleService>((ref) {
  return BattleService();
});

/// Stream of all battles for the current user (all statuses, sorted by time).
final allBattlesProvider = StreamProvider<List<BattleModel>>((ref) {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return Stream.value([]);
  return ref.read(battleServiceProvider).watchAllBattles(user.uid);
});

/// Active battles only.
final activeBattlesProvider = Provider<List<BattleModel>>((ref) {
  final all = ref.watch(allBattlesProvider).valueOrNull ?? [];
  return all.where((b) => b.status == BattleStatus.active).toList();
});

/// Scheduled (pending) battles.
final scheduledBattlesProvider = Provider<List<BattleModel>>((ref) {
  final all = ref.watch(allBattlesProvider).valueOrNull ?? [];
  return all.where((b) => b.status == BattleStatus.pending).toList();
});

/// Completed battles.
final completedBattlesProvider = Provider<List<BattleModel>>((ref) {
  final all = ref.watch(allBattlesProvider).valueOrNull ?? [];
  return all.where((b) => b.status == BattleStatus.completed).toList();
});

/// The first active battle (for Home screen card).
final firstActiveBattleProvider = Provider<BattleModel?>((ref) {
  final active = ref.watch(activeBattlesProvider);
  return active.isEmpty ? null : active.first;
});

/// The most recent completed battle (for Home screen fallback).
final lastCompletedBattleProvider = Provider<BattleModel?>((ref) {
  final completed = ref.watch(completedBattlesProvider);
  return completed.isEmpty ? null : completed.first;
});

/// Stream a single battle by ID (for battle detail / live view).
final battleDetailProvider =
    StreamProvider.family<BattleModel?, String>((ref, battleId) {
  return ref.read(battleServiceProvider).watchBattle(battleId);
});

/// Stream of pending battle invites for the current user (they haven't accepted yet).
final incomingBattleInvitesProvider =
    StreamProvider<List<BattleModel>>((ref) {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return Stream.value([]);
  return ref
      .read(battleServiceProvider)
      .watchIncomingInvites(user.uid);
});

/// Count of unread battle invites for badge display.
final incomingBattleInviteCountProvider = Provider<int>((ref) {
  return ref.watch(incomingBattleInvitesProvider).valueOrNull?.length ?? 0;
});
