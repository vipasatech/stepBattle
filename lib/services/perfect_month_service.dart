import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/subscription_model.dart';
import '../utils/app_logger.dart';
import 'xp_service.dart';

/// Awards the tier-scaled "perfect month" XP bonus — fires when the
/// user's `step_logs` cover every day of a completed calendar month.
///
/// Amounts (from [SubscriptionLimits.perfectMonthXpBonus]):
///   * Free   → 200 XP
///   * Pro    → 500 XP
///   * Family → 1000 XP (per member; each family seat gets their own)
///
/// **Idempotency** — guarded by `profiles.last_perfect_month_awarded`,
/// a `yyyy-mm` text column bumped after each check. A perfect month
/// is paid at most once per user; an imperfect one is remembered as
/// "checked" so we don't re-scan step_logs every syncSteps() call.
///
/// **Timing** — called from [StepService.syncSteps] which runs on
/// every step ingest (app foreground, background sync, provider
/// update). First call after month-rollover does the work; every
/// subsequent call short-circuits on the flag check.
///
/// **Multi-month catch-up** — the loop advances from
/// `last_awarded + 1` up to (but not including) the current month.
/// A user who reappears after 3 months of perfect logs gets three
/// awards. Capped at a lookback of 6 months to avoid pathological
/// backfills.
class PerfectMonthService {
  final SupabaseClient _supabase;
  final XPService _xpService;

  PerfectMonthService({SupabaseClient? supabase, XPService? xpService})
      : _supabase = supabase ?? Supabase.instance.client,
        _xpService = xpService ?? XPService();

  /// Look-back cap so a returning user doesn't trigger a huge scan.
  static const int _maxMonthsLookback = 6;

  Future<void> checkAndAward({required String userId}) async {
    if (userId.isEmpty) return;
    try {
      final row = await _supabase
          .from('profiles')
          .select('last_perfect_month_awarded, subscription_tier')
          .eq('id', userId)
          .maybeSingle();
      if (row == null) return;

      final lastAwarded = row['last_perfect_month_awarded'] as String?;
      final tier =
          SubscriptionTier.fromWire(row['subscription_tier'] as String?);
      final bonus = SubscriptionLimits.forTier(tier).perfectMonthXpBonus;

      final now = DateTime.now();
      final currentMonth = _monthKey(now);

      // Determine which months to check. Start = (last_awarded + 1)
      // or the immediately previous month for a first-time user.
      DateTime cursor;
      if (lastAwarded != null && lastAwarded.isNotEmpty) {
        cursor = _addMonths(_monthKeyToDate(lastAwarded), 1);
      } else {
        cursor = DateTime(now.year, now.month - 1, 1);
      }

      // Apply the look-back cap.
      final earliestAllowed =
          DateTime(now.year, now.month - _maxMonthsLookback, 1);
      if (cursor.isBefore(earliestAllowed)) cursor = earliestAllowed;

      String? lastChecked;
      var iterations = 0;
      while (_monthKey(cursor).compareTo(currentMonth) < 0) {
        // Defensive iteration cap in case a date-math bug loops forever.
        if (iterations++ > _maxMonthsLookback) break;

        final isPerfect = await _isPerfectMonth(userId, cursor);
        if (isPerfect) {
          await _xpService.awardXP(
            userId: userId,
            amount: bonus,
            reason: 'Perfect month · ${_monthLabel(cursor)}',
          );
          AppLogger.xp.i('perfectMonth:awarded', fields: {
            'userId': userId,
            'month': _monthKey(cursor),
            'tier': tier.wire,
            'bonus': bonus,
          });
        }
        lastChecked = _monthKey(cursor);
        cursor = _addMonths(cursor, 1);
      }

      if (lastChecked != null) {
        await _supabase.from('profiles').update({
          'last_perfect_month_awarded': lastChecked,
        }).eq('id', userId);
      }
    } catch (e, s) {
      AppLogger.xp.e('perfectMonth:checkAndAward:failed',
          fields: {'userId': userId}, error: e, stack: s);
    }
  }

  /// True when every day of [firstOfMonth]'s calendar month has a
  /// `step_logs` row with `step_count > 0`. Distinct-count over the
  /// `date` column vs `daysInMonth`.
  Future<bool> _isPerfectMonth(
      String userId, DateTime firstOfMonth) async {
    final year = firstOfMonth.year;
    final month = firstOfMonth.month;
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final firstDate = _dateStr(DateTime(year, month, 1));
    final firstOfNext = _dateStr(DateTime(year, month + 1, 1));

    final rows = await _supabase
        .from('step_logs')
        .select('date')
        .eq('user_id', userId)
        .gte('date', firstDate)
        .lt('date', firstOfNext)
        .gt('step_count', 0);

    final loggedDates = <String>{};
    for (final r in rows as List) {
      final d = (r as Map)['date'];
      if (d is String && d.isNotEmpty) loggedDates.add(d);
    }
    return loggedDates.length >= daysInMonth;
  }

  static String _monthKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

  static String _dateStr(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static DateTime _monthKeyToDate(String key) {
    final parts = key.split('-');
    if (parts.length < 2) return DateTime(1970, 1, 1);
    return DateTime(int.parse(parts[0]), int.parse(parts[1]), 1);
  }

  static DateTime _addMonths(DateTime d, int months) =>
      DateTime(d.year, d.month + months, 1);

  static String _monthLabel(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[d.month - 1]} ${d.year}';
  }
}
