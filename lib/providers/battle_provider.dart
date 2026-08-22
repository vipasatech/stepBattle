import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/battle_model.dart';
import '../repositories/battle_repository.dart';
import '../services/battle_service.dart';
import '../utils/app_logger.dart';
import '../utils/realtime_retry.dart';
import 'auth_provider.dart';

/// Battle service singleton. Owns the mutation surface (create, join,
/// leave). Reads flow through [battleRepositoryProvider] for
/// cache-then-network delivery.
final battleServiceProvider = Provider<BattleService>((ref) {
  return BattleService();
});

/// Cache-then-network battle repository. Caches the JOINed
/// battles-with-participants list so the Battles tab paints instantly
/// on cold boot instead of waiting for the two-hop realtime query.
final battleRepositoryProvider = Provider<BattleRepository>((ref) {
  return BattleRepository();
});

/// True when at least one of the realtime battle streams is currently
/// in retry/backoff mode. Surfaced as a "Reconnecting…" pill on the
/// Battles tab so users don't see raw exception text.
final battlesReconnectingProvider = StateProvider<bool>((ref) => false);

/// Stream of all battles for the current user (all statuses, sorted by time).
///
/// The repository's `watch()` internally wraps the Supabase realtime
/// subscription with `retryingRealtimeStream` so transient channel
/// timeouts / websocket drops auto-retry with backoff instead of
/// dropping the provider into an error state. The reconnecting flag
/// bubbles up here so the BattlesScreen can render its "Reconnecting…"
/// pill.
final allBattlesProvider = StreamProvider<List<BattleModel>>((ref) {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return Stream.value(const <BattleModel>[]);

  final repo = ref.read(battleRepositoryProvider);
  return repo.watch(user.id, onReconnectingChanged: (reconnecting) {
    ref.read(battlesReconnectingProvider.notifier).state = reconnecting;
  });
});

// -----------------------------------------------------------------------------
// Filtered views over [allBattlesProvider]. Each derived provider memoizes its
// output through a module-level cache so a parent-stream tick that doesn't
// actually change this bucket's filtered contents returns the SAME list
// instance — Riverpod's default identity equality then correctly skips
// notification for downstream watchers.
//
// Without this, `.where().toList()` produced a new List on every tick,
// which meant every 500 ms participant-step update rebuilt every widget
// that watched active/scheduled/completed — even sections whose data
// hadn't changed. Manual memoization is intentional: `Provider` doesn't
// have first-class output-memoization the way `Notifier` does, and the
// migration to `Notifier` for three providers isn't worth the surface-
// area change here.
// -----------------------------------------------------------------------------

/// Cheap content-fingerprint for a battle list — bucket rebuilds only
/// when the set of battles or their live step counts change. Deliberately
/// coarse: adding participants mid-battle or renames don't invalidate,
/// but neither of those happens in practice, and the widget tree updates
/// on the next real state change anyway.
List<Object?> _fingerprint(List<BattleModel> bs) {
  final out = <Object?>[];
  for (final b in bs) {
    out.add(b.battleId);
    out.add(b.status.index);
    // Include leader's step count (rank changes are the only mid-tick
    // visible change on a battle card). Ignore participant order —
    // BattleModel's `participants` list is already order-stable.
    for (final p in b.participants) {
      out.add(p.currentSteps);
    }
  }
  return out;
}

List<BattleModel>? _memoActive;
List<Object?>? _fpActive;
List<BattleModel>? _memoScheduled;
List<Object?>? _fpScheduled;
List<BattleModel>? _memoCompleted;
List<Object?>? _fpCompleted;
List<BattleModel>? _memoRecentCompleted;
List<Object?>? _fpRecentCompleted;

/// Active battles only.
final activeBattlesProvider = Provider<List<BattleModel>>((ref) {
  final all = ref.watch(allBattlesProvider).valueOrNull ?? const <BattleModel>[];
  final next = all.where((b) => b.status == BattleStatus.active).toList();
  final fp = _fingerprint(next);
  if (_memoActive != null && _listEquals(_fpActive, fp)) return _memoActive!;
  _memoActive = next;
  _fpActive = fp;
  return next;
});

/// Scheduled (pending) battles.
final scheduledBattlesProvider = Provider<List<BattleModel>>((ref) {
  final all = ref.watch(allBattlesProvider).valueOrNull ?? const <BattleModel>[];
  final next = all.where((b) => b.status == BattleStatus.pending).toList();
  final fp = _fingerprint(next);
  if (_memoScheduled != null && _listEquals(_fpScheduled, fp)) {
    return _memoScheduled!;
  }
  _memoScheduled = next;
  _fpScheduled = fp;
  return next;
});

/// Completed battles — full list. Used by the /battles/completed
/// history screen; the main Battles tab uses [recentCompletedBattlesProvider]
/// so it doesn't rebuild the 5-row preview every time a distant historical
/// row happens to be re-emitted by the stream.
final completedBattlesProvider = Provider<List<BattleModel>>((ref) {
  final all = ref.watch(allBattlesProvider).valueOrNull ?? const <BattleModel>[];
  final next = all.where((b) => b.status == BattleStatus.completed).toList();
  final fp = _fingerprint(next);
  if (_memoCompleted != null && _listEquals(_fpCompleted, fp)) {
    return _memoCompleted!;
  }
  _memoCompleted = next;
  _fpCompleted = fp;
  return next;
});

/// Lean top-5 of completed — the exact list the Battles tab preview
/// renders. Split from [completedBattlesProvider] so the preview only
/// rebuilds when one of the visible five actually changes; older
/// history churn doesn't affect it.
final recentCompletedBattlesProvider = Provider<List<BattleModel>>((ref) {
  final full = ref.watch(completedBattlesProvider);
  final next = full.take(5).toList();
  final fp = _fingerprint(next);
  if (_memoRecentCompleted != null &&
      _listEquals(_fpRecentCompleted, fp)) {
    return _memoRecentCompleted!;
  }
  _memoRecentCompleted = next;
  _fpRecentCompleted = fp;
  return next;
});

/// Element-wise `==` comparison — used as the equality check inside
/// the memoization above. `listEquals` from foundation is what we'd
/// use if BattleModel had a proper `==`, but the fingerprint approach
/// side-steps that requirement.
bool _listEquals(List<Object?>? a, List<Object?>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// True whenever the user has *any* battle-related content to
/// render. Used by the Battles tab body to decide between the empty
/// state and the real list. Watching this instead of the four
/// buckets individually means the body-level Consumer only rebuilds
/// on the empty ↔ non-empty transition, not on every step-count
/// tick inside an existing battle. `bool.==` handles the notify
/// suppression correctly on its own.
final hasAnyBattlesProvider = Provider<bool>((ref) {
  final incoming =
      ref.watch(incomingBattleInvitesProvider).valueOrNull ?? const [];
  final active = ref.watch(activeBattlesProvider);
  final scheduled = ref.watch(scheduledBattlesProvider);
  final completed = ref.watch(recentCompletedBattlesProvider);
  return incoming.isNotEmpty ||
      active.isNotEmpty ||
      scheduled.isNotEmpty ||
      completed.isNotEmpty;
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
///
/// `.autoDispose` — the stream tears down when the last listener unmounts
/// (user leaves the battle detail screen), so a lifetime of navigating
/// through many battles doesn't stack up N live realtime subscriptions.
final battleDetailProvider =
    StreamProvider.autoDispose.family<BattleModel?, String>((ref, battleId) {
  final service = ref.read(battleServiceProvider);
  return retryingRealtimeStream<BattleModel?>(
    factory: () => service.watchBattle(battleId),
    debugLabel: 'battleDetail:$battleId',
    category: LogCategory.battle,
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
    category: LogCategory.battle,
    onReconnectingChanged: (reconnecting) {
      ref.read(battlesReconnectingProvider.notifier).state = reconnecting;
    },
  );
});

/// Count of unread battle invites for badge display.
final incomingBattleInviteCountProvider = Provider<int>((ref) {
  return ref.watch(incomingBattleInvitesProvider).valueOrNull?.length ?? 0;
});

/// A user's battle wins vs total completed battles. Used to compute the
/// B/W Ratio shown on Profile + the Battles tab header.
///
/// Counts every `battle_participants` row where:
///   • user_id matches the queried user
///   • invite_status = 'accepted'  (rejected invites don't count)
///   • parent battle is in status 'completed' (we only score finished
///     battles — pending / scheduled / active are in-flight and
///     shouldn't move the ratio)
///
/// Returns `(wins: N, total: M)`. Cached per user so multiple widgets
/// reading the same user's stats share one query.
typedef BattleWinStats = ({int wins, int total});

final battleWinStatsProvider =
    FutureProvider.autoDispose.family<BattleWinStats, String>((ref, userId) async {
  try {
    final client = Supabase.instance.client;
    final rows = await client
        .from('battle_participants')
        .select('is_winner, battles!inner(status)')
        .eq('user_id', userId)
        .eq('invite_status', 'accepted')
        .eq('battles.status', 'completed');
    final list = rows as List;
    final total = list.length;
    final wins =
        list.where((r) => (r as Map)['is_winner'] == true).length;
    return (wins: wins, total: total);
  } catch (_) {
    return (wins: 0, total: 0);
  }
});

/// Convenience: B/W Ratio as a 0..1 fraction, or null when the user
/// has 0 completed battles (avoids "0%" looking like a sad stat for
/// new users).
double? battleWinRatioOf(BattleWinStats s) =>
    s.total == 0 ? null : s.wins / s.total;

/// One-shot fetch of every accepted participant's daily step goal, keyed
/// by userId. Used by the battle-ground arena to derive a step-anchored
/// positioning scale (leader hits the top of the arena at ~avg-goal ×
/// battle-duration-days steps).
///
/// Fetches once per arena open — battle re-emissions from realtime
/// (step-count updates) do NOT retrigger this because the set of
/// participants rarely changes mid-battle. If a fetch fails or a
/// participant's row is missing, that user falls back to the default
/// 8000-step goal.
final battleParticipantGoalsProvider = FutureProvider.autoDispose
    .family<Map<String, int>, String>((ref, battleId) async {
  final battle = await ref.watch(battleDetailProvider(battleId).future);
  if (battle == null) return const <String, int>{};
  final userIds = battle.participants
      .where((p) => p.inviteStatus == ParticipantInviteStatus.accepted)
      .map((p) => p.userId)
      .toSet()
      .toList();
  if (userIds.isEmpty) return const <String, int>{};

  // Cache-first: opponents in the arena are almost always the current
  // user's friends/family, which means their profile rows are already
  // in the Hive cache from a prior view (leaderboard, friends list,
  // battle card). We fill the goal map from the cache first, then
  // only round-trip Supabase for the userIds we couldn't answer
  // locally. On the hot path (re-opening an arena) this usually means
  // a zero-query outcome.
  final repo = ref.read(profileRepositoryProvider);
  final map = <String, int>{};
  final missing = <String>[];
  for (final id in userIds) {
    final cached = repo.readCached(id);
    if (cached != null) {
      map[id] = cached.dailyStepGoal;
    } else {
      missing.add(id);
    }
  }
  if (missing.isEmpty) return map;

  try {
    final client = Supabase.instance.client;
    final rows = await client
        .from('profiles_public')
        .select('id, daily_step_goal')
        .inFilter('id', missing);
    final list = rows as List;
    for (final r in list) {
      final m = r as Map;
      final id = m['id'] as String? ?? '';
      final goal = (m['daily_step_goal'] as num?)?.toInt() ?? 8000;
      if (id.isNotEmpty) map[id] = goal;
    }
    return map;
  } catch (e) {
    AppLogger.battle.w('battleParticipantGoals:fetchFailed',
        fields: {'battleId': battleId, 'err': e.toString()});
    return map;
  }
});
