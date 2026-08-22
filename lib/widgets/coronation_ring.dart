import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Monochrome-gold ring animation for the leaderboard-#1 avatar.
///
/// Replaces the earlier multi-colour ConfettiBurst — same "you are the
/// champion" intent, but framed as coronation instead of birthday.
/// Two behaviours in one widget:
///   • **Ambient loop** (always on when `ambientLoop == true`): slow,
///     soft gold rings pulsing outward from behind the avatar. Present
///     on every leaderboard open so the top-1 spot reads as premium
///     even in a screenshot.
///   • **One-shot pulse**: brighter, larger, plays once. Fires whenever
///     [oneShotTrigger] changes value (e.g. the current user just hit
///     rank 1, or the tab was re-focused).
///
/// Respects `MediaQuery.disableAnimations` — reduced-motion users get a
/// static gold ring at rest rather than continuous motion.
class CoronationRing extends StatefulWidget {
  final Widget child;

  /// Diameter of the avatar the child renders at. The ring layer sizes
  /// itself to this so the pulses radiate outward from the avatar edge,
  /// not from a padded box.
  final double avatarSize;

  /// Change this value to fire a one-shot pulse. Common uses:
  ///   • `_pulseTrigger` int on the parent, incremented on tab-focus
  ///     tick or when the current user becomes #1.
  ///   • Widget mount already fires an initial one-shot regardless.
  final int oneShotTrigger;

  /// Whether the slow ambient loop plays continuously. Disable for a
  /// pure one-shot use (achievement toasts, etc.).
  final bool ambientLoop;

  /// Ring stroke colour. Defaults to a warm champion-gold; callers
  /// pass a project-scoped shade (e.g. the leaderboard hero uses the
  /// Strava-style KOM gold) so the rings match the crown + rim exactly.
  final Color ringColor;

  const CoronationRing({
    super.key,
    required this.child,
    required this.avatarSize,
    this.oneShotTrigger = 0,
    this.ambientLoop = true,
    this.ringColor = const Color(0xFFF0B429),
  });

  @override
  State<CoronationRing> createState() => _CoronationRingState();
}

class _CoronationRingState extends State<CoronationRing>
    with TickerProviderStateMixin {
  static const _oneShotDuration = Duration(milliseconds: 1500);
  static const _ambientDuration = Duration(milliseconds: 3600);

  late final AnimationController _oneShot;
  late final AnimationController _ambient;

  @override
  void initState() {
    super.initState();
    _oneShot = AnimationController(vsync: this, duration: _oneShotDuration);
    _ambient = AnimationController(vsync: this, duration: _ambientDuration);

    if (widget.ambientLoop) _ambient.repeat();

    // Kick off an initial one-shot on mount so the very first paint
    // greets the user with the strong pulse.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _oneShot.forward(from: 0);
    });
  }

  @override
  void didUpdateWidget(covariant CoronationRing old) {
    super.didUpdateWidget(old);
    if (old.oneShotTrigger != widget.oneShotTrigger) {
      _oneShot.forward(from: 0);
    }
    if (old.ambientLoop != widget.ambientLoop) {
      widget.ambientLoop ? _ambient.repeat() : _ambient.stop();
    }
  }

  @override
  void dispose() {
    _oneShot.dispose();
    _ambient.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Reserve enough space around the avatar for the largest ring to
    // reach without being clipped. One-shot ring peaks at ~2.55x — so
    // pad to avatarSize * 2.6.
    final boxSize = widget.avatarSize * 2.6;

    // Respect reduced-motion: skip animations, keep the resting gold
    // border via the caller's avatar (which owns its own permanent
    // ring) — nothing else to render here.
    final disableAnim = MediaQuery.of(context).disableAnimations;

    return SizedBox(
      width: boxSize,
      height: boxSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (!disableAnim)
            RepaintBoundary(
              child: AnimatedBuilder(
                animation: Listenable.merge([_oneShot, _ambient]),
                builder: (_, __) => CustomPaint(
                  size: Size(boxSize, boxSize),
                  painter: _CoronationRingsPainter(
                    avatarDiameter: widget.avatarSize,
                    color: widget.ringColor,
                    oneShotProgress:
                        _oneShot.isAnimating ? _oneShot.value : null,
                    ambientProgress:
                        widget.ambientLoop ? _ambient.value : null,
                  ),
                ),
              ),
            ),
          widget.child,
        ],
      ),
    );
  }
}

/// Paints up to four gold rings around the avatar:
///   • Two one-shot rings (staggered by 0.28) — bright, larger scale,
///     only when a one-shot is in flight.
///   • Two ambient rings (staggered by half the loop) — soft, smaller
///     scale, always looping.
class _CoronationRingsPainter extends CustomPainter {
  final double avatarDiameter;
  final Color color;
  final double? oneShotProgress;
  final double? ambientProgress;

  _CoronationRingsPainter({
    required this.avatarDiameter,
    required this.color,
    required this.oneShotProgress,
    required this.ambientProgress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final baseRadius = avatarDiameter / 2;

    if (ambientProgress != null) {
      _drawAmbient(canvas, center, baseRadius, ambientProgress!);
      // Second ambient ring offset half a cycle so at least one is
      // always mid-flight — feels continuous rather than "pulse then
      // pause."
      _drawAmbient(canvas, center, baseRadius, (ambientProgress! + 0.5) % 1);
    }

    if (oneShotProgress != null) {
      _drawOneShot(canvas, center, baseRadius, oneShotProgress!);
      // Second ring lags 0.28 behind for the coronation-moment stack.
      final second = oneShotProgress! - 0.28;
      if (second > 0) {
        _drawOneShot(canvas, center, baseRadius, second);
      }
    }
  }

  void _drawAmbient(Canvas canvas, Offset center, double baseR, double t) {
    // t: 0 → 1 across the loop.
    // scale 0.94 → 2.15; opacity peaks ~0.55 near t=0.22, fades to 0.
    final scale = 0.94 + (2.15 - 0.94) * t;
    final peak = 0.22;
    final opacity = t < peak
        ? (t / peak) * 0.55
        : (1 - (t - peak) / (1 - peak)) * 0.55;
    if (opacity <= 0) return;
    final paint = Paint()
      ..color = color.withValues(alpha: opacity.clamp(0.0, 0.55))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..isAntiAlias = true;
    canvas.drawCircle(center, baseR * scale, paint);
  }

  void _drawOneShot(Canvas canvas, Offset center, double baseR, double t) {
    if (t <= 0 || t >= 1) return;
    // Ease-out cubic. Scale 0.92 → 2.55; opacity peaks ~0.95 at t=0.18,
    // fades to 0 at t=1.
    final eased = 1 - math.pow(1 - t, 3).toDouble();
    final scale = 0.92 + (2.55 - 0.92) * eased;
    const peak = 0.18;
    final opacity = t < peak
        ? (t / peak) * 0.95
        : (1 - (t - peak) / (1 - peak)) * 0.95;
    if (opacity <= 0) return;
    // Stroke thins as the ring expands — mimics real light dissipating.
    final stroke = 2.0 - 1.25 * t;
    final paint = Paint()
      ..color = color.withValues(alpha: opacity.clamp(0.0, 0.95))
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke.clamp(0.5, 2.0)
      ..isAntiAlias = true;
    canvas.drawCircle(center, baseR * scale, paint);
  }

  @override
  bool shouldRepaint(covariant _CoronationRingsPainter old) =>
      old.oneShotProgress != oneShotProgress ||
      old.ambientProgress != ambientProgress ||
      old.color != color;
}
