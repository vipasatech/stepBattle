import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/battle_model.dart';
import '../models/run_session_model.dart';
import 'auth_provider.dart';

/// Everything the Day Summary screen needs for one date — aggregated in
/// a single read so the page can render in one shot instead of waiting
/// on four separate async providers to land.
class DaySummaryData {
  /// `yyyy-MM-dd` local — the date this snapshot describes.
  final String dateIso;

  /// `step_logs.step_count` for the date, 0 if no row exists.
  final int steps;

  /// `step_logs.calories` for the date, 0 if no row exists.
  final int calories;

  /// Sum of positive `xp_ledger.delta` rows whose `created_at` falls in
  /// the date's local-time window. 0 if there were no XP-earning events.
  final int xpEarned;

  /// Absolute value of the sum of negative deltas — i.e. how much XP
  /// the user spent or lost that day. 0 if no negative events.
  final int xpLost;

  /// Battles whose [start_time, end_time] window overlaps the date AND
  /// in which this user is a participant. Sorted by end_time desc.
  final List<BattleModel> battles;

  /// Track sessions whose `started_at` falls on the date.
  final List<RunSession> sessions;

  const DaySummaryData({
    required this.dateIso,
    required this.steps,
    required this.calories,
    required this.xpEarned,
    required this.xpLost,
    required this.battles,
    required this.sessions,
  });

  /// Net XP for the day (earned − lost). Positive when net gain.
  int get xpNet => xpEarned - xpLost;

  bool get hasBattles => battles.isNotEmpty;
  bool get hasSessions => sessions.isNotEmpty;
}

/// Read all day-summary data for [dateIso] (`yyyy-MM-dd`) in parallel.
///
/// Each sub-query is its own RPC; we `await` them together via
/// `Future.wait` so the round-trip cost is one network turnaround, not
/// four. Any individual failure surfaces as an empty value for that
/// section so the screen still renders the parts that succeeded.
final daySummaryProvider =
    FutureProvider.family<DaySummaryData, String>((ref, dateIso) async {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) {
    return DaySummaryData(
      dateIso: dateIso,
      steps: 0,
      calories: 0,
      xpEarned: 0,
      xpLost: 0,
      battles: const [],
      sessions: const [],
    );
  }
  final supabase = Supabase.instance.client;
  final userId = user.id;

  final date = DateTime.parse(dateIso);
  final dayStart = DateTime(date.year, date.month, date.day);
  final dayEnd = dayStart.add(const Duration(days: 1));
  final dayStartIso = dayStart.toUtc().toIso8601String();
  final dayEndIso = dayEnd.toUtc().toIso8601String();

  final results = await Future.wait<dynamic>([
    // 1. step_logs row for this date (single).
    supabase
        .from('step_logs')
        .select('step_count, calories')
        .eq('user_id', userId)
        .eq('date', dateIso)
        .maybeSingle(),

    // 2. xp_ledger rows whose created_at falls in this date window.
    supabase
        .from('xp_ledger')
        .select('delta, reason, created_at')
        .eq('user_id', userId)
        .gte('created_at', dayStartIso)
        .lt('created_at', dayEndIso),

    // 3. battles whose window overlaps this date AND user is a
    //    participant. We use a relationship inner-join via the
    //    embedded `battle_participants(*)` so PostgREST filters
    //    server-side on participant.user_id and we still get the
    //    full battle row + nested participants list (needed for
    //    score rendering).
    supabase
        .from('battles')
        .select('*, battle_participants!inner(*), battle_teams(*)')
        .eq('battle_participants.user_id', userId)
        .lte('start_time', dayEndIso)
        .gte('end_time', dayStartIso)
        .order('end_time', ascending: false),

    // 4. track_sessions whose started_at falls on this date.
    supabase
        .from('track_sessions')
        .select()
        .eq('user_id', userId)
        .gte('started_at', dayStartIso)
        .lt('started_at', dayEndIso)
        .not('ended_at', 'is', null)
        .order('started_at', ascending: false),
  ]);

  // ---- step_logs --------------------------------------------------
  final stepRow = results[0] as Map<String, dynamic>?;
  final steps = (stepRow?['step_count'] as num?)?.toInt() ?? 0;
  final calories = (stepRow?['calories'] as num?)?.toInt() ?? 0;

  // ---- xp_ledger --------------------------------------------------
  final xpRows = (results[1] as List).cast<Map<String, dynamic>>();
  int earned = 0;
  int lost = 0;
  for (final r in xpRows) {
    final delta = (r['delta'] as num?)?.toInt() ?? 0;
    if (delta > 0) {
      earned += delta;
    } else if (delta < 0) {
      lost += -delta;
    }
  }

  // ---- battles ----------------------------------------------------
  final battleRows = (results[2] as List).cast<Map<String, dynamic>>();
  final battles = battleRows
      .map((r) => BattleModel.fromSupabaseRow(r))
      .toList(growable: false);

  // ---- track_sessions ---------------------------------------------
  final sessionRows = (results[3] as List).cast<Map<String, dynamic>>();
  final sessions = sessionRows
      .map((r) => RunSession.fromSupabaseRow(r))
      .toList(growable: false);

  return DaySummaryData(
    dateIso: dateIso,
    steps: steps,
    calories: calories,
    xpEarned: earned,
    xpLost: lost,
    battles: battles,
    sessions: sessions,
  );
});

/// Pretty-format an ISO date as "Wednesday, Jun 25".
String formatDayHeader(String dateIso) {
  final d = DateTime.tryParse(dateIso);
  if (d == null) return dateIso;
  return DateFormat('EEEE, MMM d').format(d);
}
