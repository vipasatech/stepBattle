import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/motion.dart';

/// Tactile scale-down + light haptic feedback wrapper. Layers ON TOP
/// of any child widget without stealing its own tap handling — uses a
/// [Listener] (not GestureDetector) so pointer events pass through to
/// whatever GestureDetector / InkWell / GoRouter link is inside the
/// child tree.
///
/// Usage:
/// ```dart
/// Pressable(
///   child: BattleCard(battle: battle, onTap: () => context.push(...)),
/// )
/// ```
/// The card's own `onTap` fires; Pressable only adds the visual
/// scale-to-0.97 on pointer-down + haptic on pointer-up. Set
/// [hapticOnDown] to fire haptic on press instead of release (rare
/// — release is the modern iOS/Android default).
///
/// Reduced-motion users get [Duration.zero] via [Motion.adaptDuration]
/// so the scale collapses to instant; haptic still fires.
///
/// Compositor-layer only: `Transform.scale` is a paint-time transform,
/// no layout invalidation. Safe in long lists.
class Pressable extends StatefulWidget {
  final Widget child;

  /// Target scale on press. 0.97 is the sweet spot — enough to feel,
  /// not enough to look weird next to un-pressed siblings.
  final double pressedScale;

  /// Whether to fire [HapticFeedback.lightImpact] on pointer-up.
  /// Defaults to true. Set false on rows with heavy composited
  /// children where the extra haptic call might feel out of place.
  final bool haptic;

  /// If true, fire the haptic on pointer-down instead of pointer-up.
  /// iOS system pattern is on-up; only override for buttons where the
  /// press itself IS the action (e.g. a swipe-to-reveal).
  final bool hapticOnDown;

  const Pressable({
    super.key,
    required this.child,
    this.pressedScale = 0.97,
    this.haptic = true,
    this.hapticOnDown = false,
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;

  void _down() {
    if (widget.hapticOnDown && widget.haptic) {
      HapticFeedback.lightImpact();
    }
    setState(() => _pressed = true);
  }

  void _up({required bool commitTap}) {
    if (!_pressed) return;
    if (commitTap && !widget.hapticOnDown && widget.haptic) {
      HapticFeedback.lightImpact();
    }
    setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    // Listener passes events THROUGH to the child's own gesture
    // handling; only observes them. `behavior: HitTestBehavior.deferToChild`
    // means we only see events when a descendant actually hit-tests
    // as pressable, so tapping a non-tap area (e.g., disabled row)
    // won't trigger the scale.
    return Listener(
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: (_) => _down(),
      onPointerUp: (_) => _up(commitTap: true),
      onPointerCancel: (_) => _up(commitTap: false),
      child: AnimatedScale(
        scale: _pressed ? widget.pressedScale : 1.0,
        duration: Motion.adaptDuration(context, Motion.d.fast),
        curve: Motion.curves.emphasized,
        child: widget.child,
      ),
    );
  }
}
