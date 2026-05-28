import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/constants.dart';
import '../utils/app_logger.dart';

/// XP awards on the Supabase `profiles` table.
///
/// We can't use a Firestore-style transaction here, so the rollover-aware
/// "xp earned today" reset is done in a single `update` after a `select`:
///
///   1. Read the user's current `total_xp`, `xp_earned_today`,
///      `xp_earned_today_date`.
///   2. If `xp_earned_today_date` doesn't match today, reset its base to 0.
///   3. Compute new XP / level / xpEarnedToday and write them all in one
///      `.update().eq('id', uid)` call.
///
/// Two concurrent awards could race here and one read could see stale
/// totals — acceptable for MVP (XP is monotonic and the worst case is
/// "user awarded same XP twice in quick succession," which the existing
/// step-XP guards prevent anyway).
class XPService {
  final SupabaseClient _supabase;

  XPService({SupabaseClient? supabase})
      : _supabase = supabase ?? Supabase.instance.client;

  /// Award XP to a user. Returns true if user levelled up.
  Future<bool> awardXP({
    required String userId,
    required int amount,
  }) async {
    if (amount <= 0) {
      AppLogger.xp.t('awardXP:noop',
          fields: {'userId': userId, 'amount': amount});
      return false;
    }

    final today = DateFormat('yyyy-MM-dd').format(DateTime.now());
    AppLogger.xp.i('awardXP:start',
        fields: {'userId': userId, 'amount': amount});

    try {
      final row = await _supabase
          .from('profiles')
          .select('total_xp, level, xp_earned_today, xp_earned_today_date')
          .eq('id', userId)
          .maybeSingle();
      if (row == null) {
        AppLogger.xp.w('awardXP:userMissing', fields: {'userId': userId});
        return false;
      }

      final oldXP = (row['total_xp'] as num?)?.toInt() ?? 0;
      final newXP = oldXP + amount;
      final oldLevel = AppConstants.levelForXP(oldXP);
      final newLevel = AppConstants.levelForXP(newXP);

      final storedDate = row['xp_earned_today_date'] as String? ?? '';
      final existingToday = storedDate == today
          ? ((row['xp_earned_today'] as num?)?.toInt() ?? 0)
          : 0;

      await _supabase.from('profiles').update({
        'total_xp': newXP,
        'level': newLevel,
        'xp_earned_today': existingToday + amount,
        'xp_earned_today_date': today,
      }).eq('id', userId);

      final leveledUp = newLevel > oldLevel;
      AppLogger.xp.i('awardXP:done', fields: {
        'userId': userId,
        'amount': amount,
        'oldXP': oldXP,
        'newXP': newXP,
        'oldLevel': oldLevel,
        'newLevel': newLevel,
        'leveledUp': leveledUp,
        'xpEarnedTodayBefore': existingToday,
      });
      return leveledUp;
    } catch (e, s) {
      AppLogger.xp.e('awardXP:failed',
          fields: {'userId': userId, 'amount': amount},
          error: e,
          stack: s);
      rethrow;
    }
  }

  /// Calculate XP earned from steps (10 XP per 1000 steps).
  int xpFromSteps(int steps) {
    return (steps ~/ 1000) * AppConstants.xpPer1000Steps;
  }

  /// Check if daily step goal was reached and award bonus XP. Idempotent
  /// because step XP gating happens upstream in [StepService._awardStepXP].
  Future<bool> checkDailyGoalXP({
    required String userId,
    required int todaySteps,
    required int dailyGoal,
  }) async {
    if (todaySteps >= dailyGoal) {
      return awardXP(userId: userId, amount: AppConstants.xpDailyGoalReached);
    }
    return false;
  }
}
