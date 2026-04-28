import 'dart:io';
import 'package:health/health.dart';
import 'package:intl/intl.dart';

/// Unified interface to Apple HealthKit (iOS) and Google Health Connect (Android).
/// Reads steps, calories, and activity data. Handles permissions.
class HealthService {
  final Health _health = Health();

  bool _isAuthorized = false;
  bool get isAuthorized => _isAuthorized;

  /// Last successful step reading for today.
  /// Keyed by yyyy-MM-dd so we reset at midnight.
  int _lastKnownTodaySteps = 0;
  String _lastKnownDate = '';

  /// One-shot init future. Health Connect's `healthConnectClient` is a
  /// `lateinit` field that must be set up via `Health().configure()` before
  /// any other call, otherwise reads throw `UninitializedPropertyAccessException`.
  /// Cache the future so concurrent first-callers all await the same setup.
  Future<void>? _configureFuture;

  /// Types we need access to.
  static const List<HealthDataType> _readTypes = [
    HealthDataType.STEPS,
    HealthDataType.ACTIVE_ENERGY_BURNED,
  ];

  // ---------------------------------------------------------------------------
  // Permissions
  // ---------------------------------------------------------------------------

  /// Lazily configure the platform health client. Idempotent.
  Future<void> _ensureConfigured() {
    return _configureFuture ??= _doConfigure();
  }

  Future<void> _doConfigure() async {
    try {
      // No-op on iOS; on Android sets up the platform plumbing.
      await _health.configure();

      // health: ^11.x quirk — `configure()` does NOT initialize the
      // Kotlin-side `lateinit var healthConnectClient`. That field is only
      // set inside `onAttachedToEngine` (which silently no-ops if Health
      // Connect availability is misdetected at attach time, common on
      // Samsung One UI) or inside `getHealthConnectSdkStatus`. Calling
      // status here forces the re-check + lazy `getOrCreate`, so subsequent
      // step reads don't throw `UninitializedPropertyAccessException`.
      if (Platform.isAndroid) {
        try {
          await _health.getHealthConnectSdkStatus();
        } catch (_) {
          // Status probe is best-effort; ignore.
        }
      }
    } catch (_) {
      // Allow retry on next call by clearing the cached future.
      _configureFuture = null;
    }
  }

  /// Request read permissions from the platform health store.
  Future<bool> requestPermissions() async {
    try {
      await _ensureConfigured();
      final permissions = _readTypes.map((_) => HealthDataAccess.READ).toList();

      final granted = await _health.requestAuthorization(
        _readTypes,
        permissions: permissions,
      );
      _isAuthorized = granted;
      return granted;
    } catch (e) {
      _isAuthorized = false;
      return false;
    }
  }

  /// Check if permissions have already been granted.
  Future<bool> hasPermissions() async {
    try {
      await _ensureConfigured();
      final result = await _health.hasPermissions(_readTypes);
      _isAuthorized = result ?? false;
      return _isAuthorized;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Step data
  // ---------------------------------------------------------------------------

  /// Get total step count for today.
  ///
  /// If Health Connect throws (e.g. app in background, which requires
  /// READ_HEALTH_DATA_IN_BACKGROUND permission we don't have), returns the
  /// last known value for today to prevent UI flicker to 0.
  /// Also ensures steps never decrease intra-day (monotonic).
  Future<int> getTodaySteps() async {
    final now = DateTime.now();
    final midnight = DateTime(now.year, now.month, now.day);
    final todayKey = DateFormat('yyyy-MM-dd').format(now);

    // Reset cache if date changed (new day)
    if (_lastKnownDate != todayKey) {
      _lastKnownTodaySteps = 0;
      _lastKnownDate = todayKey;
    }

    final fetched = await _tryGetSteps(midnight, now);
    if (fetched == null) {
      // Fetch failed (background restriction, offline, etc.) — keep last value.
      return _lastKnownTodaySteps;
    }

    // Steps can only go up during a day. Ignore any reading that's lower
    // than what we've already seen today (avoids weird Samsung/Health Connect
    // transient readings that flicker to 0).
    if (fetched < _lastKnownTodaySteps) {
      return _lastKnownTodaySteps;
    }

    _lastKnownTodaySteps = fetched;
    return fetched;
  }

  /// Get step count for a specific date.
  Future<int> getStepsForDate(DateTime date) async {
    final start = DateTime(date.year, date.month, date.day);
    final end = start.add(const Duration(days: 1)).subtract(const Duration(seconds: 1));
    final fetched = await _tryGetSteps(start, end);
    return fetched ?? 0;
  }

  /// Get step count between two date-times. Returns null on error so callers
  /// can decide how to handle transient failures (vs confusing them with 0).
  Future<int?> _tryGetSteps(DateTime start, DateTime end) async {
    try {
      await _ensureConfigured();
      final steps = await _health.getTotalStepsInInterval(start, end);
      return steps ?? 0;
    } catch (_) {
      return null;
    }
  }

  /// Get step data for a range of dates (for weekly stats etc.).
  Future<Map<String, int>> getStepHistory({
    required DateTime from,
    required DateTime to,
  }) async {
    final fmt = DateFormat('yyyy-MM-dd');
    final result = <String, int>{};
    var current = DateTime(from.year, from.month, from.day);
    final end = DateTime(to.year, to.month, to.day);

    while (!current.isAfter(end)) {
      final steps = await getStepsForDate(current);
      result[fmt.format(current)] = steps;
      current = current.add(const Duration(days: 1));
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Calories
  // ---------------------------------------------------------------------------

  /// Get calories burned today from the health store.
  /// Falls back to estimate (steps * 0.04) if health data unavailable.
  Future<double> getTodayCalories() async {
    final now = DateTime.now();
    final midnight = DateTime(now.year, now.month, now.day);
    try {
      await _ensureConfigured();
      final data = await _health.getHealthDataFromTypes(
        types: [HealthDataType.ACTIVE_ENERGY_BURNED],
        startTime: midnight,
        endTime: now,
      );
      if (data.isEmpty) {
        // Fallback: estimate from steps
        final steps = await getTodaySteps();
        return steps * 0.04;
      }
      double total = 0;
      for (final point in data) {
        final value = point.value;
        if (value is NumericHealthValue) {
          total += value.numericValue.toDouble();
        }
      }
      return total;
    } catch (_) {
      final steps = await getTodaySteps();
      return steps * 0.04;
    }
  }

  // ---------------------------------------------------------------------------
  // Platform name (for source field in step_logs)
  // ---------------------------------------------------------------------------

  String get sourceName => Platform.isIOS ? 'healthkit' : 'healthconnect';
}
