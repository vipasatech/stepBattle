import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../services/battleground_tile.dart';
import '../services/native_step_service.dart';

/// Hive key inside the shared `step_tracker` box. We piggy-back on the
/// already-open box rather than opening a new one — saves a few ms on
/// cold start.
const String _kArenaPackKey = 'pref_arena_pack';

/// User's chosen [ArenaPack]. Notifier reads/writes Hive synchronously
/// (the box is opened in `main()` before runApp) so the first build sees
/// the persisted value with no flash.
class ArenaPackPrefController extends StateNotifier<ArenaPack> {
  ArenaPackPrefController() : super(_load());

  static ArenaPack _load() {
    final box = Hive.box(NativeStepService.boxName);
    return ArenaPack.fromKey(box.get(_kArenaPackKey) as String?);
  }

  Future<void> set(ArenaPack pack) async {
    if (pack == state) return;
    // Flip the UI first, persist after (see ThemeModePrefController for
    // the same pattern + reasoning).
    state = pack;
    try {
      await Hive.box(NativeStepService.boxName)
          .put(_kArenaPackKey, pack.name);
    } catch (_) {}
  }
}

final arenaPackPrefProvider =
    StateNotifierProvider<ArenaPackPrefController, ArenaPack>(
  (ref) => ArenaPackPrefController(),
);
