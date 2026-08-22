import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/user_model.dart';
import '../utils/app_logger.dart';
import 'auth_provider.dart';

/// Cross-session tracker that logs every `total_xp` change on the
/// signed-in user's profile under the [LogCategory.xp] Diagnostics
/// filter.
///
/// Every XP source (signup bonus, mission completion, streak milestone,
/// battle win, stake charge, stake refund, XP purchase) writes into
/// `profiles.total_xp` server-side and flows to the client via the
/// realtime `profiles` subscription. This provider watches
/// [currentUserProvider] and emits an [AppLogger.xp] line whenever the
/// numeric value moves.
///
/// Log shape:
///   xp:delta {before: 720, after: 1120, delta: 400}
///
/// Enriched log (best-effort): after a delta, we async-query
/// `public.xp_ledger` for the user's most recent row within the last
/// 10 seconds and, if found, append its `reason` and `context`. That
/// tells the tester WHY the XP moved without cross-referencing a
/// separate SQL probe. Failures are silent — the delta log always
/// fires; the enrichment is a bonus.
///
/// Held alive by [ref.watch(xpDeltaTelemetryProvider)] at the app root
/// (see `app.dart`). Empty return type; the provider exists purely
/// for its side effects.
final xpDeltaTelemetryProvider = Provider<void>((ref) {
  int? lastKnown;
  ref.listen<AsyncValue<UserModel?>>(currentUserProvider, (prev, next) {
    final profile = next.valueOrNull;
    if (profile == null) return;
    final current = profile.totalXP;
    final before = lastKnown;
    lastKnown = current;

    if (before == null) {
      // First emit for this session — this is the seed, not a delta.
      // Log at trace level so testers see the starting point but the
      // Errors filter stays clean.
      AppLogger.xp.t('xpSnapshot:seed', fields: {'totalXp': current});
      return;
    }
    if (before == current) return; // no-op re-emit

    final delta = current - before;
    // Fire the delta log immediately with the raw numbers. The
    // enrichment (reason from xp_ledger) is best-effort and follows
    // in a separate log line so testers see the numeric change
    // without waiting on the round-trip.
    AppLogger.xp.i('xpDelta', fields: {
      'before': before,
      'after': current,
      'delta': delta,
    });

    // Enrich: ask xp_ledger for the most recent credit for this
    // user (any row within the last 10s). If found, log the reason
    // + context so the tester knows WHICH source moved the XP.
    unawaited(_enrichWithLedgerReason(profile.userId, delta));
  });
});

/// Async lookup — best-effort ledger reason lookup after an XP delta.
/// Never throws; a failed lookup just skips the enrichment log.
Future<void> _enrichWithLedgerReason(String userId, int delta) async {
  try {
    final rows = await Supabase.instance.client
        .from('xp_ledger')
        .select('reason, delta, context, created_at, balance_after')
        .eq('user_id', userId)
        .gt('created_at',
            DateTime.now().toUtc().subtract(const Duration(seconds: 15)).toIso8601String())
        .order('created_at', ascending: false)
        .limit(1);
    if (rows.isEmpty) {
      AppLogger.xp.d('xpDelta:reasonUnknown',
          fields: {'delta': delta, 'note': 'no ledger row within 15s'});
      return;
    }
    final row = rows.first;
    AppLogger.xp.i('xpDelta:reason', fields: {
      'delta': delta,
      'ledgerDelta': (row['delta'] as num?)?.toInt(),
      'reason': row['reason'],
      'context': row['context'],
      'balanceAfter': (row['balance_after'] as num?)?.toInt(),
    });
  } catch (e) {
    // Silent — enrichment failure shouldn't spam the log.
    AppLogger.xp.d('xpDelta:enrichFailed', fields: {'err': e.toString()});
  }
}

