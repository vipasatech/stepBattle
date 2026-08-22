import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config/colors.dart';
import '../../../providers/auth_provider.dart';
import '../../../services/background_sync.dart';
import '../../../utils/cross_isolate_kv.dart';

/// Banner that appears on Home when the always-on foreground service
/// has stopped ticking (heartbeat older than [_staleTtl]).
///
/// The FGS is what keeps step-sync happening every 5 min while the app
/// is backgrounded — if it dies (user swiped its notification away,
/// battery saver killed it, an OEM crash), step data stops syncing to
/// the cloud until the next foreground open. This banner detects that
/// state and offers a one-tap restart.
///
/// Android-only. iOS doesn't run FGS the same way; the banner
/// self-suppresses on iOS.
class KeepTrackingBanner extends ConsumerStatefulWidget {
  const KeepTrackingBanner({super.key});

  /// FGS heartbeat freshness threshold. Matches [_fgAliveTtl] in
  /// background_sync.dart — if the FGS hasn't stamped a marker within
  /// this window, we consider it dead.
  static const Duration _staleTtl = Duration(minutes: 10);

  @override
  ConsumerState<KeepTrackingBanner> createState() =>
      _KeepTrackingBannerState();
}

class _KeepTrackingBannerState extends ConsumerState<KeepTrackingBanner>
    with WidgetsBindingObserver {
  Timer? _pollTimer;
  bool _stale = false;
  bool _restarting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // First check runs after the first frame so the widget's already
    // mounted when we potentially trigger a rebuild.
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    // Re-poll every 30s while on Home so the banner appears / hides
    // as the FGS state changes (e.g., user swipes away the notification
    // → we detect within 30s and show the banner).
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) => _check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Also check on foreground so a user who dismissed the FGS
    // notification while the app was backgrounded sees the banner
    // immediately on return.
    if (state == AppLifecycleState.resumed) _check();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _check() {
    if (!mounted) return;
    if (!Platform.isAndroid) return;
    // Only show for signed-in users — anonymous users don't have a FGS.
    final uid = ref.read(authStateProvider).valueOrNull?.id;
    if (uid == null) {
      if (_stale) setState(() => _stale = false);
      return;
    }
    final ms = CrossIsolateKV.getIntSync(CrossIsolateKV.fgAliveAtMs);
    final now = DateTime.now().millisecondsSinceEpoch;
    final ageMs = ms == null ? double.infinity : (now - ms).toDouble();
    final stale = ageMs > KeepTrackingBanner._staleTtl.inMilliseconds;
    if (stale != _stale) {
      setState(() => _stale = stale);
    }
  }

  Future<void> _restart() async {
    if (_restarting) return;
    setState(() => _restarting = true);
    try {
      // Force-restart, NOT startService — the FGS is technically "running"
      // per the plugin's internal state (that's why we're staring at a
      // stale heartbeat, not "never started"). startService would early-
      // return on the `isRunningService` guard and this button would be
      // a dead click. restartService stops unconditionally and starts
      // fresh; see background_sync.dart docstring for the full "zombie
      // service" scenario this handles.
      await BackgroundSync.restartService();
      // Give the FGS a moment to write its first heartbeat, then re-check.
      await Future<void>.delayed(const Duration(seconds: 2));
      _check();
    } finally {
      if (mounted) setState(() => _restarting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) return const SizedBox.shrink();
    if (!_stale) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.amber.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.amber.withValues(alpha: 0.35)),
        ),
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Row(
          children: [
            Icon(
              Icons.pause_circle_outline,
              color: AppColors.amber,
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Live tracking paused',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: AppColors.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Background step sync stopped. Tap Resume to keep '
                    'your history exact.',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: _restarting ? null : _restart,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.amber,
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
              ),
              child: _restarting
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text(
                      'Resume',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
