import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/step_log_model.dart';
import 'auth_provider.dart';
import 'run_session_provider.dart';
import 'step_provider.dart';

/// One day's rollup of the three metrics the Profile → "This Week"
/// trendline plots.
///
/// - [steps] comes from the daily `step_logs` row (device pedometer /
///   Health Connect fed).
/// - [distanceMeters] + [calories] are summed over any Track sessions
///   started on this day (in the user's local timezone). Per the
///   Profile trend spec, days without a saved Track session get 0 for
///   both — the trendline draws them as flat baseline points.
class DailyMetricPoint {
  final DateTime date;
  final int steps;
  final double distanceMeters;
  final int calories;

  const DailyMetricPoint({
    required this.date,
    required this.steps,
    required this.distanceMeters,
    required this.calories,
  });
}

/// The last 28 days of daily metrics, ordered oldest → newest.
///
/// The provider returns exactly 28 entries — one per day for the rolling
/// 4-week window ending today — even when the underlying `step_logs` or
/// `track_sessions` tables have gaps. The trendline widget then filters
/// this list down to the 3–7 days the user selected in the calendar
/// sheet.
///
/// Fresh fetch on every Profile mount (autoDispose) so the chart shows
/// the latest data without a stale-cache pause.
final last28DaysMetricsProvider =
    FutureProvider.autoDispose<List<DailyMetricPoint>>((ref) async {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return const [];

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final from = today.subtract(const Duration(days: 27));

  // Kick off both fetches concurrently — the step-log query hits
  // `step_logs` with an explicit date range while the session query
  // reuses the app-wide history provider (which caches across screens).
  final stepFuture = ref.read(stepServiceProvider).getStepHistory(
        userId: user.id,
        from: from,
        to: today,
      );
  final sessionFuture = ref.watch(runSessionHistoryProvider.future);
  final results = await Future.wait<Object>([stepFuture, sessionFuture]);

  final stepLogs = results[0] as List<StepLogModel>;
  final sessions = results[1] as List;

  // Bucket step_logs by their "yyyy-MM-dd" date string (that's the
  // primary key StepService writes and reads).
  final stepsByDate = <String, int>{};
  for (final log in stepLogs) {
    stepsByDate[log.date] = log.stepCount;
  }

  // Bucket Track sessions by local calendar date so the distance /
  // calorie totals line up with the calendar tiles the user sees.
  final fmt = DateFormat('yyyy-MM-dd');
  final distByDate = <String, double>{};
  final kcalByDate = <String, int>{};
  for (final s in sessions) {
    final key = fmt.format(s.startedAt.toLocal());
    distByDate[key] = (distByDate[key] ?? 0) + (s.distanceMeters as double);
    kcalByDate[key] = (kcalByDate[key] ?? 0) + (s.calories as int);
  }

  return List<DailyMetricPoint>.generate(28, (i) {
    final date = from.add(Duration(days: i));
    final key = fmt.format(date);
    return DailyMetricPoint(
      date: date,
      steps: stepsByDate[key] ?? 0,
      distanceMeters: distByDate[key] ?? 0,
      calories: kcalByDate[key] ?? 0,
    );
  });
});
