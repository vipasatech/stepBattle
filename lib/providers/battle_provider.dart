import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/battle_model.dart';
import '../services/battle_service.dart';
import '../utils/realtime_retry.dart';
import 'auth_provider.dart';

/// Battle service singleton.
final battleServiceProvider = Provider<BattleService>((ref) {
  return BattleService();
});

/// True when at least one of the realtime battle streams is currently
/// in retry/backoff mode. Surfaced as a "Reconnecting…" pill on the
/// Battles tab so users don't see raw exception text.
final battlesReconnectingProvider = StateProvider<bool>((ref) => false);

/// Stream of all battles for the current user (all statuses, sorted by time).
///
/// Wrapped with [retryingRealtimeStream] so transient Supabase realtime
/// failures (channel timeouts, websocket drops) auto-retry with backoff
/// instead of putting the StreamProvider into an error state. The error
/// state is what was rendering "RealtimeSubscribeException(timedOut)"
/// directly in the BattlesScreen empty state.
final allBattlesProvider = StreamProvider<List<BattleModel>>((ref) {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return Stream.value(const <BattleModel>[]);

  final service = ref.read(battleServiceProvider);
  return retryingRealtimeStream<List<BattleModel>>(
    factory: () => service.watchAllBattles(user.id),
    debugLabel: 'allBattles',
    onReconnectingChanged: (reconnecting) {
      ref.read(battlesReconnectingProvider.notifier).state = reconnecting;
    },
  );
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
  final service = ref.read(battleServiceProvider);
  return retryingRealtimeStream<BattleModel?>(
    factory: () => service.watchBattle(battleId),
    debugLabel: 'battleDetail:$battleId',
    onReconnectingChanged: (reconnecting) {
      ref.read(battlesReconnectingProvider.notifier).state = reconnecting;
    },
  );
});

/// Stream of pending battle invites for the current user (they haven't accepted yet).
final incomingBattleInvitesProvider =
    StreamProvider<List<BattleModel>>((ref) {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return Stream.value(const <BattleModel>[]);
  final service = ref.read(battleServiceProvider);
  return retryingRealtimeStream<List<BattleModel>>(
    factory: () => service.watchIncomingInvites(user.id),
    debugLabel: 'incomingInvites',
    onReconnectingChanged: (reconnecting) {
      ref.read(battlesReconnectingProvider.notifier).state = reconnecting;
    },
  );
});

/// Count of unread battle invites for badge display.
final incomingBattleInviteCountProvider = Provider<int>((ref) {
  return ref.watch(incomingBattleInvitesProvider).valueOrNull?.length ?? 0;
});
