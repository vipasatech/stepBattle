import 'dart:async';

import 'package:hive/hive.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/mission_model.dart';
import '../models/user_mission_progress_model.dart';
import '../services/supabase_api_client.dart';
import '../utils/app_logger.dart';
import '../utils/realtime_retry.dart';
import 'hive_json_cache.dart';

/// Cache-then-network access for mission definitions and per-user
/// progress.
///
/// Mission **definitions** rarely change (admin-seeded catalog); we
/// cache aggressively and refresh in the background. **Progress** rows
/// change every step-sync tick; we cache the last-known list per period
/// so the Home screen paints its progress bars instantly on cold boot
/// and updates as Supabase realtime rows land.
class MissionRepository {
  MissionRepository({
    SupabaseClient? supabase,
    SupabaseApiClient? api,
    HiveJsonCache<MissionModel>? defCache,
    HiveJsonCache<UserMissionProgress>? progressCache,
    Box<dynamic>? box,
  })  : _supabase = supabase ?? Supabase.instance.client,
        _api = api ?? SupabaseApiClient.instance,
        _defCache = defCache ??
            HiveJsonCache<MissionModel>(
              prefix: 'missions_defs_v1:',
              logCategory: LogCategory.mission,
              encode: _encodeMission,
              decode: MissionModel.fromSupabaseRow,
              box: box,
            ),
        _progressCache = progressCache ??
            HiveJsonCache<UserMissionProgress>(
              prefix: 'missions_progress_v1:',
              logCategory: LogCategory.mission,
              encode: (v) => v.toSupabaseRow(),
              decode: UserMissionProgress.fromSupabaseRow,
              box: box,
            );

  final SupabaseClient _supabase;
  final SupabaseApiClient _api;
  final HiveJsonCache<MissionModel> _defCache;
  final HiveJsonCache<UserMissionProgress> _progressCache;

  static Map<String, dynamic> _encodeMission(MissionModel m) => {
        'id': m.missionId,
        'type': m.type == MissionType.weekly ? 'weekly' : 'daily',
        'title': m.title,
        'description': m.description,
        'category': _categoryWire(m.category),
        'target_value': m.targetValue,
        'xp_reward': m.xpReward,
        'difficulty': m.difficulty,
        'should_show_in_home': m.shouldShowInHome,
        'poster_url': m.posterUrl,
        'display_order': m.displayOrder,
      };

  static String _categoryWire(MissionCategory c) => switch (c) {
        MissionCategory.battle => 'battle',
        MissionCategory.streak => 'streak',
        MissionCategory.calories => 'calories',
        MissionCategory.steps => 'steps',
      };

  // ---------------------------------------------------------------------------
  // Mission catalog
  // ---------------------------------------------------------------------------

  /// Read cached mission definitions for [type], if any. Non-network.
  List<MissionModel>? readCachedDefs(MissionType type) {
    return _defCache.readList(_defKey(type));
  }

  /// One-shot fetch — hits Supabase with retry/timing. Warms the cache
  /// on success. Falls back to the hardcoded catalog on network failure
  /// or empty rows (fresh install with unseeded DB / cold-boot offline)
  /// — matches the prior [MissionService] behaviour and ensures the
  /// Missions tab is always populated. Never throws.
  Future<List<MissionModel>> fetchDefs(MissionType type) async {
    final defaults = type == MissionType.weekly
        ? MissionModel.defaultWeekly
        : MissionModel.defaultDaily;
    List<Map<String, dynamic>> rows;
    try {
      rows = await _api.run<List<Map<String, dynamic>>>(
        () async {
          final data = await _supabase
              .from('missions')
              .select()
              .eq('type', type == MissionType.weekly ? 'weekly' : 'daily');
          return List<Map<String, dynamic>>.from(data);
        },
        category: LogCategory.mission,
        name: 'missions.defs',
        fields: {'type': type == MissionType.weekly ? 'weekly' : 'daily'},
      );
    } catch (_) {
      // Cold-boot offline / retry ladder exhausted — the retry loop
      // already logged the error at .e. Silently fall back so the
      // Missions tab renders a usable catalog. This also prevents the
      // provider-level unawaited-refresh path from surfacing an
      // uncaught async exception to PlatformDispatcher.onError.
      return defaults;
    }
    if (rows.isEmpty) {
      AppLogger.mission.w('missions.defs:emptyCatalog',
          fields: {'type': type.name});
      return defaults;
    }
    final defs =
        rows.map((r) => MissionModel.fromSupabaseRow(r)).toList(growable: false);
    unawaited(_defCache.writeRawList(_defKey(type), rows));
    return defs;
  }

  String _defKey(MissionType type) =>
      type == MissionType.weekly ? 'weekly' : 'daily';

  // ---------------------------------------------------------------------------
  // Progress
  // ---------------------------------------------------------------------------

  String _todayPeriod() => DateFormat('yyyy-MM-dd').format(DateTime.now());

  String _weekPeriod() {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    return DateFormat('yyyy-MM-dd').format(monday);
  }

  String _progressKey(String userId, String periodStart) =>
      '$userId:$periodStart';

  /// Cache-then-network stream of the user's progress rows for a period.
  ///
  /// Emits the cached list on frame 1, then live-updates from the retry-
  /// wrapped Supabase realtime stream. Every fresh emit rewrites the
  /// cache.
  Stream<List<UserMissionProgress>> watchProgress({
    required String userId,
    required String periodStart,
  }) {
    final controller = StreamController<List<UserMissionProgress>>();
    StreamSubscription<List<UserMissionProgress>>? sub;

    controller.onListen = () {
      final cached =
          _progressCache.readList(_progressKey(userId, periodStart));
      if (cached != null && cached.isNotEmpty) controller.add(cached);

      sub = retryingRealtimeStream<List<UserMissionProgress>>(
        factory: () => _supabase
            .from('user_mission_progress')
            .stream(primaryKey: ['user_id', 'mission_id', 'period_start'])
            .eq('user_id', userId)
            .map((rows) {
              final filtered = rows
                  .where((r) => r['period_start'] == periodStart)
                  .toList(growable: false);
              unawaited(_progressCache.writeRawList(
                  _progressKey(userId, periodStart), filtered));
              return filtered
                  .map((r) => UserMissionProgress.fromSupabaseRow(r))
                  .toList(growable: false);
            }),
        debugLabel: 'missions.progress:$userId:$periodStart',
        category: LogCategory.mission,
      ).listen(controller.add);
    };

    controller.onCancel = () async {
      await sub?.cancel();
      sub = null;
    };

    return controller.stream;
  }

  Stream<List<UserMissionProgress>> watchDailyProgress(String userId) =>
      watchProgress(userId: userId, periodStart: _todayPeriod());

  Stream<List<UserMissionProgress>> watchWeeklyProgress(String userId) =>
      watchProgress(userId: userId, periodStart: _weekPeriod());

  /// Optimistic increment. Bumps the cache immediately (UI paints new
  /// value on next frame), then upserts to Supabase; on failure the
  /// realtime stream re-emits the server's truth and the optimistic
  /// row falls out. Callers get the optimistic value back to update
  /// derived UI state before the round-trip completes.
  Future<UserMissionProgress> optimisticIncrement({
    required String userId,
    required MissionModel mission,
    required int delta,
  }) async {
    final period = mission.type == MissionType.daily
        ? _todayPeriod()
        : _weekPeriod();
    final cacheKey = _progressKey(userId, period);
    final list = _progressCache.readList(cacheKey) ?? const [];

    final existing = list.firstWhere(
      (p) => p.missionId == mission.missionId && p.periodStart == period,
      orElse: () => UserMissionProgress.empty(
        userId: userId,
        missionId: mission.missionId,
        targetValue: mission.targetValue,
        periodStart: period,
      ),
    );
    final nextValue = (existing.currentValue + delta).clamp(0, mission.targetValue);
    final wasComplete = existing.isCompleted;
    final nowComplete = nextValue >= mission.targetValue;
    final optimistic = UserMissionProgress(
      id: existing.id,
      userId: userId,
      missionId: mission.missionId,
      currentValue: nextValue,
      targetValue: mission.targetValue,
      isCompleted: nowComplete,
      completedAt: nowComplete
          ? (existing.completedAt ?? DateTime.now())
          : existing.completedAt,
      periodStart: period,
    );

    // Optimistic cache update.
    final updated = [
      for (final p in list)
        if (p.missionId != mission.missionId || p.periodStart != period) p,
      optimistic,
    ];
    unawaited(_progressCache.writeList(cacheKey, updated));

    // Fire the write. Retry off — progress upsert is idempotent via the
    // composite PK, but if it flaps we don't want double-increments.
    unawaited(() async {
      try {
        await _api.run<void>(
          () async {
            await _supabase
                .from('user_mission_progress')
                .upsert(optimistic.toSupabaseRow());
          },
          category: LogCategory.mission,
          name: 'missions.progressUpsert',
          fields: {
            'uid': userId,
            'mission': mission.missionId,
            'value': nextValue,
            'completed': nowComplete && !wasComplete,
          },
          retry: false,
        );
      } catch (_) {
        // Rely on realtime stream to reconcile — no need to rethrow into
        // the fire-and-forget path.
      }
    }());

    return optimistic;
  }

  /// Wipe cached defs + progress. Called from sign-out.
  static Future<void> clearAllCached() => Future.wait([
        HiveJsonCache.clearAllWithPrefix('missions_defs_v1:'),
        HiveJsonCache.clearAllWithPrefix('missions_progress_v1:'),
      ]);
}
