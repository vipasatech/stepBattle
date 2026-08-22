import 'dart:developer' as dev;

import '../utils/app_logger.dart';
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

  /// Effective value the rest of the app reads. Chosen by [pickAggregate]
  /// (HC-preferred, with per-source sanity checks against impossible
  /// readings).
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
/// Source selection (changed from the original `max()` policy after a
/// corrupt native baseline poisoned today's step count with a 40k+ value
/// — see logs/2026-05-26_15-15-42):
///
///   1. Run a sanity check on each per-source reading. Anything >
///      [_perDayMax] is treated as "this source is lying" and discarded
///      with a `sourceRejected` warning.
///   2. Prefer Health Connect when available — it's the authoritative
///      OEM-fed value on Android (Samsung Health, Mi Fit, Fitbit, etc.).
///   3. Fall back to native pedometer for devices without an HC feeder
///      (Realme/Motorola on a fresh install).
///   4. Google Fit fallback only when explicitly opted in.
///
/// If native disagrees wildly with HC (HC=440, native=40k), trust HC and
/// ask NativeStepService to repair its corrupt baseline (see
/// [NativeStepService.repairBaselineFromTrustedSource]).
class StepSourceAggregator {
  final NativeStepService _native;
  final HealthService _hc;
  final GoogleFitService _fit;

  /// Last computed reading. Used by `getTodaySteps()` callers that want a
  /// monotonic-within-a-day floor and by the debug screen.
  StepReading? _lastReading;
  StepReading? get lastReading => _lastReading;

  /// Anything beyond this is treated as garbage. The world record for
  /// most steps in 24h is around 200k; everyday users top out well below.
  /// 100k gives plenty of headroom but rejects the corrupt-baseline
  /// scenario (which surfaces as the device's lifetime step count, often
  /// in the 40k–200k+ range).
  static const int _perDayMax = 100000;

  /// If native says >10k MORE than HC (when HC is available and trusted),
  /// we conclude native's baseline is wrong and repair it.
  static const int _nativeDriftFromHCToRepair = 10000;

  /// Bumped 1s → 3s in 1.1.6+28.
  ///
  /// Rationale: on mid-range OEM Androids (moto g35, older Realme /
  /// Xiaomi models) the first async pull of TYPE_STEP_COUNTER can
  /// take 2-3 seconds because the sensor batches readings internally.
  /// The prior 1-second cutoff silently dropped native reads on
  /// those devices — surfacing as `slow_native_read` in Diagnostics
  /// and leaving genuinely-counted steps stuck in the sensor. Lavanya's
  /// moto g35 (2026-08-18): 1,085 real steps captured in the sensor,
  /// but never surfaced because every read timed out at 1 second.
  /// 3 seconds gives OEM sensors enough time to respond without
  /// noticeably slowing hot-path reads (which normally return in
  /// <200ms — that's why hot reads still feel instant).
  static const _nativeTimeout = Duration(seconds: 3);
  static const _hcTimeout = Duration(seconds: 3);
  static const _fitTimeout = Duration(seconds: 5);

  StepSourceAggregator({
    required NativeStepService native,
    required HealthService healthService,
    required GoogleFitService googleFit,
  })  : _native = native,
        _hc = healthService,
        _fit = googleFit;

  Future<void> warmUp() async {
    await _native.start();
  }

  Future<int> getTodaySteps() async {
    final reading = await readWithDebug();
    return reading.aggregate;
  }

  Future<StepReading> readWithDebug() async {
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
    final nativeRaw = results[0] as int;
    final hcRaw = results[1] as int;
    final fitRaw = results[2] as int?;

    final nativeLatency = DateTime.now().difference(nativeStart);
    final hcLatency = DateTime.now().difference(hcStart);
    final fitLatency = DateTime.now().difference(fitStart);

    // -------------------------------------------------------------------
    // Sanity-check each source. A reading > _perDayMax can't be a real
    // human walking — almost always a corrupt cumulative baseline. Mark
    // the source as errored so it isn't considered for the aggregate.
    // -------------------------------------------------------------------
    final nativeValid = nativeRaw >= 0 && nativeRaw <= _perDayMax;
    final hcValid = hcRaw >= 0 && hcRaw <= _perDayMax;
    final fitValid = fitRaw == null || (fitRaw >= 0 && fitRaw <= _perDayMax);

    if (!nativeValid) {
      AppLogger.health.w('aggregator:sourceRejected', fields: {
        'source': 'native',
        'value': nativeRaw,
        'reason': 'exceeds_per_day_max_$_perDayMax',
      });
    }
    if (!hcValid) {
      AppLogger.health.w('aggregator:sourceRejected', fields: {
        'source': 'health_connect',
        'value': hcRaw,
        'reason': 'exceeds_per_day_max_$_perDayMax',
      });
    }
    if (!fitValid) {
      AppLogger.health.w('aggregator:sourceRejected', fields: {
        'source': 'google_fit',
        'value': fitRaw,
        'reason': 'exceeds_per_day_max_$_perDayMax',
      });
    }

    // -------------------------------------------------------------------
    // Detect "native baseline poisoned" — native is valid by itself but
    // dramatically higher than HC, which is the authoritative source when
    // present. Ask NativeStepService to repair so the next read converges.
    // -------------------------------------------------------------------
    if (nativeValid &&
        hcValid &&
        hcRaw > 0 &&
        nativeRaw - hcRaw > _nativeDriftFromHCToRepair) {
      AppLogger.health.w('aggregator:nativeBaselineDrift', fields: {
        'native': nativeRaw,
        'hc': hcRaw,
        'drift': nativeRaw - hcRaw,
      });
      // Fire and forget — repair persists to Hive; next read picks up the
      // corrected baseline.
      _native.repairBaselineFromTrustedSource(trustedTodaySteps: hcRaw);
    }

    // -------------------------------------------------------------------
    // Pick the winner: HC first, then native, then Fit.
    // -------------------------------------------------------------------
    int aggregate;
    if (hcValid && hcRaw > 0) {
      aggregate = hcRaw;
    } else if (nativeValid && nativeRaw > 0) {
      aggregate = nativeRaw;
    } else if (fitValid && (fitRaw ?? 0) > 0) {
      aggregate = fitRaw!;
    } else {
      aggregate = 0;
    }

    String? nativeErr;
    if (!nativeValid) {
      nativeErr = 'invalid_value_$nativeRaw';
    } else {
      if (nativeLatency > _nativeTimeout) nativeErr = 'slow_native_read';
      if (!_native.isAvailable) nativeErr ??= _native.lastError;
    }

    String? hcErr;
    if (!hcValid) {
      hcErr = 'invalid_value_$hcRaw';
    } else if (hcLatency >= _hcTimeout) {
      hcErr = 'timeout';
    }

    String? fitErr;
    if (!fitValid) {
      fitErr = 'invalid_value_$fitRaw';
    } else if (_fit.isEnabled && fitRaw == null) {
      fitErr = _fit.lastError ?? 'fit_unavailable';
    }

    final reading = StepReading(
      // Surface the validated value to consumers (debug screen included)
      // so the dashboard never shows the rejected number as if it were
      // real. Invalid reads collapse to 0 here.
      nativeSteps: nativeValid ? nativeRaw : 0,
      healthConnectSteps: hcValid ? hcRaw : 0,
      googleFitSteps: fitValid ? fitRaw : null,
      aggregate: aggregate,
      nativeLatency: nativeLatency,
      healthConnectLatency: hcLatency,
      googleFitLatency: fitLatency,
      nativeError: nativeErr,
      healthConnectError: hcErr,
      googleFitError: fitErr,
    );
    _lastReading = reading;

    dev.log(
      'native=$nativeRaw(${nativeValid ? "ok" : "drop"}) '
      'hc=$hcRaw(${hcValid ? "ok" : "drop"}) '
      'fit=${fitRaw ?? "null"}(${fitValid ? "ok" : "drop"}) '
      'agg=$aggregate '
      'errs={n=${nativeErr ?? "-"}, h=${hcErr ?? "-"}, f=${fitErr ?? "-"}}',
      name: 'StepSourceAggregator',
    );

    return reading;
  }
}
