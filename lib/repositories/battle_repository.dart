import 'dart:async';

import 'package:hive/hive.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/battle_model.dart';
import '../services/supabase_api_client.dart';
import '../utils/app_logger.dart';
import '../utils/realtime_retry.dart';
import '../utils/stream_debounce.dart';
import 'hive_json_cache.dart';

/// Cache-then-network access for the user's battle list.
///
/// The Battles tab is one of the noisiest cold-boot experiences in the
/// app — before Phase 2, `allBattlesProvider` would show an empty
/// skeleton until the two-hop realtime query (`battle_participants` →
/// `battles` joined with participants + teams) resolved. On cellular
/// this was 400-1200 ms of empty scaffold.
///
/// Here we cache the JOINed battle rows (raw JSON, keyed by user id) so
/// the Battles tab paints the last-known list on frame 1 while the
/// realtime stream re-fetches in the background. As soon as fresh rows
/// arrive, the cache is rewritten and the UI updates.
///
/// The per-battle detail stream ([battleDetailProvider]) stays on
/// Supabase realtime unchanged — it's already `autoDispose` (Phase 1D)
/// so it tears down when the user backs out of the detail screen.
class BattleRepository {
  BattleRepository({
    SupabaseClient? supabase,
    SupabaseApiClient? api,
    HiveJsonCache<BattleModel>? cache,
    Box<dynamic>? box,
  })  : _supabase = supabase ?? Supabase.instance.client,
        _api = api ?? SupabaseApiClient.instance,
        _cache = cache ??
            HiveJsonCache<BattleModel>(
              prefix: 'battles_v1:',
              logCategory: LogCategory.battle,
              // These are unused because we cache raw server rows via
              // writeRawList; the decode side calls fromSupabaseRow
              // directly. Both are required by the ctor.
              encode: (_) => const <String, dynamic>{},
              decode: BattleModel.fromSupabaseRow,
              box: box,
            );

  final SupabaseClient _supabase;
  final SupabaseApiClient _api;
  final HiveJsonCache<BattleModel> _cache;

  String _key(String userId) => userId;

  /// Read the last-cached battle list for [userId] without touching
  /// the network. Returns null on cache miss.
  List<BattleModel>? readCached(String userId) {
    return _cache.readList(_key(userId));
  }

  /// One-shot fetch. Retries transient failures, warms the cache.
  Future<List<BattleModel>> fetch(String userId) async {
    final rows = await _api.run<List<Map<String, dynamic>>>(
      () async {
        final ids = await _supabase
            .from('battle_participants')
            .select('battle_id')
            .eq('user_id', userId);
        final battleIds =
            (ids as List).map((r) => r['battle_id'] as String).toSet().toList();
        if (battleIds.isEmpty) return const <Map<String, dynamic>>[];
        final battlesRaw = await _supabase
            .from('battles')
            .select('*, battle_participants(*), battle_teams(*)')
            .inFilter('id', battleIds)
            // Hide battles the retention cron has already archived —
            // Free users lose them after 30 days, Pro/Family after 6mo.
            .filter('archived_at', 'is', null)
            .order('start_time', ascending: false);
        return List<Map<String, dynamic>>.from(battlesRaw);
      },
      category: LogCategory.battle,
      name: 'battles.fetchAll',
      fields: {'uid': userId},
    );
    final battles =
        rows.map(BattleModel.fromSupabaseRow).toList(growable: false);
    unawaited(_cache.writeRawList(_key(userId), rows));
    return battles;
  }

  /// Cache-then-network stream of the user's full battle list.
  ///
  /// Emits the cached list on frame 1, then re-emits every time the
  /// retry-wrapped participant-row realtime subscription fires a delta
  /// (join/leave/step-update). Each fresh emit rewrites the cache.
  ///
  /// The inner join step (participant IDs → full battles) is a
  /// synchronous await inside the map — if it throws, we swallow to
  /// null and skip the emit, so a transient join failure doesn't tear
  /// down the whole subscription. `retryingRealtimeStream` handles
  /// upstream reconnects and calls [onReconnectingChanged] on every
  /// transition so the UI's "Reconnecting…" pill can toggle.
  Stream<List<BattleModel>> watch(
    String userId, {
    void Function(bool reconnecting)? onReconnectingChanged,
  }) {
    final controller = StreamController<List<BattleModel>>();
    StreamSubscription<List<BattleModel>?>? sub;

    controller.onListen = () {
      final cached = readCached(userId);
      if (cached != null && cached.isNotEmpty) controller.add(cached);

      // Trailing-debounce the participant firehose. During a team
      // battle every participant's `current_steps` updates on the
      // same 60s sync cadence; before the debounce, each participant
      // row change fired its own batched JOIN, so N players
      // produced N heavy queries within a second. Coalescing to a
      // single JOIN per 500 ms preserves live feel and drops per-
      // tick network cost by ~N-1.
      const debounceWindow = Duration(milliseconds: 500);
      sub = retryingRealtimeStream<List<BattleModel>?>(
        factory: () => debounceTrailing(
          _supabase
              .from('battle_participants')
              .stream(primaryKey: ['battle_id', 'user_id'])
              .eq('user_id', userId),
          debounceWindow,
        ).asyncMap((participantRows) async {
          try {
            final battleIds = participantRows
                .map((r) => r['battle_id'] as String)
                .toSet()
                .toList();
            if (battleIds.isEmpty) {
              await _cache.writeRawList(_key(userId), const []);
              return const <BattleModel>[];
            }
            final battlesRaw = await _supabase
                .from('battles')
                .select('*, battle_participants(*), battle_teams(*)')
                .inFilter('id', battleIds)
                // Hide retention-archived battles from the client
                // stream — nightly cron sets archived_at once
                // the retention window for all participants has
                // elapsed.
                .filter('archived_at', 'is', null)
                .order('start_time', ascending: false)
                // Cap the JOIN payload. `start_time desc` means the
                // 50 most recent battles win — pending + active are
                // naturally near the top (their start_time is now/
                // future), and the last 5-ish completed sit under
                // them. Users with heavy history get their oldest
                // completed dropped from this stream; the full
                // history screen (`/battles/completed`) fetches
                // beyond this cap on demand via `getBattles`.
                .limit(50);
            final rows = List<Map<String, dynamic>>.from(battlesRaw);
            await _cache.writeRawList(_key(userId), rows);
            return rows.map(BattleModel.fromSupabaseRow).toList();
          } catch (e, s) {
            AppLogger.battle.e('battles.watchAll:resolveFailed',
                fields: {'uid': userId}, error: e, stack: s);
            // Skip this tick, keep the last-good emit visible.
            return null;
          }
        }),
        debugLabel: 'battles.watchAll:$userId',
        category: LogCategory.battle,
        onReconnectingChanged: onReconnectingChanged,
      ).listen((emit) {
        if (emit != null) controller.add(emit);
      });
    };

    controller.onCancel = () async {
      await sub?.cancel();
      sub = null;
    };

    return controller.stream;
  }

  /// Sign-out cleanup — wipe every cached user's battle list.
  static Future<void> clearAllCached() =>
      HiveJsonCache.clearAllWithPrefix('battles_v1:');
}
