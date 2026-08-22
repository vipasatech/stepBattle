import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The current Flutter app lifecycle state, exposed as a Riverpod
/// [StateProvider] so downstream providers can gate work on whether
/// the UI is actually in the foreground.
///
/// Written by [MainShell.didChangeAppLifecycleState]. Read by
/// providers whose polling / periodic work should pause when the app
/// isn't in front of the user — e.g. the 60s pedometer aggregator
/// tick: while the app is backgrounded, the foreground service and
/// WorkManager fallback own step sync, so the UI-side timer would be
/// pure waste.
///
/// Defaults to [AppLifecycleState.resumed] because at provider-init
/// time the app is by definition alive — the observer in MainShell
/// only fires on transitions, so we can't rely on it having emitted
/// yet the first time a listener reads this.
final appLifecycleStateProvider = StateProvider<AppLifecycleState>(
  (ref) => AppLifecycleState.resumed,
);
