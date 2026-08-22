import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/pricing.dart';

/// The currency the user's Buy-XP UI shows prices in. Resolution order:
///   1. Explicit user override stored in SharedPreferences (`selected_currency`)
///   2. Device locale country code → [PriceCurrency.fromCountryCode]
///   3. USD fallback
///
/// Set via [CurrencyNotifier.setCurrency] from a Settings row (or
/// wherever we surface the picker). Reads are cheap — the state is a
/// simple enum value.
final selectedCurrencyProvider =
    StateNotifierProvider<CurrencyNotifier, PriceCurrency>((ref) {
  return CurrencyNotifier();
});

class CurrencyNotifier extends StateNotifier<PriceCurrency> {
  static const _prefKey = 'selected_currency';

  CurrencyNotifier() : super(_initialFromPlatformLocale()) {
    // Async: prefer the stored override if one exists. If not, keep
    // the locale-derived default. Fire-and-forget so the constructor
    // stays synchronous.
    _hydrateFromPrefs();
  }

  /// Best-effort synchronous default based on the platform locale.
  /// Reads Platform.localeName (e.g. `en_US.UTF-8`, `hi_IN`) and pulls
  /// the region code out. Available on all Dart platforms without
  /// needing MediaQuery.
  static PriceCurrency _initialFromPlatformLocale() {
    try {
      final locale = Platform.localeName; // e.g. "en_IN", "en_US.UTF-8"
      // Extract the region — the two chars after the underscore or
      // hyphen. Handles both "en_IN" and "en-IN" separators.
      final match = RegExp(r'[_-]([A-Za-z]{2})').firstMatch(locale);
      final region = match?.group(1);
      return PriceCurrency.fromCountryCode(region);
    } catch (_) {
      return PriceCurrency.usd;
    }
  }

  Future<void> _hydrateFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_prefKey);
      if (stored == null) return;
      final match = PriceCurrency.values.firstWhere(
        (c) => c.code == stored,
        orElse: () => state,
      );
      if (match != state) {
        // Post-frame so we don't fire a state change during the first
        // provider build cycle — Riverpod complains about that.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) state = match;
        });
      }
    } catch (_) {
      // Non-fatal; keep the platform-locale default.
    }
  }

  /// Update the user's chosen currency + persist. Call from the
  /// Settings picker.
  Future<void> setCurrency(PriceCurrency c) async {
    state = c;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, c.code);
    } catch (_) {
      // Non-fatal; state is already updated in-memory.
    }
  }
}
