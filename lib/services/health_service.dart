import 'dart:io';
import 'package:health/health.dart';
import 'package:intl/intl.dart';

/// Unified interface to Apple HealthKit (iOS) and Google Health Connect (Android).
/// Reads steps, calories, and activity data. Handles permissions.
class HealthService {
  final Health _health = Health();

  bool _isAuthorized = false;
  bool get isAuthorized => _isAuthorized;

  /// Types we need access to.
  static const List<HealthDataType> _readTypes = [
    HealthDataType.STEPS,
    HealthDataType.ACTIVE_ENERGY_BURNED,
  ];

  // ---------------------------------------------------------------------------
  // Permissions
  // ---------------------------------------------------------------------------

  /// Request read permissions from the platform health store.
  Future<bool> requestPermissions() async {
    try {
      final permissions = _readTypes.map((_) => HealthDataAccess.READ).toList();

      // On Android, install Health Connect if needed
      if (Platform.isAndroid) {
        await Health().configure();
      }

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
  Future<int> getTodaySteps() async {
    final now = DateTime.now();
    final midnight = DateTime(now.year, now.month, now.day);
    return _getSteps(midnight, now);
  }

  /// Get step count for a specific date.
  Future<int> getStepsForDate(DateTime date) async {
    final start = DateTime(date.year, date.month, date.day);
    final end = start.add(const Duration(days: 1)).subtract(const Duration(seconds: 1));
    return _getSteps(start, end);
  }

  /// Get step count between two date-times.
  Future<int> _getSteps(DateTime start, DateTime end) async {
    try {
      final steps = await _health.getTotalStepsInInterval(start, end);
      return steps ?? 0;
    } catch (_) {
      return 0;
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
