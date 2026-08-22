import 'dart:async';
import 'dart:collection';

import 'app_logger.dart';

/// Serial, priority-ordered queue for OS permission dialogs.
///
/// **Why this exists:** Android throws
/// `Can request only one set of permissions at a time` when two
/// permission dialogs try to open concurrently. On StepBattle this
/// happened at login — the PermissionGate's `requestAll()` and the
/// main-shell's `notifications.requestPermission()` fired in parallel;
/// Android accepted the first, silently dropped the second, and the
/// dropped one's `await` never resolved → the entire login flow hung
/// in a "loading" state with no way forward.
///
/// **How this fixes it:** every permission ask MUST go through
/// [PermissionCoordinator.instance.enqueue]. Requests are stored in
/// a min-heap by priority (lower number = runs first) and executed
/// one at a time — the coordinator only fires the next request once
/// the previous one's Future has settled. If two callers enqueue the
/// same permission at the same priority, they get merged onto one
/// underlying request (dedupe) so the OS dialog only appears once
/// and both awaiters resolve when it completes.
///
/// **Priority convention:**
///   1 = ACTIVITY_RECOGNITION (blocks all step counting — ask first)
///   2 = NOTIFICATION         (needed for push and the always-on FGS)
///   3 = HEALTH_CONNECT       (optional accuracy boost)
///   4 = LOCATION             (run-tracking, on-demand only)
///
/// Callers pass whichever priority fits their permission; the exact
/// number matters only for RELATIVE ordering when the queue has
/// multiple items pending.
class PermissionCoordinator {
  PermissionCoordinator._();
  static final PermissionCoordinator instance = PermissionCoordinator._();

  /// Priority-ordered pending requests. Not using a heap library —
  /// the queue is at most 4-5 items so we sort on insert (O(n)) and
  /// remove-first (O(1)). Simpler + no dependency.
  final Queue<_PendingRequest<Object?>> _queue = Queue();

  /// Dedupe map: key = permission tag; value = the in-flight completer.
  /// A second enqueue with the same tag piggy-backs onto the same
  /// underlying `action()` invocation instead of running it twice.
  final Map<String, _InFlight<Object?>> _inFlight = {};

  bool _running = false;

  /// Completers waiting for the queue to drain. Populated by [awaitDrain],
  /// completed by [_tick] when the queue empties. Used by consumers who
  /// need to know "the OS permission dialog is closed, safe to navigate
  /// away now" — the battle-activation auto-router in app.dart is the
  /// canonical example. Without this gate, a route change fires while a
  /// permission dialog is showing → dialog's context dies → its Future
  /// never resolves and the app hangs.
  final List<Completer<void>> _drainListeners = [];

  /// Whether any permission request is currently in flight or queued.
  bool get isFlowActive => _running || _queue.isNotEmpty;

  /// Resolves the next time the queue transitions from non-empty to
  /// empty (or immediately if the queue is already empty). Multiple
  /// callers can await this concurrently — all resolve together when
  /// the drain fires.
  Future<void> awaitDrain() {
    if (!isFlowActive) return Future<void>.value();
    final c = Completer<void>();
    _drainListeners.add(c);
    return c.future;
  }

  void _notifyDrainListeners() {
    if (_drainListeners.isEmpty) return;
    final listeners = List<Completer<void>>.from(_drainListeners);
    _drainListeners.clear();
    for (final c in listeners) {
      if (!c.isCompleted) c.complete();
    }
  }

  /// Enqueue a permission-requesting action. Returns a Future that
  /// resolves with the action's result once the coordinator gets to
  /// this request AND the action completes.
  ///
  /// Two callers passing the SAME [tag] within one session get the
  /// same underlying invocation — the OS dialog fires once, both
  /// awaiters resolve.
  Future<T> enqueue<T>({
    required String tag,
    required int priority,
    required Future<T> Function() action,
  }) {
    // Dedupe: if this tag is already in flight (either queued or
    // actively running), return its completer's future. New callers
    // wait for the same result the original will produce.
    final existing = _inFlight[tag];
    if (existing != null) {
      AppLogger.permission.d('permQueue:dedupe', fields: {'tag': tag});
      return existing.completer.future.then((v) => v as T);
    }

    final completer = Completer<T>();
    _inFlight[tag] = _InFlight<Object?>(
      completer: completer as Completer<Object?>,
    );

    _queue.add(_PendingRequest<Object?>(
      tag: tag,
      priority: priority,
      action: () async {
        try {
          final result = await action();
          if (!completer.isCompleted) completer.complete(result);
        } catch (e, s) {
          if (!completer.isCompleted) completer.completeError(e, s);
        } finally {
          _inFlight.remove(tag);
        }
      },
    ));

    // Sort by priority — cheapest option for a queue this small.
    final sorted = _queue.toList()..sort((a, b) => a.priority.compareTo(b.priority));
    _queue
      ..clear()
      ..addAll(sorted);

    AppLogger.permission.d('permQueue:enqueued', fields: {
      'tag': tag,
      'priority': priority,
      'queueDepth': _queue.length,
    });

    _tick();
    return completer.future;
  }

  /// Pump the queue. Idempotent — if a request is already in flight,
  /// this is a no-op; the current one's `.finally` re-invokes _tick
  /// via the next iteration.
  void _tick() {
    if (_running) return;
    if (_queue.isEmpty) return;
    _running = true;
    scheduleMicrotask(() async {
      while (_queue.isNotEmpty) {
        final item = _queue.removeFirst();
        AppLogger.permission.i('permQueue:running', fields: {
          'tag': item.tag,
          'priority': item.priority,
        });
        try {
          await item.action();
        } catch (_) {
          // Errors already delivered to the caller's completer.
        }
      }
      _running = false;
      _notifyDrainListeners();
    });
  }

  /// Test-only helper — clear the queue and any in-flight state.
  /// Never call from prod code; permission state should persist.
  void resetForTests() {
    _queue.clear();
    _inFlight.clear();
    _drainListeners.clear();
    _running = false;
  }
}

class _PendingRequest<T> {
  final String tag;
  final int priority;
  final Future<void> Function() action;
  _PendingRequest({
    required this.tag,
    required this.priority,
    required this.action,
  });
}

class _InFlight<T> {
  final Completer<T> completer;
  _InFlight({required this.completer});
}

/// Priority constants — use these instead of literals so the queue's
/// ordering rules stay obvious at call sites.
class PermissionPriority {
  PermissionPriority._();
  static const int activityRecognition = 1;
  static const int notification = 2;
  static const int health = 3;
  static const int location = 4;
}
