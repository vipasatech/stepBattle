import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/subscription_model.dart';
import '../utils/app_logger.dart';
import 'auth_provider.dart';
import 'user_provider.dart';

/// Live stream of the current-month usage counters from the
/// `subscription_usage_current` view. Emits [SubscriptionUsage.zero]
/// while unauthenticated / before the first row arrives.
///
/// The view is a JOIN between `profiles` and `subscription_usage` —
/// LEFT-JOINed, so a user who hasn't triggered any usage this month
/// still gets a row with zeros (Postgres `COALESCE` in the view).
final _subscriptionUsageStreamProvider =
    StreamProvider<SubscriptionUsage>((ref) {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null) return Stream.value(SubscriptionUsage.zero);

  final supabase = Supabase.instance.client;
  final controller = StreamController<SubscriptionUsage>();
  StreamSubscription<dynamic>? sub;

  Future<void> emitOnce() async {
    try {
      final row = await supabase
          .from('subscription_usage_current')
          .select()
          .eq('user_id', user.id)
          .maybeSingle();
      if (controller.isClosed) return;
      controller.add(
        row == null ? SubscriptionUsage.zero : SubscriptionUsage.fromViewRow(row),
      );
    } catch (e) {
      AppLogger.session.w('subscriptionUsage:fetchFailed',
          fields: {'uid': user.id, 'err': e.toString()});
      if (!controller.isClosed) controller.add(SubscriptionUsage.zero);
    }
  }

  controller.onListen = () {
    // Emit once immediately so UI has data before the realtime stream
    // catches up.
    emitOnce();
    // Realtime — watch the underlying `subscription_usage` table
    // filtered to this user. On every change, re-fetch the view (the
    // view's total_entries column is computed, so we can't reflect
    // it from the raw row alone).
    sub = supabase
        .from('subscription_usage')
        .stream(primaryKey: ['user_id', 'period_start'])
        .eq('user_id', user.id)
        .listen((_) => emitOnce());
  };

  controller.onCancel = () async {
    await sub?.cancel();
    sub = null;
    await controller.close();
  };

  return controller.stream;
});

/// The user's full subscription state — tier + expiry + billing +
/// family role + current usage — composed from [userProfileProvider]
/// (source of tier / expires_at / etc.) and the usage stream above.
///
/// Reads: any UI that gates a battle action calls this and inspects
/// the returned [SubscriptionState.canCreateBattle()] etc.
final subscriptionProvider = Provider<SubscriptionState>((ref) {
  final profile = ref.watch(userProfileProvider).valueOrNull;
  final usage = ref.watch(_subscriptionUsageStreamProvider).valueOrNull
      ?? SubscriptionUsage.zero;

  if (profile == null) return SubscriptionState.basic.copyWith(usage: usage);

  return SubscriptionState(
    tier: profile.subscriptionTier,
    expiresAt: profile.subscriptionExpiresAt,
    billingPeriod: profile.subscriptionBillingPeriod,
    familyOwnerId: profile.familyOwnerId,
    usage: usage,
  );
});

// ─── Convenience single-question providers ───────────────────────────────
//
// UI code that only wants "can I do X" gets a lean boolean provider
// instead of watching the whole SubscriptionState. Each returns a
// [LimitDecision] so the caller has both the yes/no AND the reason /
// upgrade-target when it's a no.

final canCreateBattleProvider = Provider<LimitDecision>((ref) {
  return ref.watch(subscriptionProvider).canCreateBattle();
});

final canJoinPublicBattleProvider = Provider<LimitDecision>((ref) {
  return ref.watch(subscriptionProvider).canJoinPublicBattle();
});

final canJoinPrivateBattleProvider = Provider<LimitDecision>((ref) {
  return ref.watch(subscriptionProvider).canJoinPrivateBattle();
});
