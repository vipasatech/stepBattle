import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/battle_model.dart';
import '../providers/battle_provider.dart';
import '../utils/app_logger.dart';

/// Root-level provider that watches every battle the current user is
/// part of and remembers the last-seen status per battle. When it sees
/// a transition to [BattleStatus.active] for a battle the user hadn't
/// already seen active, it emits the battle id via [justActivatedProvider]
/// once — the app-level GoRouter listener picks it up and pushes
/// `/battle-ground/{id}` when the app is foregrounded.
///
/// Design notes:
///   • Held alive by `ref.watch(battleActivationDetectorProvider)` at
///     the app root so the state persists across route changes.
///   • First emission of `allBattlesProvider` is a "seed" — battles
///     that are ALREADY active on cold-boot don't fire a nav (user
///     would be surprised by an unrequested route push on app open).
///   • Deep-linked by battle id, so if the user is already in that
///     arena the router just no-ops the same-route push.
///
/// This is the "foreground detector" half of item C from the
/// arena-auto-nav design. The "backgrounded via push" half is served
/// by the existing FCM tap handler (`extractRoute` for `battle_started`
/// / `battle_auto_started` already routes to `/battles`, and can be
/// extended to `/battle-ground/{id}` if needed).
final battleActivationDetectorProvider =
    NotifierProvider<BattleActivationDetector, String?>(
  BattleActivationDetector.new,
);

class BattleActivationDetector extends Notifier<String?> {
  /// Wall-clock grace window at boot during which detected transitions
  /// are silently absorbed into the seed instead of firing a nav.
  /// Covers the race where Hive cache is empty (fresh install, cache
  /// cleared, first login on this device) and the first Supabase
  /// realtime emit brings in an already-active battle — the OLD
  /// `_seeded` flag flipped true on an empty batch, so the real
  /// emission looked like a fresh activation.
  ///
  /// 3 seconds is enough for the first cached emission + first live
  /// hydration to both land on a normal network. Any battle activating
  /// AFTER these 3 seconds is a real user-visible transition and does
  /// fire the nav.
  static const _seedGracePeriod = Duration(seconds: 3);

  DateTime? _bootedAt;

  /// True once we've seen at least one NON-EMPTY batch. Prevents the
  /// exact bug reported 2026-08-13 ("cold-start briefly flashes the
  /// battle arena shimmer before Home tab loads"): with the old
  /// implementation, an empty first emission from a cache miss flipped
  /// `_seeded = true`, and the follow-up realtime emit carrying an
  /// active battle was treated as a fresh activation → auto-nav.
  bool _seeded = false;

  final Map<String, BattleStatus> _lastStatus = {};

  @override
  String? build() {
    _bootedAt = DateTime.now();
    _seeded = false;
    _lastStatus.clear();
    // Subscribe to the ALL-battles stream. Any change fires _ingest.
    ref.listen<List<BattleModel>>(activeBattlesProvider, (prev, next) {
      _ingest(next);
    }, fireImmediately: true);
    // Also observe pending/scheduled → active transitions (a battle
    // that JUST activated may briefly appear in scheduled between
    // ticks). The scheduled stream fires when status flips.
    ref.listen<List<BattleModel>>(scheduledBattlesProvider, (prev, next) {
      _ingest(next);
    }, fireImmediately: true);
    return null;
  }

  void _ingest(List<BattleModel> batch) {
    final now = DateTime.now();
    final booted = _bootedAt ?? now;
    final inGracePeriod = now.difference(booted) < _seedGracePeriod;

    if (!_seeded) {
      // Seed: record CURRENT status for every battle so we don't fire
      // a nav on cold-boot for battles already active before the
      // detector attached.
      for (final b in batch) {
        _lastStatus[b.battleId] = b.status;
      }
      // Only mark seeded once we've seen a NON-EMPTY batch. An empty
      // first emission (Hive cache miss, fresh install, first login
      // on this device) leaves _seeded=false so the next populated
      // realtime emission also enters this branch and seeds correctly
      // — not misinterpreted as a fresh activation.
      if (batch.isNotEmpty) {
        _seeded = true;
      }
      return;
    }

    for (final b in batch) {
      final prev = _lastStatus[b.battleId];
      _lastStatus[b.battleId] = b.status;
      // Belt-and-suspenders grace period: even after seed, silently
      // absorb transitions during the first `_seedGracePeriod`. Covers
      // races where seeding finished on the first (real) batch but a
      // slower stream still lands during boot.
      if (inGracePeriod) continue;
      // Transition INTO active from anything else → publish battleId.
      // The router listener consumes it and immediately clears the
      // state so a subsequent identical status doesn't re-fire.
      if (b.status == BattleStatus.active && prev != BattleStatus.active) {
        AppLogger.battle.i('battleActivation:detected', fields: {
          'battleId': b.battleId,
          'prev': prev?.name ?? 'null',
        });
        state = b.battleId;
      }
    }
  }

  /// Called by the router listener after it has navigated. Clears the
  /// signal so the next activation can trigger cleanly.
  void consume() {
    if (state != null) state = null;
  }
}
