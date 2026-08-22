import 'dart:async';

import 'package:hive/hive.dart';

import '../models/leaderboard_entry_model.dart';
import '../services/leaderboard_service.dart';
import '../utils/app_logger.dart';
import 'hive_json_cache.dart';

/// Cache-then-poll access for the five leaderboard scopes + my-rank.
///
/// The leaderboard is a batch view of `profiles` — realtime subscriptions
/// on the underlying table would fire on every step-tick from every
/// active user, which would be catastrophically chatty. Instead we poll
/// every [pollInterval] while there's a listener, and cache the last
/// response in Hive so cold-boot / tab-switch paint is instant.
///
/// Scopes: global, friends, district, state, country, myRank.
/// Cache key layout: `leaderboard_v1:<scope>[:<param>]`.
class LeaderboardRepository {
  LeaderboardRepository({
    LeaderboardService? service,
    HiveJsonCache<LeaderboardEntry>? cache,
    Box<dynamic>? box,
    Duration? pollInterval,
  })  : _service = service ?? LeaderboardService(),
        _pollInterval = pollInterval ?? const Duration(seconds: 60),
        _cache = cache ??
            HiveJsonCache<LeaderboardEntry>(
              prefix: 'leaderboard_v1:',
              logCategory: LogCategory.leaderboard,
              encode: _encodeEntry,
              decode: LeaderboardEntry.fromSupabaseRow,
              box: box,
            );

  final LeaderboardService _service;
  final HiveJsonCache<LeaderboardEntry> _cache;
  final Duration _pollInterval;

  /// Round-trip an entry to/from Hive JSON. Mirrors the keys
  /// [LeaderboardEntry.fromSupabaseRow] reads.
  static Map<String, dynamic> _encodeEntry(LeaderboardEntry e) => {
        'user_id': e.userId,
        'display_name': e.displayName,
        'preferred_name': e.preferredName,
        'avatar_url': e.avatarURL,
        'avatar_config': e.avatarConfig,
        'earned_xp': e.totalXP,
        'rank': e.rank,
        'updated_at': e.updatedAt.toIso8601String(),
      };

  // ---------------------------------------------------------------------------
  // Read helpers
  // ---------------------------------------------------------------------------

  List<LeaderboardEntry>? readCached(String cacheKey) =>
      _cache.readList(cacheKey);

  Future<void> _writeCache(
      String cacheKey, List<LeaderboardEntry> entries) async {
    await _cache.writeList(cacheKey, entries);
  }

  // ---------------------------------------------------------------------------
  // Scopes
  // ---------------------------------------------------------------------------

  Stream<List<LeaderboardEntry>> watchGlobal({int limit = 20}) {
    return _pollingWatch(
      cacheKey: 'global',
      fetch: () => _service.getGlobalRanks(limit: limit),
    );
  }

  Stream<List<LeaderboardEntry>> watchDistrict({
    required String districtName,
    int limit = 50,
  }) {
    return _pollingWatch(
      cacheKey: 'district:$districtName',
      fetch: () => _service.getDistrictRanks(
          districtName: districtName, limit: limit),
    );
  }

  Stream<List<LeaderboardEntry>> watchState({
    required String stateName,
    int limit = 100,
  }) {
    return _pollingWatch(
      cacheKey: 'state:$stateName',
      fetch: () =>
          _service.getStateRanks(stateName: stateName, limit: limit),
    );
  }

  Stream<List<LeaderboardEntry>> watchCountry({
    required String countryCode,
    int limit = 100,
  }) {
    return _pollingWatch(
      cacheKey: 'country:${countryCode.toUpperCase()}',
      fetch: () => _service.getCountryRanks(
          countryCode: countryCode, limit: limit),
    );
  }

  /// Friends leaderboard. Cache key includes both [uid] AND a stable
  /// hash of the sorted friend set — so unfriending someone shows the
  /// correct ranked list on the next open instead of briefly painting
  /// the pre-unfriend cache while the poll produces the fresh set.
  Stream<List<LeaderboardEntry>> watchFriends({
    required String uid,
    required List<String> friendIds,
  }) {
    // Sort + join + hashCode gives a stable per-set fingerprint. String
    // concat is fine (uids are opaque UUIDs, no collision concern) and
    // .hashCode fits in a Dart int so the key stays short.
    final sorted = [...friendIds]..sort();
    final setHash = sorted.join(',').hashCode.toRadixString(36);
    return _pollingWatch(
      cacheKey: 'friends:$uid:$setHash',
      fetch: () => _service.getFriendsRanks(
        friendIds: [...friendIds, uid],
      ),
    );
  }

  /// The signed-in user's own rank card. Not a list — the single-entry
  /// helper wraps the polled result in a list for reuse, then peels the
  /// first item back off. Cache key is `me:<uid>`.
  Stream<LeaderboardEntry?> watchMyRank(String uid) {
    return _pollingWatch(
      cacheKey: 'me:$uid',
      fetch: () async {
        final row = await _service.getMyRank(uid);
        return row == null ? const <LeaderboardEntry>[] : [row];
      },
    ).map((list) => list.isEmpty ? null : list.first);
  }

  // ---------------------------------------------------------------------------
  // Poll implementation
  // ---------------------------------------------------------------------------

  /// Emit the cached list on frame 1, then poll [fetch] every
  /// [_pollInterval] while a listener is subscribed. Every fetch
  /// rewrites the cache. Fetch errors are logged but do NOT tear down
  /// the stream — the UI keeps the last-good list on-screen.
  Stream<List<LeaderboardEntry>> _pollingWatch({
    required String cacheKey,
    required Future<List<LeaderboardEntry>> Function() fetch,
  }) {
    final controller = StreamController<List<LeaderboardEntry>>();
    Timer? timer;
    var disposed = false;

    Future<void> doFetch() async {
      try {
        final entries = await fetch();
        if (disposed) return;
        // Store BEFORE emit so the next cold read serves the fresh data
        // even if the listener rebuilds mid-tick.
        await _writeCache(cacheKey, entries);
        if (!controller.isClosed) controller.add(entries);
      } catch (e, s) {
        // Log at .w only — a poll failure is transient (the next 60s
        // tick usually recovers) and firing .e here would fan out to
        // Sentry every tick during an offline window, blowing through
        // event quotas. The catch is unusual enough that the .w line
        // + `stack` field is enough for triage; if a failure pattern
        // proves persistent we can promote to .e at the call sites
        // that actually surface it to the user.
        AppLogger.leaderboard.w('leaderboard.poll:failed', fields: {
          'cacheKey': cacheKey,
          'err': e.toString(),
          'stack': s.toString().split('\n').take(3).join(' | '),
        });
      }
    }

    controller.onListen = () {
      // Frame 1: cache. Fetch triggers async, emit lands on next tick.
      final cached = readCached(cacheKey);
      if (cached != null && cached.isNotEmpty) controller.add(cached);

      doFetch();
      timer = Timer.periodic(_pollInterval, (_) => doFetch());
    };

    controller.onCancel = () {
      disposed = true;
      timer?.cancel();
      timer = null;
    };

    return controller.stream;
  }

  /// Wipe every cached leaderboard slice. Called from sign-out.
  static Future<void> clearAllCached() =>
      HiveJsonCache.clearAllWithPrefix('leaderboard_v1:');
}
