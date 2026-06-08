import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/run_session_model.dart';
import '../services/run_tracking_service.dart';
import 'auth_provider.dart';
import 'step_provider.dart';

/// Singleton RunTrackingService. Disposed when the auth user changes (sign
/// out → new service for the next sign-in).
final runTrackingServiceProvider = Provider<RunTrackingService>((ref) {
  final svc = RunTrackingService(
    native: ref.watch(nativeStepServiceProvider),
  );
  ref.onDispose(svc.dispose);
  return svc;
});

/// Live state of the running Track session, or null when nothing is active.
/// Emits ~every 2 seconds while a session is in flight (from
/// RunTrackingService's internal timer + GPS stream).
final activeRunSessionProvider = StreamProvider<RunSession?>((ref) {
  final svc = ref.watch(runTrackingServiceProvider);
  // Wrap to also emit the most recent snapshot to late subscribers (e.g., the
  // live screen after a hot-reload while the session is mid-flight).
  return svc.stateStream;
});

/// Quick boolean for places that just need "is a Track session active right
/// now". Reads the Hive flag so the FAB renders correctly even before the
/// service stream has emitted its first event on a fresh subscription.
final isTrackActiveProvider = Provider<bool>((ref) {
  // Recompute whenever the stream emits (so we react to start/end live).
  ref.watch(activeRunSessionProvider);
  return isTrackActiveFromHive();
});

/// History of finished sessions for the signed-in user. Re-fetched on demand
/// (FutureProvider.autoDispose so it re-runs each time the user opens the
/// Track hub screen).
final runSessionHistoryProvider = FutureProvider<List<RunSession>>((ref) async {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return const [];
  return ref.read(runTrackingServiceProvider).getHistory(userId: user.id);
});

/// One saved session by id (drives the detail screen). autoDispose so it
/// re-fetches whenever the user navigates into a session; explicit
/// `ref.invalidate(trackSessionByIdProvider(id))` after a rename/delete on
/// the detail screen.
final trackSessionByIdProvider =
    FutureProvider.family.autoDispose<RunSession?, String>((ref, id) async {
  return ref.read(runTrackingServiceProvider).getById(id);
});
