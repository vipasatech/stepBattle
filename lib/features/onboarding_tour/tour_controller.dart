import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../services/tour_service.dart';
import '../../utils/app_logger.dart';
import '../../utils/cross_isolate_kv.dart';
import 'tour_step.dart';

/// State carried by [OnboardingTourController]. Immutable so Riverpod
/// consumers only rebuild when something actually changed.
class TourControllerState {
  /// True while the overlay should be rendering. False when the tour
  /// hasn't started, has been skipped, or has finished.
  final bool active;

  /// Zero-based index into [kTourSteps]. Meaningful only when [active].
  final int stepIndex;

  /// When set, the tour was started via a scoped info-icon replay
  /// beginning at this index. Consumed by tour_overlay to hide the
  /// Back button on the FIRST step of that scoped run so pressing
  /// Back doesn't decrement to a step outside the scoped tab.
  /// Null on the full-tour path (first-run gate + Settings replay).
  final int? scopedFromIndex;

  const TourControllerState({
    required this.active,
    required this.stepIndex,
    this.scopedFromIndex,
  });

  const TourControllerState.idle()
      : active = false,
        stepIndex = 0,
        scopedFromIndex = null;

  TourControllerState copyWith({bool? active, int? stepIndex}) =>
      TourControllerState(
        active: active ?? this.active,
        stepIndex: stepIndex ?? this.stepIndex,
        // scopedFromIndex is set only at [startFromStep] time and
        // cleared by going idle; copyWith always preserves it.
        scopedFromIndex: scopedFromIndex,
      );

  /// Convenience — the currently-active step, or null when idle. All
  /// UI branches on this being non-null.
  TourStep? get currentStep {
    if (!active) return null;
    if (stepIndex < 0 || stepIndex >= kTourSteps.length) return null;
    return kTourSteps[stepIndex];
  }
}

/// Riverpod-managed controller for the 7-step new-user tour. Drives
/// [OnboardingTourOverlay] (renders per-step visuals) and is listened
/// to by [MainShell] (switches to `currentStep.tab` when stepIndex
/// changes so the target widget is mounted before the overlay tries
/// to spotlight it).
///
/// **Does not** decide WHEN to fire — that gate lives in the shell
/// (needs profile hydration + no other modal open + on Home tab).
///
/// **Does not** persist anything itself — delegates to [TourService]
/// so the "server flag + local mirror" contract stays in one place.
class OnboardingTourController extends StateNotifier<TourControllerState> {
  OnboardingTourController(this._ref) : super(const TourControllerState.idle());

  final Ref _ref;

  /// Fire the tour from the beginning (step 0). No-op when already
  /// active. Called by the shell's first-run gate.
  void start() {
    if (state.active) {
      AppLogger.tour.i('start:skipped', fields: {'reason': 'alreadyActive'});
      return;
    }
    AppLogger.tour.i('start', fields: {'totalSteps': kTourSteps.length.toString()});
    state = const TourControllerState(active: true, stepIndex: 0);
  }

  /// Fire the tour SCOPED to a step range — used by the info-icon
  /// replays on Home + Battles so a user re-triggering the tour from
  /// a specific page only sees THAT page's steps, not the full 13.
  ///
  ///   • `fromIndex` — inclusive start (0-based index into kTourSteps).
  ///   • `untilExclusive` — exclusive end; if null, runs to the end.
  ///
  /// The controller stashes `untilExclusive` so [next] can transition
  /// to `idle` (calling [markCompleted] locally — but NOT flipping the
  /// server flag, since a scoped replay is a partial view of the tour
  /// and doesn't count as "completed the whole thing" if the user
  /// already finished it once).
  void startFromStep(int fromIndex, {int? untilExclusive}) {
    if (fromIndex < 0 || fromIndex >= kTourSteps.length) return;
    if (state.active) return;
    _scopedUntilExclusive = untilExclusive;
    _scopedFromIndex = fromIndex;
    final firstStep = kTourSteps[fromIndex];
    AppLogger.tour.i('startFromStep', fields: {
      'from': fromIndex.toString(),
      'until': untilExclusive?.toString() ?? 'end',
      'firstTargetId': firstStep.targetId.name,
      'firstSheet': firstStep.sheet?.name ?? 'null',
      'firstTab': firstStep.tab.name,
    });
    state = TourControllerState(
      active: true,
      stepIndex: fromIndex,
      scopedFromIndex: fromIndex,
    );
  }

  /// When set, [next] treats reaching this index as "finished" and
  /// exits the tour instead of advancing further. Cleared on any
  /// finish/skip path. Null = normal full-tour behaviour.
  int? _scopedUntilExclusive;

  /// Inclusive lower bound for a scoped replay — the step index
  /// [startFromStep] was called with. [back] treats reaching this
  /// index as "at the start" and EXITS the tour instead of
  /// decrementing further (which would surface a step from another
  /// tab, e.g. going Back from the Battles-scoped replay's first
  /// step surfacing the Home tour's Save Goal step). Null = normal
  /// full-tour behaviour, [back] stops at stepIndex 0.
  int? _scopedFromIndex;

  /// Re-entrancy guard for [next]. Set to `true` while an interceptor
  /// from [tourNextInterceptorProvider] is running; the interceptor's
  /// own action (e.g. `_invitePlayers` in the team lobby) may call
  /// [next] recursively to advance the state after opening a sheet,
  /// and that recursive call MUST bypass the interceptor lookup or
  /// it would re-fire the same interceptor forever.
  bool _interceptorFiring = false;

  /// Advance to the next step, or finish if we're already on the last
  /// step. Called by the NEXT / FINISH pill.
  Future<void> next() async {
    if (!state.active) {
      AppLogger.tour.i('next:noop', fields: {'reason': 'notActive'});
      return;
    }
    // Interceptor lookup (2026-09-22 afternoon). Certain steps —
    // Confirm the team battle (18), Lock the stake (22), Invite
    // players (23) — register a callback in
    // [tourNextInterceptorProvider] that routes a Next tap on the
    // tour card to the SAME action the underlying button fires.
    // Skipped on recursive calls (see [_interceptorFiring]).
    if (!_interceptorFiring) {
      final overrides = _ref.read(tourNextInterceptorProvider);
      final currentTarget = state.currentStep?.targetId;
      if (currentTarget != null && overrides.containsKey(currentTarget)) {
        final interceptor = overrides[currentTarget]!;
        AppLogger.tour.i('next:interceptor:invoke', fields: {
          'atStep': state.stepIndex.toString(),
          'targetId': currentTarget.name,
        });
        _interceptorFiring = true;
        var interceptorThrew = false;
        try {
          await interceptor();
        } catch (e) {
          interceptorThrew = true;
          AppLogger.tour.e('next:interceptor:threw', fields: {
            'targetId': currentTarget.name,
            'error': e.toString(),
          });
          // Evict the failing interceptor so a stale closure (from a
          // widget that disposed without cleaning up) can't deadlock
          // subsequent Next taps. Without this, the outer advance
          // loop in the battles_screen tour listener would keep
          // calling next() → same throw → infinite loop at ~2 k
          // iterations/s (2026-09-22 afternoon log evidence).
          final current = _ref.read(tourNextInterceptorProvider);
          if (current.containsKey(currentTarget)) {
            _ref.read(tourNextInterceptorProvider.notifier).state = {
              ...current,
            }..remove(currentTarget);
            AppLogger.tour.i('next:interceptor:evicted', fields: {
              'targetId': currentTarget.name,
            });
          }
        } finally {
          _interceptorFiring = false;
        }
        // If the interceptor threw and left the state unchanged,
        // fall through to the normal advance path so the tour still
        // progresses. If it completed cleanly (or the interceptor is
        // still responsible for driving state itself), return here
        // as before.
        if (!interceptorThrew) return;
      }
    }
    final nextIndex = state.stepIndex + 1;
    // Full-tour end: past the last step → finish (persists completion).
    if (nextIndex >= kTourSteps.length) {
      AppLogger.tour.i('next:endOfCatalog', fields: {
        'at': state.stepIndex.toString(),
      });
      await finish();
      return;
    }
    // Scoped-replay end: reached the caller's `untilExclusive` → exit
    // WITHOUT persisting completion (a scoped info-icon replay doesn't
    // count as finishing the full tour).
    final limit = _scopedUntilExclusive;
    if (limit != null && nextIndex >= limit) {
      AppLogger.tour.i('next:scopedExit', fields: {
        'at': nextIndex.toString(),
        'limit': limit.toString(),
      });
      _scopedUntilExclusive = null;
      _scopedFromIndex = null;
      state = const TourControllerState.idle();
      return;
    }
    final fromStep = state.currentStep;
    final toStep = kTourSteps[nextIndex];
    AppLogger.tour.i('next', fields: {
      'from': state.stepIndex.toString(),
      'to': nextIndex.toString(),
      'fromTargetId': fromStep?.targetId.name ?? 'null',
      'fromSheet': fromStep?.sheet?.name ?? 'null',
      'toTargetId': toStep.targetId.name,
      'toSheet': toStep.sheet?.name ?? 'null',
      'toTab': toStep.tab.name,
      'toAllowInteract': toStep.allowTargetInteraction.toString(),
    });
    state = state.copyWith(stepIndex: nextIndex);
  }

  /// Step back one (min 0 for the full tour, or [_scopedFromIndex]
  /// for a scoped info-icon replay). When Back is pressed on the
  /// FIRST step of a scoped replay, we EXIT the tour instead of
  /// decrementing into a step from another tab — 2026-09-21 user
  /// feedback: pressing Back on step 6 "Start a battle" (the first
  /// step of the Battles-scoped replay) was surfacing step 5 "Save
  /// your new goal" from the Home tour, which is confusing UX.
  ///
  /// The Back button is also hidden in the overlay at this boundary
  /// (`hasBack` guard in tour_overlay), so under normal use this
  /// method's scoped-exit branch is defence-in-depth against
  /// programmatic back calls or a stale button tap.
  void back() {
    if (!state.active) return;
    final floor = _scopedFromIndex ?? 0;
    if (state.stepIndex <= floor) {
      // Only exit if this IS a scoped replay — a full-tour back on
      // step 0 is still a no-op (matches pre-2026-09-21 behaviour).
      if (_scopedFromIndex != null) {
        AppLogger.tour.i('back:scopedExit',
            fields: {'at': state.stepIndex.toString(), 'floor': floor.toString()});
        _scopedUntilExclusive = null;
        _scopedFromIndex = null;
        state = const TourControllerState.idle();
      } else {
        AppLogger.tour.i('back:atStep0');
      }
      return;
    }
    final fromStep = state.currentStep;
    final toStep = kTourSteps[state.stepIndex - 1];
    AppLogger.tour.i('back', fields: {
      'from': state.stepIndex.toString(),
      'to': (state.stepIndex - 1).toString(),
      'fromTargetId': fromStep?.targetId.name ?? 'null',
      'toTargetId': toStep.targetId.name,
      'toSheet': toStep.sheet?.name ?? 'null',
    });
    state = state.copyWith(stepIndex: state.stepIndex - 1);
  }

  /// Skip the tour — same persistence effect as [finish] (both mark
  /// the user as done so it never re-fires until Replay) but doesn't
  /// walk through the remaining steps. Called by the "Skip" text link.
  Future<void> skip() async {
    if (!state.active) return;
    final scoped = _scopedFromIndex != null;
    AppLogger.tour.i('skip', fields: {
      'atStep': state.stepIndex.toString(),
      'atTargetId': state.currentStep?.targetId.name ?? 'null',
      'scoped': scoped.toString(),
    });
    _scopedUntilExclusive = null;
    _scopedFromIndex = null;
    _ref.read(tourOverlaySuspendedProvider.notifier).state = false;
    await _persistCompletion();
    state = const TourControllerState.idle();
  }

  /// Complete the tour after the last step's FINISH tap.
  Future<void> finish() async {
    if (!state.active) return;
    AppLogger.tour.i('finish', fields: {
      'atStep': state.stepIndex.toString(),
    });
    _scopedUntilExclusive = null;
    _scopedFromIndex = null;
    _ref.read(tourOverlaySuspendedProvider.notifier).state = false;
    await _persistCompletion();
    state = const TourControllerState.idle();
  }

  /// Called by Settings → "Replay app tour". Resets both server flag
  /// and local mirror so the next Home visit re-fires the tour, then
  /// starts it immediately (assumes the caller is already on Home; if
  /// not, the shell's gate will re-detect and fire on next Home entry).
  Future<void> replay() async {
    final userAsync = _ref.read(currentUserProvider);
    final user = userAsync.valueOrNull;
    if (user == null) {
      AppLogger.auth.w('tour:replay:noUser');
      return;
    }
    final service = _ref.read(tourServiceProvider);
    await service.resetForReplay(user.userId);
    // Fire immediately — the user asked for it, don't wait for a
    // navigation to re-trigger the shell gate.
    start();
  }

  /// Shared server + local persistence path for both skip + finish.
  /// Swallow errors — a network blip must not leave the tour in a
  /// half-state where it re-fires next session.
  Future<void> _persistCompletion() async {
    final userAsync = _ref.read(currentUserProvider);
    final user = userAsync.valueOrNull;
    if (user == null) {
      // No user? Still write the local mirror so THIS session doesn't
      // re-fire. The auth listener will sync to server when a user
      // eventually shows up.
      await CrossIsolateKV.setTourCompletedLocal(true);
      return;
    }
    final service = _ref.read(tourServiceProvider);
    await service.markCompleted(user.userId);
  }
}

/// Provider for [TourService] — one instance per session, no per-user
/// state (the service is stateless; user id is passed per-call).
final tourServiceProvider = Provider<TourService>((ref) => TourService());

/// When true, the [OnboardingTourOverlay] renders nothing (no dim, no
/// card, no spotlight) even while the tour is technically active. Used
/// to hide the overlay during a known "waiting for the next screen to
/// finish loading" gap — currently just the confirm-team-battle →
/// team-lobby transition, where the createTeamLobby RPC + page push
/// takes 500-1500 ms and showing a floating card during that window
/// looks like the tour is stuck. The overlay auto-clears the flag on
/// its first successful `measure:committed` for the new step, so the
/// tour reappears smoothly the moment the target mounts.
///
/// Set to true by the battles_screen team-flow branch right after
/// `showTeamBattleConfirmDialog` returns true; cleared by the overlay.
final tourOverlaySuspendedProvider = StateProvider<bool>((_) => false);

/// Map of tour-target ids → callbacks that intercept the tour card's
/// Next tap. Widgets that own an action-with-an-obvious-button (Use
/// entry & open in the team confirm dialog, Confirm stake + Invite
/// players in the team lobby) register a callback on mount so a Next
/// tap on the card triggers the SAME action the button fires — the
/// user shouldn't have to hunt for a specific button when the tour
/// card's forward affordance is right there.
///
/// Registration protocol (used by `_TeamBattleConfirmDialogState` and
/// `_TeamLobbyPageState`):
///   • On mount (in a `Future.microtask` off `initState` to avoid
///     mutating a provider during widget build):
///       `notifier.state = { ...notifier.state, id: callback };`
///   • On dispose:
///       `notifier.state = { ...notifier.state }..remove(id);`
///
/// The callback is invoked by [OnboardingTourController.next] with
/// the re-entrancy guard [OnboardingTourController._interceptorFiring]
/// set to `true`, so the callback can call `notifier.next()` itself
/// to advance the state without re-firing the interceptor.
final tourNextInterceptorProvider =
    StateProvider<Map<TourTargetId, Future<void> Function()>>((_) => {});

/// The battle-format the user chose in [NewBattleSelectionSheet]
/// during the tour: null (none), 0 (1v1), 1 (Multi), 2 (Team).
///
/// The sheet updates this when the user taps its Continue button,
/// and BattlesScreen's tour listener reads it after the sheet
/// closes to decide the next tour path:
///   • null → user tapped tour's Next without picking → default 1v1
///   • 0    → open Battle1v1SetupSheet + continue with steps 7-10
///   • 1/2  → user is exploring a non-1v1 format → skip past all
///            1v1-specific steps to step 11 (Discover)
///
/// Reset to null every time the tour arrives on step 6 so a re-run
/// starts fresh.
final tourBattleFormatChoiceProvider = StateProvider<int?>((_) => null);

/// Provider for the tour controller. Auto-disposed with the app —
/// there's no per-route lifecycle concern here since the shell owns
/// the overlay for the whole authenticated session.
final tourControllerProvider =
    StateNotifierProvider<OnboardingTourController, TourControllerState>(
  (ref) => OnboardingTourController(ref),
);
