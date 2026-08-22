import 'dart:async';

/// Trailing debounce for a source Stream: collapses bursts of events
/// into one emit at the end of a quiet window.
///
/// Useful for realtime streams that fan out expensive follow-up work
/// (heavy JOIN refetches, network round-trips). A 4-participant team
/// battle emitting a `battle_participants.current_steps` update from
/// every player once per 60s sync tick will collapse to a single
/// downstream emit inside a 500 ms window instead of firing four
/// full-battle JOIN queries in rapid succession.
///
/// Semantics:
///   • Every incoming event resets the wait timer to [duration].
///   • When the timer elapses with no further event, the most recent
///     value is emitted downstream.
///   • Errors pass through immediately (no debounce on error).
///   • On upstream `done`, any pending value flushes before close.
///
/// This is a lightweight local reimplementation of RxDart's
/// `.debounceTime()` — the repo doesn't depend on rxdart and a
/// single-purpose helper is cheaper than adding one.
Stream<T> debounceTrailing<T>(Stream<T> src, Duration duration) {
  final controller = StreamController<T>();
  Timer? timer;
  T? pending;
  bool hasPending = false;

  StreamSubscription<T>? sub;
  sub = src.listen(
    (value) {
      pending = value;
      hasPending = true;
      timer?.cancel();
      timer = Timer(duration, () {
        if (hasPending) {
          controller.add(pending as T);
          hasPending = false;
        }
      });
    },
    onError: controller.addError,
    onDone: () {
      timer?.cancel();
      if (hasPending) {
        controller.add(pending as T);
        hasPending = false;
      }
      controller.close();
    },
    cancelOnError: false,
  );

  controller.onCancel = () async {
    timer?.cancel();
    await sub?.cancel();
    sub = null;
  };

  return controller.stream;
}
