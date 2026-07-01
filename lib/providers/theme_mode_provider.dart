import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../services/native_step_service.dart';

/// Hive key inside the shared `step_tracker` box. We piggy-back on the
/// already-open box rather than opening a new one — saves a cold-start
/// roundtrip.
const String _kThemeModeKey = 'pref_theme_mode';

/// Persisted user choice for [ThemeMode]: light / dark / system. Synchronous
/// load (box is opened in `main()` before runApp) so the first frame uses
/// the saved value with no flicker.
class ThemeModePrefController extends StateNotifier<ThemeMode> {
  ThemeModePrefController() : super(_load());

  static ThemeMode _load() {
    final box = Hive.box(NativeStepService.boxName);
    final raw = box.get(_kThemeModeKey) as String?;
    return switch (raw) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> set(ThemeMode mode) async {
    if (mode == state) return;
    // Flip the UI first — this is what the user is waiting on. The
    // Hive write happens in the background; if it fails the toggle is
    // lost on next launch but the user gets an instant response. The
    // previous "await Hive then update state" ordering felt like a
    // 1-5 s delay on slower devices because the platform-channel
    // roundtrip blocked the rebuild.
    state = mode;
    try {
      await Hive.box(NativeStepService.boxName)
          .put(_kThemeModeKey, mode.name);
    } catch (_) {
      // Persistence is best-effort.
    }
  }
}

final themeModePrefProvider =
    StateNotifierProvider<ThemeModePrefController, ThemeMode>(
  (ref) => ThemeModePrefController(),
);
