import 'dart:async';

import '../services/observability_service.dart';
import 'app_logger.dart';

/// True when [error] is a Supabase realtime subscription failure that the
/// SDK (or [retryingRealtimeStream]) recovers from on its own — i.e. a
/// network flap, not a bug.
///
/// Covers the WebSocket close codes a mobile client actually hits:
///   • `timedOut`      — subscription handshake exceeded its deadline
///   • `channelError`  — channel rejected / dropped mid-subscribe
///   • `code: 1002`    — protocol error, typical of a WiFi↔mobile-data handover
///   • `code: 1006`    — abnormal closure, no close frame received
///
/// Added 2026-10-29. Call sites previously logged these at ERROR, so a
/// single network transition produced a burst of five ERROR entries
/// (profile, battles.watchAll, friendRels asFrom + asTo, and the
/// session-level platformError). That volume of recoverable noise is how
/// the signup-bonus 42501 went unnoticed in Diagnostics for weeks.
/// Classify here, log at DEBUG, and keep ERROR meaning "something is
/// actually broken".
bool isRecoverableRealtimeError(Object? error) {
  if (error == null) return false;
  final msg = error.toString();
  if (!msg.contains('RealtimeSubscribeException') &&
      !msg.contains('RealtimeCloseEvent')) {
    return false;
  }
  return msg.contains('timedOut') ||
      msg.contains('channelError') ||
      msg.contains('code: 1002') ||
      msg.contains('code: 1006');
}

/// Wrap a Supabase realtime stream so transient `RealtimeSubscribeException`s
/// (channelError / timedOut) auto-retry with exponential backoff instead of
/// dropping the consumer onto a raw error state.
///
/// While reconnect attempts are in flight, the wrapped stream emits no new
/// data — consumers see the last-known list. Reconnection state is exposed
/// separately via [onReconnectingChanged] so the UI can render a small
/// banner without coupling the data and the connection-status into the
/// same stream.
///
/// Every state transition (connected / disconnected / reconnecting) drops
/// a Sentry breadcrumb tagged `realtime.<label>` so a crash mid-battle
/// (or any other captured exception) ships with the surrounding realtime
/// activity attached — essential for debugging flaky-connection reports
/// where the raw crash line reveals nothing about what led up to it.
///
/// - [factory] is called every retry to (re)create the underlying stream.
/// - [debugLabel] tags the AppLogger output and the breadcrumb category
///   so multi-stream apps can tell which channel is flapping.
/// - [category] routes log lines into the correct per-domain log file.
///   Defaults to [LogCategory.battle] for backward compatibility with
///   the original callers that were battle-specific.
Stream<T> retryingRealtimeStream<T>({
  required Stream<T> Function() factory,
  required String debugLabel,
  LogCategory category = LogCategory.battle,
  Duration initialDelay = const Duration(seconds: 2),
  Duration maxDelay = const Duration(seconds: 30),
  void Function(bool reconnecting)? onReconnectingChanged,
}) {
  final controller = StreamController<T>();
  final logger = AppLogger.forCategory(category);
  final crumb = 'realtime.$debugLabel';
  StreamSubscription<T>? sub;
  Timer? retryTimer;
  Duration delay = initialDelay;
  var disposed = false;
  var everConnected = false;

  // Forward-declared so [subscribe]'s error/done callbacks can reach it.
  // Assigned just below.
  late void Function() scheduleRetry;

  void subscribe() {
    sub = factory().listen(
      (value) {
        // First successful emit — reset backoff, clear the banner, drop
        // a "connected" breadcrumb so Sentry sees the recovery moment.
        if (!everConnected || delay != initialDelay) {
          everConnected = true;
          delay = initialDelay;
          onReconnectingChanged?.call(false);
          ObservabilityService.breadcrumb(
            'connected',
            category: crumb,
          );
        }
        if (!controller.isClosed) controller.add(value);
      },
      onError: (Object e, StackTrace s) {
        logger.w('realtime:retry', fields: {
          'label': debugLabel,
          'delaySec': delay.inSeconds,
          'error': e.toString(),
        });
        ObservabilityService.breadcrumb(
          'retry',
          category: crumb,
          data: {
            'delaySec': delay.inSeconds,
            'error': e.runtimeType.toString(),
          },
        );
        onReconnectingChanged?.call(true);
        scheduleRetry();
      },
      onDone: () {
        // Server closed the channel without an error — also a transient
        // signal worth retrying so we don't silently lose updates.
        if (!disposed) {
          logger.t('realtime:closedReconnect',
              fields: {'label': debugLabel});
          ObservabilityService.breadcrumb(
            'closed',
            category: crumb,
          );
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
