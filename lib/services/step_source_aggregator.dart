import 'dart:developer' as dev;
import 'google_fit_service.dart';
import 'health_service.dart';
import 'native_step_service.dart';

/// Per-source today-step values plus aggregate. Surfaced to the debug
/// screen so we can see, in real time, which source(s) are agreeing or
/// disagreeing.
class StepReading {
  /// Steps from the device's hardware pedometer (`TYPE_STEP_COUNTER`).
  /// Always available on Android phones with a pedometer chip.
  final int nativeSteps;

  /// Steps from Health Connect (Android 14+) / HealthKit (iOS).
  /// Returns the user's authoritative count when an OEM source is feeding it.
  /// May lag native by 1–15 minutes on Android (Samsung Health batches push).
  final int healthConnectSteps;

  /// Steps from Google Fit REST API. `null` when Fit fallback is disabled
  /// or the user hasn't granted the `fitness.activity.read` scope. A
  /// distinct null vs. 0 lets us tell "Fit said the user walked 0 today"
  /// from "we didn't ask Fit at all."
  final int? googleFitSteps;

  /// Effective value the rest of the app reads.
  /// = max(nativeSteps, healthConnectSteps, googleFitSteps ?? -1).
  /// Max because all three sources read the same physical activity; sum
  /// would double-count. Max favors freshness when one source is stale.
  final int aggregate;

  /// Per-source timeout / error snapshots for the debug screen.
  final Duration nativeLatency;
  final Duration healthConnectLatency;
  final Duration googleFitLatency;
  final String? nativeError;
  final String? healthConnectError;
  final String? googleFitError;

  const StepReading({
    required this.nativeSteps,
    required this.healthConnectSteps,
    this.googleFitSteps,
    required this.aggregate,
    required this.nativeLatency,
    required this.healthConnectLatency,
    this.googleFitLatency = Duration.zero,
    this.nativeError,
    this.healthConnectError,
    this.googleFitError,
  });
}

/// Orchestrates all step data sources behind a single API.
///
/// Strategy:
///   1. Query native + Health Connect in parallel (each with a timeout).
///   2. Return `max(values)` — never `sum` (would double-count overlapping
///      readings of the same hardware counter).
///   3. Cache per-source values for the debug screen.
///
/// Why max:
///   - Native sensor is real-time; HC may lag while Samsung Health batches.
///   - HC can be higher than native when it aggregates a Galaxy Watch reading
///     the phone alone wouldn't see.
///   - Either source returning 0 (no permission, no feeder) shouldn't suppress
///     the other.
class StepSourceAggregator {
  final NativeStepService _native;
  final HealthService _hc;
  final GoogleFitService _fit;

  /// Last computed reading. Used by `getTodaySteps()` callers that want a
  /// monotonic-within-a-day floor and by the debug screen.
  StepReading? _lastReading;
  StepReading? get lastReading => _lastReading;

  static const _nativeTimeout = Duration(seconds: 1);
  static const _hcTimeout = Duration(seconds: 3);
  static const _fitTimeout = Duration(seconds: 5);

  StepSourceAggregator({
    required NativeStepService native,
    required HealthService healthService,
    required GoogleFitService googleFit,
  })  : _native = native,
        _hc = healthService,
        _fit = googleFit;

  /// Eager startup — call once after permissions are granted.
  Future<void> warmUp() async {
    await _native.start();
  }

  /// Best-effort today's step count across all sources.
  /// Never throws — falls back to 0 if everything fails.
  Future<int> getTodaySteps() async {
    final reading = await readWithDebug();
    return reading.aggregate;
  }

  /// Same as [getTodaySteps] but returns the full per-source breakdown.
  Future<StepReading> readWithDebug() async {
    // Run all three in parallel — Fit only fires if user opted in, so we
    // don't burn the OAuth token on every poll for the 99% who never enabled.
    final nativeStart = DateTime.now();
    final hcStart = DateTime.now();
    final fitStart = DateTime.now();

    final nativeFuture = Future<int>(() {
      try {
        return _native.getTodaySteps();
      } catch (_) {
        return 0;
      }
    });

    final hcFuture = _hc
        .getTodaySteps()
        .timeout(_hcTimeout, onTimeout: () => 0)
        .catchError((_) => 0);

    final fitFuture = _fit.isEnabled
        ? _fit
            .getTodaySteps()
            .timeout(_fitTimeout, onTimeout: () => null)
            .catchError((_) => null)
        : Future<int?>.value(null);

    final results = await Future.wait<dynamic>([
      nativeFuture,
      hcFuture,
      fitFuture,
    ]);
    final nativeVal = results[0] as int;
    final hcVal = results[1] as int;
    final fitVal = results[2] as int?;

    final nativeLatency = DateTime.now().difference(nativeStart);
    final hcLatency = DateTime.now().difference(hcStart);
    final fitLatency = DateTime.now().difference(fitStart);

    String? nativeErr;
    if (nativeLatency > _nativeTimeout) nativeErr = 'slow_native_read';
    if (!_native.isAvailable) nativeErr ??= _native.lastError;

    String? hcErr;
    if (hcLatency >= _hcTimeout) hcErr = 'timeout';

    String? fitErr;
    if (_fit.isEnabled && fitVal == null) {
      fitErr = _fit.lastError ?? 'fit_unavailable';
    }

    // Aggregate: max across all available sources. Fit treated as -1
    // when null so it never wins-by-default.
    final fitForMax = fitVal ?? -1;
    var aggregate = nativeVal;
    if (hcVal > aggregate) aggregate = hcVal;
    if (fitForMax > aggregate) aggregate = fitForMax;
    if (aggregate < 0) aggregate = 0;

    final reading = StepReading(
      nativeSteps: nativeVal,
      healthConnectSteps: hcVal,
      googleFitSteps: fitVal,
      aggregate: aggregate,
      nativeLatency: nativeLatency,
      healthConnectLatency: hcLatency,
      googleFitLatency: fitLatency,
      nativeError: nativeErr,
      healthConnectError: hcErr,
      googleFitError: fitErr,
    );
    _lastReading = reading;

    // Single-line per-source breakdown so logs show which source produced
    // the winning value at any moment. Tagged so you can grep for it.
    dev.log(
      'native=$nativeVal hc=$hcVal '
      'fit=${fitVal ?? "null"} '
      'agg=$aggregate '
      'errs={n=${nativeErr ?? "-"}, h=${hcErr ?? "-"}, f=${fitErr ?? "-"}}',
      name: 'StepSourceAggregator',
    );

    return reading;
  }
}
