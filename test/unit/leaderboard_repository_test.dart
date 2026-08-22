import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:stepbattle/models/leaderboard_entry_model.dart';
import 'package:stepbattle/repositories/leaderboard_repository.dart';
import 'package:stepbattle/services/leaderboard_service.dart';
import 'package:stepbattle/services/native_step_service.dart';

/// A [LeaderboardService] fake that lets the test drive the fetch
/// contract without hitting Supabase. Each stub replaces the whole
/// response for the corresponding scope; a null stub means "always
/// return an empty list".
class _FakeLeaderboardService implements LeaderboardService {
  int globalCalls = 0;
  List<LeaderboardEntry> globalRows = const [];
  Future<List<LeaderboardEntry>>? Function()? globalOverride;

  @override
  Future<List<LeaderboardEntry>> getGlobalRanks({int limit = 20, int? startAfterRank}) async {
    globalCalls++;
    if (globalOverride != null) {
      return globalOverride!() ?? globalRows;
    }
    return globalRows;
  }

  @override
  Future<List<LeaderboardEntry>> getFriendsRanks({required List<String> friendIds}) async => const [];

  @override
  Future<List<LeaderboardEntry>> getDistrictRanks({required String districtName, int limit = 50}) async => const [];

  @override
  Future<List<LeaderboardEntry>> getStateRanks({required String stateName, int limit = 100}) async => const [];

  @override
  Future<List<LeaderboardEntry>> getCountryRanks({required String countryCode, int limit = 100}) async => const [];

  @override
  Future<LeaderboardEntry?> getMyRank(String userId) async => null;

  // Fill in any other members with no-op stubs — this only compiles if
  // LeaderboardService adds no non-nullable methods without defaults.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

LeaderboardEntry _entry({
  String userId = 'u1',
  String displayName = 'Ada',
  int xp = 100,
  int rank = 1,
}) {
  return LeaderboardEntry(
    userId: userId,
    displayName: displayName,
    totalXP: xp,
    rank: rank,
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

void main() {
  late Directory tmpDir;

  setUpAll(() async {
    tmpDir = await Directory.systemTemp.createTemp('leaderboard_repo_test_');
    Hive.init(tmpDir.path);
    await Hive.openBox(NativeStepService.boxName);
  });

  tearDownAll(() async {
    await Hive.close();
    if (tmpDir.existsSync()) {
      await tmpDir.delete(recursive: true);
    }
  });

  setUp(() async {
    await Hive.box(NativeStepService.boxName).clear();
  });

  group('LeaderboardRepository.watchGlobal', () {
    test('emits cache on frame 1 before the first fetch resolves',
        () async {
      final fake = _FakeLeaderboardService();
      // Prime the cache via a completed fetch on a first repo, then
      // build a NEW repo instance so we don't observe the write itself.
      fake.globalRows = [_entry(userId: 'cache-hit', displayName: 'Cached')];
      final priming = LeaderboardRepository(
        service: fake,
        pollInterval: const Duration(minutes: 5),
      );
      // Draining one emit populates the cache via the fetch that fires
      // as soon as onListen is called.
      final sub1 = priming.watchGlobal().listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub1.cancel();

      // Now build a fresh repo (same Hive box) whose fetch stalls, and
      // observe that the cached row lands on the first emit even
      // though the fetch hasn't produced a value yet.
      fake.globalOverride = () => Future.delayed(
          const Duration(minutes: 5),
          () => <LeaderboardEntry>[]);
      final observed = <LeaderboardEntry>[];
      final observer = LeaderboardRepository(
        service: fake,
        pollInterval: const Duration(minutes: 5),
      );
      final sub2 =
          observer.watchGlobal().listen((list) => observed.addAll(list));
      // Give the microtask queue time to drain the frame-1 emit.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(observed, hasLength(1));
      expect(observed.first.userId, 'cache-hit');
      await sub2.cancel();
    });

    test('poll interval refires fetch while listened', () async {
      final fake = _FakeLeaderboardService();
      fake.globalRows = [_entry(userId: 'u1')];
      final repo = LeaderboardRepository(
        service: fake,
        pollInterval: const Duration(milliseconds: 50),
      );
      final sub = repo.watchGlobal().listen((_) {});
      // Initial fetch + at least 2 poll ticks.
      await Future<void>.delayed(const Duration(milliseconds: 175));
      await sub.cancel();
      expect(fake.globalCalls, greaterThanOrEqualTo(3));
    });

    test('canceling the subscription stops the poll timer', () async {
      final fake = _FakeLeaderboardService();
      fake.globalRows = [_entry()];
      final repo = LeaderboardRepository(
        service: fake,
        pollInterval: const Duration(milliseconds: 40),
      );
      final sub = repo.watchGlobal().listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final callsBeforeCancel = fake.globalCalls;
      await sub.cancel();
      // Wait past several would-be ticks — no more fetches should fire.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(fake.globalCalls, callsBeforeCancel);
    });
  });

  group('LeaderboardRepository.clearAllCached', () {
    test('wipes cached rows so a fresh watch has no cache to emit',
        () async {
      final fake = _FakeLeaderboardService();
      fake.globalRows = [_entry(userId: 'prime')];
      final repo = LeaderboardRepository(
        service: fake,
        pollInterval: const Duration(minutes: 5),
      );
      // Prime the cache.
      final sub = repo.watchGlobal().listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await sub.cancel();
      expect(repo.readCached('global'), isNotNull);

      await LeaderboardRepository.clearAllCached();
      expect(repo.readCached('global'), isNull);
    });
  });
}
