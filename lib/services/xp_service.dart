import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/constants.dart';
import '../utils/app_logger.dart';
import 'xp_celebration_bus.dart';

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
  ///
  /// [reason] is a short human label shown under the "+X XP" number
  /// in the celebration popup ("Sign-up bonus", "7-day streak",
  /// "Keep Streak Alive"). Purely cosmetic — the actual XP is stored
  /// as a monotonic total on the profile row.
  Future<bool> awardXP({
    required String userId,
    required int amount,
    String? reason,
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
      // Surface the award to the UI celebration overlay. Queued so
      // rapid back-to-back awards (streak + mission on the same
      // sync) each play their own animation instead of merging.
      XPCelebrationBus.instance.enqueue(
        XPAwardEvent(amount: amount, reason: reason),
      );
      return leveledUp;
    } catch (e, s) {
      AppLogger.xp.e('awardXP:failed',
          fields: {'userId': userId, 'amount': amount},
          error: e,
          stack: s);
      rethrow;
    }
  }

  /// Streak-based XP awards — called after the daily streak counter
  /// has been persisted. Two payouts:
  ///
  ///   • First-ever 7-day streak → +50 XP (once per user, guarded by
  ///     `profiles.has_awarded_7day_streak`).
  ///   • Every 30-day milestone (30, 60, 90, …) crossed by the user's
  ///     bestStreak → +100 XP per new milestone. Guarded by
  ///     `profiles.last_awarded_30day_milestone` so a broken-then-
  ///     rebuilt streak never re-pays milestones the user already
  ///     received.
  ///
  /// Returns the total XP awarded in this call (0 if nothing new).
  Future<int> checkStreakMilestones({
    required String userId,
    required int currentStreak,
    required int bestStreak,
  }) async {
    if (currentStreak <= 0 && bestStreak <= 0) return 0;
    try {
      final row = await _supabase
          .from('profiles')
          .select(
              'has_awarded_7day_streak, last_awarded_30day_milestone')
          .eq('id', userId)
          .maybeSingle();
      if (row == null) return 0;

      final has7DayFlag =
          (row['has_awarded_7day_streak'] as bool?) ?? false;
      final last30Milestone =
          (row['last_awarded_30day_milestone'] as num?)?.toInt() ?? 0;

      int totalAwarded = 0;
      final updates = <String, dynamic>{};

      // 7-day: once ever, first time bestStreak reaches 7. Never
      // re-fires after a streak break.
      if (!has7DayFlag && bestStreak >= 7) {
        await awardXP(
          userId: userId,
          amount: AppConstants.xpFirst7DayStreak,
          reason: '7-day streak',
        );
        totalAwarded += AppConstants.xpFirst7DayStreak;
        updates['has_awarded_7day_streak'] = true;
      }

      // 30-day: every milestone the user's bestStreak has crossed
      // that we haven't paid out yet. `(bestStreak ~/ 30) * 30` is the
      // highest completed milestone; the diff from what we last paid
      // is how many +100 payouts we owe.
      final currentMilestone = (bestStreak ~/ 30) * 30;
      if (currentMilestone > last30Milestone) {
        final milestonesOwed =
            (currentMilestone - last30Milestone) ~/ 30;
        for (var i = 0; i < milestonesOwed; i++) {
          final milestoneReached =
              last30Milestone + (i + 1) * 30;
          await awardXP(
            userId: userId,
            amount: AppConstants.xp30DayStreakMilestone,
            reason: '$milestoneReached-day streak',
          );
          totalAwarded += AppConstants.xp30DayStreakMilestone;
        }
        updates['last_awarded_30day_milestone'] = currentMilestone;
      }

      if (updates.isNotEmpty) {
        await _supabase.from('profiles').update(updates).eq('id', userId);
        AppLogger.xp.i('checkStreakMilestones:awarded', fields: {
          'userId': userId,
          'currentStreak': currentStreak,
          'bestStreak': bestStreak,
          'totalAwarded': totalAwarded,
          ...updates,
        });
      }
      return totalAwarded;
    } catch (e, s) {
      AppLogger.xp.e('checkStreakMilestones:failed',
          fields: {'userId': userId}, error: e, stack: s);
      return 0;
    }
  }
}
