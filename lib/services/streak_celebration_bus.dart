import 'dart:async';

/// Pub/sub for streak-tick events. Fired by [DailyTargetCard] the moment
/// `advance_daily_progress` returns a credited result; listened by any
/// streak widget that wants to play a tick-up animation (Home streak
/// strip, Profile streak card, etc.).
///
/// Buffers the LAST event within a short replay window so late-attaching
/// subscribers still get the celebration. Reason: the broadcast stream
/// used to drop events with no listeners; if the StreakStrip was unmounted
/// (e.g. user was on another tab) when the credit RPC returned, the
/// animation never played. With replay, remounting Home within the
/// window still triggers the animation from the buffered event.
class StreakCelebrationBus {
  StreakCelebrationBus._();
  static final instance = StreakCelebrationBus._();

  final _controller = StreamController<StreakCelebration>.broadcast();
  StreakCelebration? _last;
  DateTime? _lastEmittedAt;

  /// Any listener that subscribes within this window of an emit gets
  /// the last event replayed. Longer than a typical tab switch, short
  /// enough that stale celebrations don't fire on a fresh open of the
  /// app the next day.
  static const _replayWindow = Duration(seconds: 5);

  /// Subscribe to celebrations. If an event was emitted within the
  /// replay window, the listener receives it immediately (in the next
  /// microtask, so callers don't get called back synchronously during
  /// `initState`). Returns a subscription — cancel it in dispose.
  StreamSubscription<StreakCelebration> subscribe(
    void Function(StreakCelebration) onEvent,
  ) {
    final last = _last;
    final at = _lastEmittedAt;
    if (last != null &&
        at != null &&
        DateTime.now().difference(at) <= _replayWindow) {
      // Deliver the buffered event on the next microtask so the
      // subscriber has a chance to finish initState / mount its
      // AnimationController before the callback fires.
      Future.microtask(() => onEvent(last));
    }
    return _controller.stream.listen(onEvent);
  }

  void emit({
    required int streakBefore,
    required int streakAfter,
    required int xpCredited,
    required bool recovered,
    required bool milestone,
  }) {
    final event = StreakCelebration(
      streakBefore: streakBefore,
      streakAfter: streakAfter,
      xpCredited: xpCredited,
      recovered: recovered,
      milestone: milestone,
    );
    _last = event;
    _lastEmittedAt = DateTime.now();
    _controller.add(event);
  }
}

class StreakCelebration {
  final int streakBefore;
  final int streakAfter;
  final int xpCredited;
  final bool recovered;
  final bool milestone;

  const StreakCelebration({
    required this.streakBefore,
    required this.streakAfter,
    required this.xpCredited,
    required this.recovered,
    required this.milestone,
  });
}
