import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config/colors.dart';
import '../../../providers/auth_provider.dart';
import '../../../services/background_sync.dart';
import '../../../utils/cross_isolate_kv.dart';

/// Bare sync-status icon in the Home app bar. Same 36×36 tap target as
/// the bell button beside it, but WITHOUT the chip background — just
/// the glyph on the page ground. Colour alone carries the state:
///
///  - **Idle** — FGS heartbeat fresh: muted `onSurface` icon. Tap
///    surfaces a "Step sync is healthy" snackbar and does NOT touch
///    the FGS (nothing to restart when the service is already ticking).
///  - **Stale** — FGS heartbeat >10 min old: amber icon. Tap calls
///    [BackgroundSync.restartService] to force-wake the service, then
///    polls the heartbeat for up to 5 s so the icon flips back to
///    muted as soon as the FGS is confirmed alive.
///
/// History:
///   1.1.6+26 — first shipped as a hide-when-idle amber chip with
///              a border, appearing only when action was needed.
///   1.1.6+27 — always-visible with matching bell-button chip
///              background so it sat cleanly next to the bell.
///   1.1.6+29 — chip removed per user feedback ("just keep the icon
///              instead of wrapping it in the box"). Icon reads as
///              the sole indicator; the bell keeps its chip.
///
/// Android-only. iOS doesn't run FGS the same way; self-suppresses.
class ResumeTrackingIconButton extends ConsumerStatefulWidget {
  const ResumeTrackingIconButton({super.key});

  /// FGS heartbeat freshness threshold. Same 10-min TTL as
  /// [_fgAliveTtl] in [BackgroundSync] and the (now-deprecated)
  /// KeepTrackingBanner — one source of truth for "how long without a
  /// heartbeat before we call the service dead."
  static const Duration _staleTtl = Duration(minutes: 10);

  @override
  ConsumerState<ResumeTrackingIconButton> createState() =>
      _ResumeTrackingIconButtonState();
}

class _ResumeTrackingIconButtonState
    extends ConsumerState<ResumeTrackingIconButton>
    with WidgetsBindingObserver {
  Timer? _pollTimer;
  bool _stale = false;
  bool _restarting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) => _check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
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
    final uid = ref.read(authStateProvider).valueOrNull?.id;
    if (uid == null) {
      if (_stale) setState(() => _stale = false);
      return;
    }
    final ms = CrossIsolateKV.getIntSync(CrossIsolateKV.fgAliveAtMs);
    final now = DateTime.now().millisecondsSinceEpoch;
    final ageMs = ms == null ? double.infinity : (now - ms).toDouble();
    final stale =
        ageMs > ResumeTrackingIconButton._staleTtl.inMilliseconds;
    if (stale != _stale) {
      setState(() => _stale = stale);
    }
  }

  Future<void> _onTap() async {
    if (_restarting) return;
    // Idle branch: purely confirmatory. No FGS restart because there's
    // nothing to restart — the service is already ticking. Skipping
    // the restart avoids resetting a healthy heartbeat window every
    // time a curious user taps.
    if (!_stale) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Step sync is healthy'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    setState(() => _restarting = true);
    // Show immediate feedback — user tapped, we're doing something.
    // Since the icon is visually small, a SnackBar reinforces the
    // action landed.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Resuming step sync…'),
        duration: Duration(seconds: 2),
      ),
    );
    try {
      await BackgroundSync.restartService();
      // Poll for the first fresh heartbeat instead of a single
      // hardcoded delay. Rationale (1.1.6+29): the prior implementation
      // waited a flat 2 s then called _check() once. On slower OEM
      // boots (moto g35, older Xiaomi) the FGS often takes 3-5 s to
      // write its first fgAliveAtMs marker, so the single check saw
      // _stale=true and the icon stayed amber until the 30 s
      // periodic tick — long after the user had clearly seen the
      // "Resuming step sync…" toast and expected the icon to flip.
      // Poll every 300 ms for up to 5 s, break as soon as
      // _stale flips false, and if it never does the amber stays —
      // which is honest (restart genuinely didn't recover, e.g. the
      // sessionRefresh:refreshTokenDead case seen in Diagnostics).
      const pollInterval = Duration(milliseconds: 300);
      const pollBudget = Duration(seconds: 5);
      final deadline = DateTime.now().add(pollBudget);
      while (mounted && _stale && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(pollInterval);
        if (!mounted) break;
        _check();
      }
    } finally {
      if (mounted) setState(() => _restarting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    // Colour is the sole state signal now that the chip background is
    // gone — amber shouts "needs attention", muted onSurface reads as
    // a passive status glyph parked next to the bell.
    final Color iconColor = _stale
        ? AppColors.amber
        : scheme.onSurface.withValues(alpha: 0.6);

    // 36×36 tap target (icon is 20 px; 8 px of transparent padding on
    // each side matches the bell button's touch footprint, so both
    // hit areas feel identical even though only the bell is chipped).
    return Semantics(
      label: _stale
          ? 'Resume step tracking'
          : 'Step sync healthy — tap to check',
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: SizedBox(
            width: 20,
            height: 20,
            child: _restarting
                ? CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(AppColors.amber),
                  )
                : Icon(
                    Icons.sync_rounded,
                    size: 20,
                    color: iconColor,
                  ),
          ),
        ),
      ),
    );
  }
}
