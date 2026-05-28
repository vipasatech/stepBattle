import 'dart:async';

import 'app_logger.dart';

/// Wrap a Supabase realtime stream so transient `RealtimeSubscribeException`s
/// (channelError / timedOut) auto-retry with exponential backoff instead of
/// dropping the consumer onto a raw error state.
///
/// While reconnect attempts are in flight, the wrapped stream emits no new
/// data — consumers see the last-known list. Reconnection state is exposed
/// separately via [realtimeReconnectingProvider] (see battle_provider.dart
/// for an example) so the UI can render a small banner without coupling
/// the data and the connection-status into the same stream.
///
/// [factory] is called every retry to (re)create the underlying stream.
/// [debugLabel] tags the AppLogger output so multi-stream apps can tell
/// which realtime channel is flapping.
Stream<T> retryingRealtimeStream<T>({
  required Stream<T> Function() factory,
  required String debugLabel,
  Duration initialDelay = const Duration(seconds: 2),
  Duration maxDelay = const Duration(seconds: 30),
  void Function(bool reconnecting)? onReconnectingChanged,
}) {
  final controller = StreamController<T>();
  StreamSubscription<T>? sub;
  Timer? retryTimer;
  Duration delay = initialDelay;
  var disposed = false;

  // Forward-declared so [subscribe]'s error/done callbacks can reach it.
  // Assigned just below.
  late void Function() scheduleRetry;

  void subscribe() {
    sub = factory().listen(
      (value) {
        // First successful emit after a retry — reset backoff and clear
        // the banner.
        if (delay != initialDelay) {
          delay = initialDelay;
          onReconnectingChanged?.call(false);
        }
        if (!controller.isClosed) controller.add(value);
      },
      onError: (Object e, StackTrace s) {
        AppLogger.battle.w('realtime:retry',
            fields: {'label': debugLabel, 'delaySec': delay.inSeconds, 'error': e.toString()});
        onReconnectingChanged?.call(true);
        scheduleRetry();
      },
      onDone: () {
        // Server closed the channel without an error — also a transient
        // signal worth retrying so we don't silently lose updates.
        if (!disposed) {
          AppLogger.battle.t('realtime:closedReconnect',
              fields: {'label': debugLabel});
          onReconnectingChanged?.call(true);
          scheduleRetry();
        }
      },
      cancelOnError: true,
    );
  }

  scheduleRetry = () {
    sub?.cancel();
    sub = null;
    retryTimer?.cancel();
    retryTimer = Timer(delay, () {
      if (disposed) return;
      // Exponential backoff with a hard cap.
      delay = Duration(
        milliseconds: (delay.inMilliseconds * 2)
            .clamp(initialDelay.inMilliseconds, maxDelay.inMilliseconds),
      );
      subscribe();
    });
  };

  controller.onListen = subscribe;
  controller.onCancel = () async {
    disposed = true;
    retryTimer?.cancel();
    await sub?.cancel();
  };

  return controller.stream;
}
