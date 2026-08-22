import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:stepbattle/repositories/hive_json_cache.dart';
import 'package:stepbattle/services/native_step_service.dart';
import 'package:stepbattle/utils/app_logger.dart';

/// Micro-benchmarks for the hot paths added in Phases 1-3.
///
/// These aren't hard assertions — they run as tests so `flutter test`
/// executes them and prints the timing, but they don't fail the suite
/// on absolute thresholds (device speed varies wildly). Instead they
/// serve as:
///
///   1. A regression tripwire — a 10× slowdown will show up in the
///      output diff of a PR reviewer scanning CI logs.
///   2. Local reference — run before/after a refactor to prove a hot
///      path didn't regress.
///
/// To watch a specific benchmark:
///
///     flutter test test/benchmark/hot_paths_bench_test.dart --reporter expanded
///
/// Reported metrics:
///
///   - median: middle of the sorted iteration times, more robust to
///     GC pauses than mean
///   - p95:    95th percentile — tail-latency signal for scroll-perf
///             work where p50 doesn't reveal jank
///   - runs/s: throughput, useful to reason about batch calls
void main() {
  late Directory tmpDir;

  setUpAll(() async {
    tmpDir = await Directory.systemTemp.createTemp('bench_hot_paths_');
    Hive.init(tmpDir.path);
    await Hive.openBox(NativeStepService.boxName);
  });

  tearDownAll(() async {
    await Hive.close();
    if (tmpDir.existsSync()) {
      await tmpDir.delete(recursive: true);
    }
  });

  group('bench: HiveJsonCache', () {
    test('write + read roundtrip (10k iterations)', () async {
      final cache = HiveJsonCache<Map<String, Object?>>(
        prefix: 'bench_v1:',
        logCategory: LogCategory.session,
        encode: (v) => v,
        decode: (m) => m,
      );

      final row = {
        'id': 'u_bench',
        'display_name': 'Ada Lovelace',
        'total_xp': 12345,
        'streak': 42,
        'city': 'Chennai',
      };
      final writeSamples = await _timeMany(
          iterations: 10000, body: () => cache.write('u_bench', row));
      final readSamples = _timeManySync(
          iterations: 10000, body: () => cache.read('u_bench'));

      _report('HiveJsonCache.write', writeSamples);
      _report('HiveJsonCache.read', readSamples);
    });
  });

  group('bench: AppLogger PII redaction', () {
    test('write with PII (redacts email + phone) — 5k iterations', () {
      final samples = _timeManySync(iterations: 5000, body: () {
        AppLogger.auth.i('signIn attempt for jane.doe@example.com',
            fields: {
              'phone': '+1 415 555 0123',
              'attempt': 2,
              'jti': 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc',
            });
      });
      _report('AppLogger.PII-redact.write', samples);
    });

    test('write without PII (fast path) — 5k iterations', () {
      final samples = _timeManySync(iterations: 5000, body: () {
        AppLogger.auth.i('signIn',
            fields: {'provider': 'google', 'attempt': 2});
      });
      _report('AppLogger.plain.write', samples);
    });
  });
}

/// Sync timer. Returns per-iteration durations in microseconds.
List<int> _timeManySync({
  required int iterations,
  required void Function() body,
}) {
  // Warm-up so JIT-like optimisations settle before measurement.
  for (var i = 0; i < 200; i++) {
    body();
  }
  final samples = <int>[];
  final sw = Stopwatch();
  for (var i = 0; i < iterations; i++) {
    sw
      ..reset()
      ..start();
    body();
    sw.stop();
    samples.add(sw.elapsedMicroseconds);
  }
  return samples;
}

/// Async timer variant.
Future<List<int>> _timeMany({
  required int iterations,
  required Future<void> Function() body,
}) async {
  for (var i = 0; i < 200; i++) {
    await body();
  }
  final samples = <int>[];
  final sw = Stopwatch();
  for (var i = 0; i < iterations; i++) {
    sw
      ..reset()
      ..start();
    await body();
    sw.stop();
    samples.add(sw.elapsedMicroseconds);
  }
  return samples;
}

void _report(String label, List<int> samplesMicros) {
  samplesMicros.sort();
  final n = samplesMicros.length;
  final median = samplesMicros[n ~/ 2];
  final p95 = samplesMicros[(n * 0.95).floor()];
  final total = samplesMicros.reduce((a, b) => a + b);
  final runsPerSec = (n / (total / 1e6)).toStringAsFixed(0);
  // Note: printed via stdout so `flutter test --reporter expanded` shows it.
  // ignore: avoid_print
  print('[BENCH] $label  '
      'median=$median µs  '
      'p95=$p95 µs  '
      'throughput=$runsPerSec runs/s  '
      '(n=$n)');
}
