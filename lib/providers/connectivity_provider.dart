import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Live-updating boolean: `true` when the device has any active network
/// interface (WiFi / mobile / ethernet), `false` when it doesn't.
///
/// Streams from [Connectivity.onConnectivityChanged] and seeds with a
/// one-shot [Connectivity.checkConnectivity] so a widget that watches
/// this doesn't spend the first frame in the loading state.
///
/// Note: this reflects the OS's view of network reachability, not
/// whether Supabase is actually reachable. A captive-portal WiFi or
/// a DNS failure would still report `true`. Adequate for UI hints
/// like "show an offline icon on the leaderboard card".
final isOnlineProvider = StreamProvider<bool>((ref) async* {
  final conn = Connectivity();
  // Seed with the current snapshot so the first frame doesn't flash a
  // "loading" state before the stream fires.
  try {
    final initial = await conn.checkConnectivity();
    yield initial.any((r) => r != ConnectivityResult.none);
  } catch (_) {
    // If the platform check throws (rare), assume online — being
    // over-optimistic here just means the offline-hint UI is delayed
    // by one connectivity event, not that anything breaks.
    yield true;
  }
  yield* conn.onConnectivityChanged.map(
    (results) => results.any((r) => r != ConnectivityResult.none),
  );
});
