import 'dart:async';
import 'dart:convert';

import 'package:hive/hive.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/user_model.dart';
import '../services/native_step_service.dart';
import '../services/supabase_api_client.dart';
import '../utils/app_logger.dart';
import '../utils/hive_lifecycle.dart';
import '../utils/realtime_retry.dart';
import 'hive_json_cache.dart';

/// Cache-then-network profile access.
///
/// The prior design read [UserModel] straight off Supabase's realtime
/// stream — meaning a cold boot painted an empty shell until the first
/// row arrived (~200-400ms on wifi, seconds on cellular). Here we:
///
/// 1. Persist the last-known profile row in Hive (JSON string, keyed
///    by user id — small, stable, hot).
/// 2. On [watch], immediately emit that cached row synchronously.
/// 3. Subscribe to the live Supabase stream; every arriving row updates
///    both the cache and the emitted stream.
///
/// UI code that watches this via a `StreamProvider` sees the cached
/// profile on frame 1 and the fresh one as soon as it lands. Same
/// tearing rules as before — Supabase's row eventually wins.
///
/// This is the pilot for a broader repository pattern: mission progress,
/// clan info, and leaderboard slices will follow the same shape once
/// this one has burnt in.
class ProfileRepository {
  ProfileRepository({
    SupabaseClient? supabase,
    Box<dynamic>? cacheBox,
    SupabaseApiClient? api,
  })  : _supabase = supabase ?? Supabase.instance.client,
        _cacheBox = cacheBox ?? Hive.box(NativeStepService.boxName),
        _api = api ?? SupabaseApiClient.instance;

  final SupabaseClient _supabase;
  final Box<dynamic> _cacheBox;
  final SupabaseApiClient _api;

  static const String _cachePrefix = 'profile_cache_v1:';

  String _cacheKey(String userId) => '$_cachePrefix$userId';

  /// Read the cached row without touching the network. Returns null if
  /// nothing was cached for this user yet.
  ///
  /// Uses [safeSharedBox] instead of the captured [_cacheBox] so a
  /// background-isolate box close doesn't leave us reading from a stale
  /// handle; falls through to network fetch on any handle miss.
  UserModel? readCached(String userId) {
    final box = safeSharedBox() ?? _cacheBox;
    try {
      final raw = box.get(_cacheKey(userId));
      if (raw is! String || raw.isEmpty) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return UserModel.fromSupabaseRow(map);
    } catch (e, s) {
      if (isBenignBoxClosed(e)) return null;
      // A malformed cache entry shouldn't crash the app — discard and
      // fall through to network.
      AppLogger.auth.w('profileCache:decodeFailed',
          fields: {'uid': userId, 'err': e.toString()});
      unawaited(box.delete(_cacheKey(userId)).catchError((_) {}));
      // s intentionally unused — swallow, cache-read failure isn't fatal.
      // ignore: unused_local_variable
      final _ = s;
      return null;
    }
  }

  Future<void> _writeCache(String userId, Map<String, dynamic> row) async {
    final box = safeSharedBox();
    if (box == null) return;
    try {
      await box.put(_cacheKey(userId), jsonEncode(row));
    } catch (e) {
      if (isBenignBoxClosed(e)) return;
      AppLogger.auth.w('profileCache:writeFailed',
          fields: {'uid': userId, 'err': e.toString()});
    }
  }

  /// One-shot fetch. Retries transient failures via [SupabaseApiClient],
  /// warms the cache on success. Returns null if the row hasn't been
  /// created yet (fresh sign-in race with the `on_auth_user_created`
  /// trigger).
  Future<UserModel?> fetch(String userId) async {
    final row = await _api.run<Map<String, dynamic>?>(
      () => _supabase
          .from('profiles')
          .select()
          .eq('id', userId)
          .maybeSingle(),
      category: LogCategory.auth,
      name: 'profiles.fetch',
      fields: {'uid': userId},
    );
    if (row == null) return null;
    await _writeCache(userId, row);
    return UserModel.fromSupabaseRow(row);
  }

  /// Cache-then-network live stream.
  ///
  /// Emits the cached row first (if any), then every row that arrives
  /// on the retry-wrapped Supabase realtime subscription. On upstream
  /// failure `retryingRealtimeStream` handles backoff and reconnection;
  /// the UI keeps painting the last-good row throughout.
  Stream<UserModel?> watch(String userId) {
    final controller = StreamController<UserModel?>();
    StreamSubscription<UserModel?>? sub;

    controller.onListen = () {
      final cached = readCached(userId);
      if (cached != null) controller.add(cached);

      sub = retryingRealtimeStream<UserModel?>(
        factory: () => _supabase
            .from('profiles')
            .stream(primaryKey: ['id'])
            .eq('id', userId)
            .map((rows) {
              if (rows.isEmpty) return null;
              final row = rows.first;
              unawaited(_writeCache(userId, row));
              return UserModel.fromSupabaseRow(row);
            }),
        debugLabel: 'profile:$userId',
        category: LogCategory.auth,
      ).listen(controller.add);
    };

    controller.onCancel = () async {
      await sub?.cancel();
      sub = null;
    };

    return controller.stream;
  }

  /// Invalidate the cached row for [userId]. Call after sign-out so the
  /// next sign-in with a different account doesn't briefly render the
  /// previous user's data.
  Future<void> invalidate(String userId) async {
    await _cacheBox.delete(_cacheKey(userId));
  }

  /// Wipe every cached profile row. Called from sign-out so a device
  /// shared across accounts doesn't briefly render the previous user's
  /// profile before the new one loads.
  static Future<void> clearAllCached() =>
      HiveJsonCache.clearAllWithPrefix(_cachePrefix);
}
