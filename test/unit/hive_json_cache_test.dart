import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:stepbattle/repositories/hive_json_cache.dart';
import 'package:stepbattle/services/native_step_service.dart';
import 'package:stepbattle/utils/app_logger.dart';

/// The whole Phase-2 repository layer stores its rows via
/// [HiveJsonCache]. These tests lock in the four properties every repo
/// depends on:
///
///   1. Namespacing — different prefixes never see each other's rows,
///      so `clearAll()` on one repo can't wipe another's.
///   2. Decode-failure eviction — corrupt JSON is discarded silently
///      so a bad row can't crash the app on cold boot.
///   3. `clearAll()` removes every row under the prefix, and nothing
///      outside it.
///   4. Roundtrip via `encode` + `decode` is lossless for the model.
class _TestRow {
  _TestRow(this.id, this.name);
  final String id;
  final String name;
}

void main() {
  late Directory tmpDir;

  setUpAll(() async {
    tmpDir = await Directory.systemTemp.createTemp('hive_json_cache_test_');
    Hive.init(tmpDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    if (tmpDir.existsSync()) {
      await tmpDir.delete(recursive: true);
    }
  });

  setUp(() async {
    // Fresh box per test so state doesn't bleed.
    if (Hive.isBoxOpen(NativeStepService.boxName)) {
      await Hive.box(NativeStepService.boxName).clear();
    } else {
      await Hive.openBox(NativeStepService.boxName);
    }
  });

  HiveJsonCache<_TestRow> makeCache(String prefix) {
    return HiveJsonCache<_TestRow>(
      prefix: prefix,
      logCategory: LogCategory.session,
      encode: (v) => {'id': v.id, 'name': v.name},
      decode: (m) => _TestRow(m['id'] as String, m['name'] as String),
    );
  }

  group('HiveJsonCache', () {
    test('write + read roundtrip', () async {
      final cache = makeCache('t_v1:');
      await cache.write('u1', _TestRow('u1', 'Ada'));
      final read = cache.read('u1');
      expect(read, isNotNull);
      expect(read!.id, 'u1');
      expect(read.name, 'Ada');
    });

    test('read returns null on cache miss (unknown id)', () {
      final cache = makeCache('t_v1:');
      expect(cache.read('never-written'), isNull);
    });

    test('two caches with different prefixes are isolated', () async {
      final a = makeCache('a_v1:');
      final b = makeCache('b_v1:');
      await a.write('shared-id', _TestRow('shared-id', 'from-a'));
      expect(b.read('shared-id'), isNull);
    });

    test('corrupt JSON is evicted and read returns null', () async {
      final cache = makeCache('t_v1:');
      // Simulate a malformed row landing in the box (e.g. schema
      // change we never bumped the version prefix for).
      await Hive.box(NativeStepService.boxName)
          .put('t_v1:corrupted', 'not-json-at-all');
      expect(cache.read('corrupted'), isNull);
      // Verify the row was actively deleted, not just skipped.
      // ignore: unawaited_futures — the eviction is fire-and-forget.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final raw =
          Hive.box(NativeStepService.boxName).get('t_v1:corrupted');
      expect(raw, isNull);
    });

    test('writeList + readList roundtrip', () async {
      final cache = makeCache('t_v1:');
      await cache.writeList('users', [
        _TestRow('u1', 'Ada'),
        _TestRow('u2', 'Grace'),
      ]);
      final read = cache.readList('users');
      expect(read, hasLength(2));
      expect(read!.map((r) => r.id).toList(), ['u1', 'u2']);
    });

    test('clearAll wipes prefix-scoped rows only', () async {
      final a = makeCache('a_v1:');
      final b = makeCache('b_v1:');
      await a.write('x', _TestRow('x', 'in-a'));
      await a.write('y', _TestRow('y', 'in-a'));
      await b.write('z', _TestRow('z', 'in-b'));

      await a.clearAll();

      expect(a.read('x'), isNull);
      expect(a.read('y'), isNull);
      // b's row survives.
      final z = b.read('z');
      expect(z, isNotNull);
      expect(z!.name, 'in-b');
    });

    test('delete removes a single row without touching others',
        () async {
      final cache = makeCache('t_v1:');
      await cache.write('a', _TestRow('a', 'A'));
      await cache.write('b', _TestRow('b', 'B'));
      await cache.delete('a');
      expect(cache.read('a'), isNull);
      expect(cache.read('b'), isNotNull);
    });
  });
}
