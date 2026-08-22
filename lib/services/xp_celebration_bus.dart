import 'package:flutter/foundation.dart';

/// Payload for an XP-award event surfaced to the UI via
/// [XPCelebrationBus]. The [amount] is the XP delta; [reason] is the
/// short human label ("Sign-up bonus", "7-day streak", "Keep Streak
/// Alive") that renders under the number in the celebration card.
@immutable
class XPAwardEvent {
  final int amount;
  final String? reason;
  const XPAwardEvent({required this.amount, this.reason});
}

/// App-wide bus that turns [XPService] awards into UI celebrations.
///
/// Deliberately a plain singleton (not a Riverpod provider) because
/// `XPService` is a raw service class with no `ref` — publishing has
/// to be doable from anywhere without dragging in Riverpod. UI code
/// listens by watching [current] and calls [completeCurrent] when the
/// celebration animation finishes so the next queued event surfaces.
///
/// Events that arrive while a celebration is already on-screen queue
/// up in `_queue` and play back sequentially. Nothing is dropped —
/// awarding four XP hits in a row will play four celebrations in the
/// order they were emitted.
class XPCelebrationBus {
  XPCelebrationBus._();

  static final XPCelebrationBus instance = XPCelebrationBus._();

  /// Non-null while a celebration is on-screen. UI observes this to
  /// know what to render.
  final ValueNotifier<XPAwardEvent?> current = ValueNotifier(null);

  /// FIFO of events waiting to play once `current` clears.
  final List<XPAwardEvent> _queue = [];

  /// Publish an event. If nothing is currently showing, the event
  /// becomes `current` immediately; otherwise it queues.
  void enqueue(XPAwardEvent event) {
    if (event.amount <= 0) return;
    if (current.value == null) {
      current.value = event;
    } else {
      _queue.add(event);
    }
  }

  /// Called by the celebration widget when its exit animation
  /// finishes. Advances to the next queued event (or clears).
  void completeCurrent() {
    if (_queue.isNotEmpty) {
      current.value = _queue.removeAt(0);
    } else {
      current.value = null;
    }
  }

  /// Testing-only reset.
  @visibleForTesting
  void reset() {
    _queue.clear();
    current.value = null;
  }
}
