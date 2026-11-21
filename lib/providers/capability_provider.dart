import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/capability_service.dart';
import 'app_lifecycle_provider.dart';
import 'step_provider.dart';

/// Singleton [CapabilityService], wired to the same service instances the
/// step pipeline uses. It must be the same ones: the native pedometer's
/// "has this stream emitted yet" state lives on its instance, so a second
/// copy would always look unavailable.
final capabilityServiceProvider = Provider<CapabilityService>((ref) {
  return CapabilityService(
    health: ref.watch(healthServiceProvider),
    native: ref.watch(nativeStepServiceProvider),
    fit: ref.watch(googleFitServiceProvider),
    aggregator: ref.watch(stepAggregatorProvider),
  );
});

/// Bumped after a successful lock resolution to re-run every
/// [capabilityUnlockedProvider] watching it.
///
/// Permission state changes outside Dart's view — the user taps Allow in a
/// system alert, or flips a toggle in Settings and comes back — so there is
/// nothing to listen to. This is the manual invalidation signal.
final capabilityRefreshProvider = StateProvider<int>((ref) => 0);

/// Whether [capability] is currently available.
///
/// Returns `true` while loading so a metric never flashes a lock on the way
/// to being readable — a brief correct number beats a brief wrong padlock.
final capabilityUnlockedProvider =
    FutureProvider.family<bool, AppCapability>((ref, capability) async {
  ref.watch(capabilityRefreshProvider);
  // Re-probe whenever the app comes back to the foreground: that is
  // exactly when a user returns from Settings having flipped a toggle.
  ref.watch(appLifecycleStateProvider);
  return ref.watch(capabilityServiceProvider).isUnlocked(capability);
});
