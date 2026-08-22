import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/mission_model.dart';
import '../models/user_mission_progress_model.dart';
import '../repositories/mission_repository.dart';
import '../services/mission_service.dart';
import 'auth_provider.dart';

/// Mission service singleton. Kept for the write path (upserts,
/// getOrCreate progress, completedDailyCount RPC); reads have moved
/// to [missionRepositoryProvider] for cache-then-network delivery.
final missionServiceProvider = Provider<MissionService>((ref) {
  return MissionService();
});

/// Fires `update_tz_offset` once per session as soon as the signed-in
/// user is available. Cron backstop (migration 0045) uses the offset
/// to compute the user's local "yesterday" — without this the cron
/// falls back to +330 (IST) which is wrong for travellers.
///
/// The provider itself has no meaningful value; it's held alive by
/// being watched at the app root. The `_sentTzOffsetLastKey` module-
/// level cache guards against re-firing on every rebuild — we push
/// only when the (uid, offset) pair changes.
///
/// Uses a module-level cache instead of a `StateProvider` because
/// Riverpod forbids modifying another provider during a provider's
/// own build. Writing to a `StateProvider.notifier` during build
/// throws the "Providers are not allowed to modify other providers
/// during their initialization" error that this replaces.
String? _sentTzOffsetLastKey;
final tzOffsetSyncProvider = Provider<void>((ref) {
  final uid = ref.watch(authStateProvider).valueOrNull?.id;
  if (uid == null) return;
  final offset = DateTime.now().timeZoneOffset.inMinutes;
  final key = '$uid:$offset';
  if (_sentTzOffsetLastKey == key) return;
  // Fire the RPC asynchronously so it doesn't run inside the build
  // frame. Cache the (uid, offset) key ONLY on success — otherwise a
  // boot-time not_authorized failure would freeze the cache and never
  // retry. Now: on failure the next provider rebuild (triggered by any
  // authStateProvider tick, e.g. session refresh) tries again.
  //
  // The 1.1.6+19 build had the cache write BEFORE the microtask fired,
  // so a boot-time JWT-hydration race would silently strand the tz
  // offset stale forever (server fell back to IST). Now the service
  // itself does a one-shot 400ms retry on the auth-race error, and
  // this caller only caches when the service reports success.
  Future.microtask(() async {
    final ok = await ref
        .read(missionServiceProvider)
        .updateTzOffset(userId: uid, offsetMinutes: offset);
    if (ok) _sentTzOffsetLastKey = key;
  });
});

/// Cache-then-network mission repository. Definitions cached with a
/// long horizon, progress rows cached per (user, period).
final missionRepositoryProvider = Provider<MissionRepository>((ref) {
  return MissionRepository();
});

/// Daily mission definitions — live via Supabase realtime so
/// admin-panel creates / edits / deletes surface on every connected
/// device without a manual refresh. Emits the cached list first (if
/// any) so the UI paints instantly on cold boot, then swaps in the
/// server snapshot the moment the subscription connects.
///
/// Requires `alter publication supabase_realtime add table missions;`
/// server-side (see PENDING_MIGRATIONS.md). Without it the stream
/// still delivers the initial snapshot but stops receiving updates.
final dailyMissionsProvider =
    StreamProvider<List<MissionModel>>((ref) {
  return _streamMissionDefs(ref, MissionType.daily);
});

/// Weekly mission definitions — same realtime semantics as daily.
final weeklyMissionsProvider =
    StreamProvider<List<MissionModel>>((ref) {
  return _streamMissionDefs(ref, MissionType.weekly);
});

/// Realtime stream of mission definitions for the given [type],
/// cache-primed on first emission.
Stream<List<MissionModel>> _streamMissionDefs(
    Ref ref, MissionType type) async* {
  final repo = ref.read(missionRepositoryProvider);
  final cached = repo.readCachedDefs(type);
  if (cached != null && cached.isNotEmpty) yield cached;

  final wire = type == MissionType.weekly ? 'weekly' : 'daily';
  yield* Supabase.instance.client
      .from('missions')
      .stream(primaryKey: ['id'])
      .eq('type', wire)
      .map((rows) => rows
          .map((r) => MissionModel.fromSupabaseRow(r))
          .toList(growable: false));
}

/// Base stream: **every** mission-progress row for the current user
/// regardless of period. Both [dailyProgressProvider] and
/// [weeklyProgressProvider] used to open their own filtered
/// subscription, which meant two realtime channels on the same table
/// delivering overlapping row updates on every step tick. This
/// single stream powers both — the two derived Providers below
/// filter by period client-side. Repository still does the caching
/// + retry-wrapper for the daily / weekly views; this one is a
/// direct realtime read since it's the source of truth for the two
/// derived views that consumers actually watch.
final _allMissionProgressProvider =
    StreamProvider<List<UserMissionProgress>>((ref) {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return Stream.value([]);
  return Supabase.instance.client
      .from('user_mission_progress')
      .stream(primaryKey: ['user_id', 'mission_id', 'period_start'])
      .eq('user_id', user.id)
      .map((rows) =>
          rows.map(UserMissionProgress.fromSupabaseRow).toList());
});

/// Daily mission progress for the current user — derived from the
/// single shared upstream stream. Filters by today's period_start.
final dailyProgressProvider =
    Provider<AsyncValue<List<UserMissionProgress>>>((ref) {
  final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
  return ref.watch(_allMissionProgressProvider).whenData(
        (rows) =>
            rows.where((r) => r.periodStart == today).toList(growable: false),
      );
});

/// Weekly mission progress for the current user — derived from the
/// single shared upstream stream. Filters by this Monday's
/// period_start (matches `MissionRepository._weekPeriod`).
final weeklyProgressProvider =
    Provider<AsyncValue<List<UserMissionProgress>>>((ref) {
  final now = DateTime.now();
  final monday = now.subtract(Duration(days: now.weekday - 1));
  final weekStart = DateFormat('yyyy-MM-dd').format(monday);
  return ref.watch(_allMissionProgressProvider).whenData(
        (rows) => rows
            .where((r) => r.periodStart == weekStart)
            .toList(growable: false),
      );
});

/// Number of daily missions completed today.
final completedDailyCountProvider = FutureProvider<int>((ref) async {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return 0;
  return ref.read(missionServiceProvider).completedDailyCount(user.id);
});

/// Helper: find progress for a specific mission from the progress list.
UserMissionProgress? findProgress(
    List<UserMissionProgress> progressList, String missionId) {
  try {
    return progressList.firstWhere((p) => p.missionId == missionId);
  } catch (_) {
    return null;
  }
}

/// Pairs a mission with the current user's live progress row on it.
/// Used by the Home-tab featured-missions section so the card can
/// render a real progress bar.
class HomeMissionEntry {
  final MissionModel mission;
  final UserMissionProgress? progress;
  const HomeMissionEntry({required this.mission, this.progress});

  bool get isCompleted => progress?.isCompleted ?? false;
  int get currentValue => progress?.currentValue ?? 0;
}

/// Admin-featured missions that should render on the Home tab. Filters:
///   * `shouldShowInHome == true`
///   * NOT yet completed (completed missions still show in the
///     Missions tab till end of period, but disappear from Home the
///     moment they complete).
/// Sorted by [MissionModel.displayOrder] descending — highest first.
/// Combines daily + weekly catalogs so an admin can feature either
/// bucket.
final homeHighlightedMissionsProvider =
    Provider<List<HomeMissionEntry>>((ref) {
  final daily = ref.watch(dailyMissionsProvider).valueOrNull ?? const [];
  final weekly = ref.watch(weeklyMissionsProvider).valueOrNull ?? const [];
  final dailyProgress =
      ref.watch(dailyProgressProvider).valueOrNull ?? const [];
  final weeklyProgress =
      ref.watch(weeklyProgressProvider).valueOrNull ?? const [];

  final entries = <HomeMissionEntry>[];
  for (final m in daily.where((m) => m.shouldShowInHome)) {
    final progress = findProgress(dailyProgress, m.missionId);
    if (progress?.isCompleted == true) continue;
    entries.add(HomeMissionEntry(mission: m, progress: progress));
  }
  for (final m in weekly.where((m) => m.shouldShowInHome)) {
    final progress = findProgress(weeklyProgress, m.missionId);
    if (progress?.isCompleted == true) continue;
    entries.add(HomeMissionEntry(mission: m, progress: progress));
  }
  entries.sort(
      (a, b) => b.mission.displayOrder.compareTo(a.mission.displayOrder));
  return entries;
});

/// The single mission whose poster (if any) should surface as a
/// full-screen popup on next app open / foreground. Rules:
///   * Non-null `posterUrl`
///   * NOT yet completed
///   * Poster has not been dismissed on this device (checked
///     asynchronously by the [MissionPosterHost] before showing).
/// Multiple candidates → highest [displayOrder] wins. Only ONE popup
/// per open — no queue.
final missionPosterCandidatesProvider =
    Provider<List<MissionModel>>((ref) {
  final daily = ref.watch(dailyMissionsProvider).valueOrNull ?? const [];
  final weekly = ref.watch(weeklyMissionsProvider).valueOrNull ?? const [];
  final dailyProgress =
      ref.watch(dailyProgressProvider).valueOrNull ?? const [];
  final weeklyProgress =
      ref.watch(weeklyProgressProvider).valueOrNull ?? const [];

  bool isCompleted(MissionModel m, List<UserMissionProgress> ps) =>
      findProgress(ps, m.missionId)?.isCompleted ?? false;

  final candidates = <MissionModel>[];
  for (final m in daily.where((m) => m.posterUrl != null)) {
    if (isCompleted(m, dailyProgress)) continue;
    candidates.add(m);
  }
  for (final m in weekly.where((m) => m.posterUrl != null)) {
    if (isCompleted(m, weeklyProgress)) continue;
    candidates.add(m);
  }
  candidates
      .sort((a, b) => b.displayOrder.compareTo(a.displayOrder));
  return candidates;
});
