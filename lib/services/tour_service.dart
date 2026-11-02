import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/app_logger.dart';
import '../utils/cross_isolate_kv.dart';

/// Persistence + sync for the 7-step new-user tour (migration 0062,
/// 2026-09-04). Design memo: `memory/project_new_user_tour.md`.
///
/// **Two sources of truth, in this order of authority:**
///
/// 1. **Server** — `profiles.has_completed_tour boolean` (migration
///    0062, backfilled to `true` for every profile older than
///    2026-09-04 so existing users are grandfathered out). This is
///    the actual authority: the tour must NEVER fire twice for the
///    same user across devices, and the only way to enforce that is
///    a shared server flag.
///
/// 2. **Local mirror** — [CrossIsolateKV.tourCompletedLocal]. Written
///    every time the server flag is set OR read (server → local
///    sync). Used to gate the tour instantly on cold-start before
///    the profile hydrates, so a returning user never sees the tour
///    flash for the ~200-800ms it takes to load their profile.
///
/// **The gate**: the tour should fire when BOTH the server AND the
/// local mirror agree it hasn't run. If either says complete, don't
/// show it — this is deliberately optimistic (favours "don't fire")
/// so a schema hiccup / rollback / offline read never triggers a
/// surprise re-onboarding for an existing user.
///
/// **What this service does NOT do:** it doesn't decide WHEN to
/// show the tour (that's [OnboardingTourController]), it doesn't
/// render anything, and it doesn't know about the 7 steps. It's
/// purely persistence + sync.
class TourService {
  TourService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  /// Mark the tour COMPLETED — user reached step 7 → FINISH, or
  /// tapped SKIP on any step. Both paths set the flag identically
  /// so the tour never re-fires (until Settings → Replay resets it).
  ///
  /// Writes server first, then local mirror. Server failure is
  /// swallowed + logged — the local mirror still gets set so the
  /// tour doesn't loop this session. Next successful profile write
  /// will sync the flag up.
  Future<void> markCompleted(String userId) async {
    try {
      await _client
          .from('profiles')
          .update({'has_completed_tour': true})
          .eq('id', userId);
      AppLogger.auth.i('tour:server:markedCompleted');
    } catch (e, s) {
      AppLogger.auth.w('tour:server:markCompletedFailed',
          fields: {'err': e.toString()});
      // s intentionally unused — a network blip must not crash the
      // tour completion path. Local mirror below still lets us gate.
      // ignore: unused_local_variable
      final _ = s;
    }
    // Always mirror locally, even if the server write failed — the
    // gate reads local-first and we don't want to loop the tour in
    // this session.
    await CrossIsolateKV.setTourCompletedLocal(true);
  }

  /// Reset the tour — called by the "Replay app tour" row in
  /// Settings. Clears BOTH sources so the next Home visit re-fires
  /// the tour with a clean slate. Same server-then-local order as
  /// [markCompleted].
  Future<void> resetForReplay(String userId) async {
    try {
      await _client
          .from('profiles')
          .update({'has_completed_tour': false})
          .eq('id', userId);
      AppLogger.auth.i('tour:server:resetForReplay');
    } catch (e) {
      AppLogger.auth.w('tour:server:resetFailed',
          fields: {'err': e.toString()});
      // If the server write fails, the local clear below is not
      // enough on its own (other devices will still show completed).
      // But we still clear locally so THIS device re-fires the tour
      // as requested; the user can retry from Settings if they open
      // the app on another device and it doesn't fire.
    }
    await CrossIsolateKV.clearTourCompletedLocal();
  }

  /// Push the server flag into the local mirror. Called by the shell
  /// on every profile hydration so the mirror stays in sync with the
  /// server. Best-effort; a failed local write is logged, not thrown.
  Future<void> syncFromServer(bool serverValue) async {
    final localValue = CrossIsolateKV.getTourCompletedLocalSync();
    if (localValue == serverValue) return; // no-op
    await CrossIsolateKV.setTourCompletedLocal(serverValue);
    AppLogger.auth.i('tour:localMirrorSynced',
        fields: {'from': localValue?.toString() ?? 'null', 'to': serverValue.toString()});
  }

  /// Should the tour fire for this profile? Optimistic false —
  /// returns true only when BOTH the server-side flag and the local
  /// mirror agree it hasn't run. Any ambiguity (missing column, null
  /// local mirror without a hydrated profile) returns false so we
  /// never surprise-onboard an existing user.
  ///
  /// Caller (the shell / router gate) checks other conditions too:
  /// currently on `/home`, no other modals open, survey done, etc.
  static bool shouldFire({
    required bool? serverHasCompleted,
    required bool? localHasCompleted,
  }) {
    // Server says completed OR local says completed → don't fire.
    if (serverHasCompleted == true) return false;
    if (localHasCompleted == true) return false;
    // If the server value hasn't hydrated yet AND the local mirror
    // is null → don't fire yet. Once one of the two answers with a
    // definite `false`, we can fire.
    if (serverHasCompleted == null && localHasCompleted == null) {
      return false;
    }
    return true;
  }
}
