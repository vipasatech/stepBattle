import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/step_log_model.dart';
import 'auth_provider.dart';
import 'step_provider.dart';

/// Last 4 weeks of `step_logs` rows for the signed-in user. Drives the
/// home-screen streak strip — each row tells us whether the user
/// recorded any activity on a given date.
///
/// Returned as a Map keyed by `yyyy-MM-dd` for O(1) lookup from the
/// strip widget when it paints each day cell.
///
/// Range: Monday of (current week - 3 weeks ago) through today. The
/// strip itself decides which week to show.
final recentStepLogsProvider =
    FutureProvider<Map<String, StepLogModel>>((ref) async {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return const {};
  final svc = ref.read(stepServiceProvider);

  final now = DateTime.now();
  // Monday of the current week, local midnight.
  final mondayThisWeek =
      DateTime(now.year, now.month, now.day).subtract(
    Duration(days: now.weekday - 1),
  );
  // 4 weeks back = Monday of 3 weeks before the current week.
  final from = mondayThisWeek.subtract(const Duration(days: 21));

  final logs =
      await svc.getStepHistory(userId: user.id, from: from, to: now);
  return {for (final l in logs) l.date: l};
});
