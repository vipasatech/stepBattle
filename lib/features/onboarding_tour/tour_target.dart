import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../utils/app_logger.dart';
import 'tour_step.dart';

/// Registry of live TourTarget GlobalKeys, keyed by [TourTargetId].
///
/// **How screens use this:** wrap the widget you want the tour to
/// spotlight in a [TourTarget] with a matching [TourTargetId]. The
/// wrapper self-registers on mount and self-unregisters on dispose;
/// screens don't need to touch the registry directly.
///
/// **How the tour reads this:** [OnboardingTourController] looks up
/// `state[step.targetId]` at fire time, then reads the key's
/// `currentContext.findRenderObject()` to compute the target's global
/// rect. If the key isn't registered yet (screen not mounted, tab not
/// visited), the controller waits one frame + retries — screens on
/// the tour path are guaranteed mounted before the controller advances
/// to a step that targets them (see [OnboardingTourController.next]).
///
/// **Why a StateNotifier and not just a mutable Map:** consumers of
/// `tourTargetsProvider` need to REBUILD when a target registers, so
/// the overlay can start rendering as soon as the target is available.
class TourTargetRegistry extends StateNotifier<Map<TourTargetId, GlobalKey>> {
  TourTargetRegistry() : super(const {});

  void register(TourTargetId id, GlobalKey key) {
    // Rebuild only when the key actually changes — the same TourTarget
    // widget re-registering on hot reload should be a no-op.
    if (state[id] == key) {
      AppLogger.tour.i('target:register:noop', fields: {
        'id': id.name,
        'reason': 'sameKey',
      });
      return;
    }
    final hadPrevious = state.containsKey(id);
    state = {...state, id: key};
    AppLogger.tour.i('target:register', fields: {
      'id': id.name,
      'replacedPrevious': hadPrevious.toString(),
      'registrySize': state.length.toString(),
    });
  }

  void unregister(TourTargetId id, GlobalKey key) {
    // Only unregister if THIS is still the key on file. A rapid mount /
    // unmount of two TourTargets with the same id (e.g. tab switch
    // during a rebuild) can otherwise clobber the new registration.
    if (state[id] != key) {
      AppLogger.tour.i('target:unregister:noop', fields: {
        'id': id.name,
        'reason': state.containsKey(id) ? 'newerKeyOnFile' : 'notRegistered',
      });
      return;
    }
    final next = Map<TourTargetId, GlobalKey>.from(state);
    next.remove(id);
    state = next;
    AppLogger.tour.i('target:unregister', fields: {
      'id': id.name,
      'registrySize': state.length.toString(),
    });
  }
}

final tourTargetsProvider =
    StateNotifierProvider<TourTargetRegistry, Map<TourTargetId, GlobalKey>>(
  (ref) => TourTargetRegistry(),
);

/// Wraps a widget so the tour can spotlight it. Self-registers a
/// [GlobalKey] into [tourTargetsProvider] on mount + unregisters on
/// dispose. Layout-transparent — uses [KeyedSubtree] so the child
/// renders exactly as it would without the wrapper.
///
/// Usage:
/// ```dart
/// TourTarget(
///   id: TourTargetId.homeStepCounter,
///   child: DailyTargetCard(...),
/// )
/// ```
///
/// **Do not** put a TourTarget inside a Builder or a widget that
/// remounts on every frame — the key registration would churn. It's
/// fine for a widget that rebuilds inside a normal Consumer / setState;
/// only remounts (widget-tree slot changes) are the concern.
class TourTarget extends ConsumerStatefulWidget {
  final TourTargetId id;
  final Widget child;

  const TourTarget({
    super.key,
    required this.id,
    required this.child,
  });

  @override
  ConsumerState<TourTarget> createState() => _TourTargetState();
}

class _TourTargetState extends ConsumerState<TourTarget> {
  /// Stable across the widget's lifetime. Created in [initState] so
  /// every rebuild uses the same key — otherwise the registry would
  /// see a new key each frame and the overlay would flicker.
  final GlobalKey _key = GlobalKey(debugLabel: 'TourTarget');

  /// Cached reference to the registry notifier, resolved once from
  /// `ref` in [didChangeDependencies]. Riverpod invalidates the
  /// `ref` handle by the time [dispose] runs, so reading through
  /// `ref` there throws `Cannot use "ref" after the widget was
  /// disposed`. That exception fired on EVERY step transition (each
  /// old-step target unmount) and Flutter's debug error handler
  /// paused to log the full stack trace — 10-50 ms of latency per
  /// disposed TourTarget, which is where the "hang between steps"
  /// the user reported was coming from (2026-09-21). Holding the
  /// notifier reference directly sidesteps `ref` entirely at
  /// tear-down.
  TourTargetRegistry? _registry;

  @override
  void initState() {
    super.initState();
    AppLogger.tour.i('target:initState', fields: {'id': widget.id.name});
    // Defer to post-frame so the child's render object is mounted +
    // laid out before anyone tries to read the rect. The overlay is
    // already tolerant of a missing registration (retries next frame),
    // but registering post-frame avoids one unnecessary retry.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        AppLogger.tour.i('target:register:aborted', fields: {
          'id': widget.id.name,
          'reason': 'unmountedBeforePostFrame',
        });
        return;
      }
      ref.read(tourTargetsProvider.notifier).register(widget.id, _key);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Cache the notifier the first time deps resolve. Providers are
    // stable across the widget's lifetime here (tourTargetsProvider
    // is a top-level StateNotifierProvider that lives with the app
    // container), so the reference stays valid all the way through
    // to dispose.
    _registry ??= ref.read(tourTargetsProvider.notifier);
  }

  @override
  void dispose() {
    // Defer the unregister to a microtask so the notifier's state
    // mutation happens AFTER Flutter finishes finalizing the widget
    // tree. Doing it synchronously here throws:
    //   "Tried to modify a provider while the widget tree was building"
    // — because dispose runs inside `_InactiveElements._unmountAll`
    // which is inside `BuildOwner.finalizeTree` which is inside
    // `WidgetsBinding.drawFrame` (see 2026-09-21 session log stack).
    // Riverpod's debug check for `_debugCanModifyProviders` fires
    // BEFORE the underlying state assignment, so the map never
    // actually loses the stale key AND every listener throws a
    // 20-frame stack that Flutter's error handler serializes to
    // logcat, adding 10-50 ms per exception per transition. That was
    // the "message text updates but position/highlight doesn't"
    // symptom on step 6 → 7 (Start a battle → Pick a format) — the
    // stale registry lookup for step 7's target combined with the
    // exception cascade meant `_measureTarget` couldn't reliably
    // find the newly-registered key AND the frame budget was already
    // spent logging exceptions.
    //
    // The unregister method is idempotent + guards on `state[id] !=
    // key`, so a race with a new TourTarget for the same id
    // registering first won't clobber it. The cached [_registry]
    // reference stays alive because the top-level
    // StateNotifierProvider isn't auto-disposed.
    final registry = _registry;
    final id = widget.id;
    AppLogger.tour.i('target:dispose', fields: {
      'id': id.name,
      'deferring': (registry != null).toString(),
    });
    if (registry != null) {
      Future.microtask(() {
        AppLogger.tour.i('target:disposeMicrotask:fire', fields: {
          'id': id.name,
        });
        registry.unregister(id, _key);
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // KeyedSubtree anchors the key without adding layout — the child
    // paints identically to how it would without this wrapper.
    return KeyedSubtree(key: _key, child: widget.child);
  }
}
