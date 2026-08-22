import 'package:flutter/widgets.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../config/motion.dart';

/// Per-index stagger for widgets built via `ListView.builder` /
/// `.map((...) => child.staggerAt(i, cap: 6))` where the eager
/// [MountStagger] wrapper doesn't fit.
///
/// Only the first [cap] indices animate. Above the cap the widget
/// returns as-is (zero cost).
///
/// Caveat vs. [MountStagger]: a ListView.builder recycles widget
/// instances as the user scrolls. If a top-index row scrolls off-
/// screen and back, flutter_animate treats it as a fresh mount and
/// replays the animation. For long lists (leaderboards, missions)
/// this means re-scrolling to top will re-fire the first 6 rows'
/// stagger — the tradeoff we accept to avoid the memory cost of
/// KeepAlive on every visible row.
extension StaggerIndex on Widget {
  Widget staggerAt(
    int index, {
    int cap = 6,
    Duration duration = const Duration(milliseconds: 380),
    Duration? stagger,
    double slideYBegin = 0.04,
  }) {
    if (index >= cap) return this;
    final stepMs = (stagger ?? Motion.stagger.base).inMilliseconds;
    // We don't have BuildContext here, so respect-reduced-motion
    // check happens at paint time via the same effect chain; the
    // effect resolves near-instantly if the OS clocks Ticker rate
    // to zero. For strict reduce-motion, use MountStagger which
    // short-circuits with context awareness.
    return animate()
        .fadeIn(
          duration: duration,
          delay: Duration(milliseconds: index * stepMs),
          curve: Motion.curves.standard,
        )
        .slideY(
          begin: slideYBegin,
          end: 0,
          duration: duration,
          delay: Duration(milliseconds: index * stepMs),
          curve: Motion.curves.standard,
        );
  }
}

/// Stagger-in helper for a fixed list of top-level children. Wraps
/// each child (up to [animateCount]) in a fade + tiny slide-up with a
/// per-index delay, giving lists and card stacks a "settling into
/// place" mount without touching individual widgets.
///
/// Rules baked in per the motion audit:
///
/// * **First-mount only.** flutter_animate's `Animate` widget holds
///   completion state internally. As long as the parent doesn't
///   re-key the child position, the animation runs once per mount
///   and never on subsequent Riverpod ticks. Pull-to-refresh, provider
///   invalidates, and scroll events do NOT replay the stagger.
///
/// * **Cap on animated count.** Items past [animateCount] render
///   without animation. Prevents a 100-row leaderboard from spending
///   ~7s staggering itself in. Default 6 comfortably fills a phone
///   viewport for card lists.
///
/// * **Compositor-only.** `.fadeIn()` and `.slideY()` mutate Opacity
///   and Transform.translate — paint-layer ops, no layout re-flow.
///   Safe inside a scrolling ListView.
///
/// * **Respects reduce-motion.** Duration + delay collapse to zero
///   via [Motion.adaptDuration] so accessibility users see the final
///   state instantly. Delay values are per-index so a strict zero
///   collapse is enforced by short-circuiting to plain children.
///
/// Usage:
/// ```dart
/// MountStagger(
///   children: [
///     RepaintBoundary(child: StreakStrip()),
///     RepaintBoundary(child: OverviewCard()),
///     ...
///   ],
/// )
/// ```
///
/// The returned widget is a `Column` with `crossAxisAlignment:
/// CrossAxisAlignment.stretch`. Wrap in your own layout container if
/// you want different sizing behaviour.
class MountStagger extends StatelessWidget {
  /// The children to reveal. Rendered in a stretch-aligned Column.
  final List<Widget> children;

  /// Only the first [animateCount] children get the fade+slide effect.
  /// Set higher for hero surfaces; keep default (6) for lists.
  final int animateCount;

  /// Duration of each child's fade+slide.
  final Duration duration;

  /// Delay between consecutive children's animation start times.
  /// Defaults to [Motion.stagger.base] (70ms).
  final Duration? stagger;

  /// Slide-up distance as a fraction of the child's own height. 0.04
  /// = 4% of height, ~2-4dp visible motion — enough to feel "settling
  /// in" without competing with the fade for attention.
  final double slideYBegin;

  const MountStagger({
    super.key,
    required this.children,
    this.animateCount = 6,
    this.duration = const Duration(milliseconds: 380),
    this.stagger,
    this.slideYBegin = 0.04,
  });

  @override
  Widget build(BuildContext context) {
    // Fully-collapse for reduce-motion users. Bypass the Animate
    // wrapper entirely so we don't pay for its controller either.
    final effectiveDuration = Motion.adaptDuration(context, duration);
    if (effectiveDuration == Duration.zero) {
      return Column(
        // mainAxisSize: min so we don't try to fill unbounded vertical
        // space when the parent is a ListView. Without this, children
        // that internally use Stack + Positioned (SwipeableCardStack)
        // receive an infinite-height constraint and throw
        // "BoxConstraints forces an infinite height" at layout.
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }

    final stepMs =
        (stagger ?? Motion.stagger.base).inMilliseconds;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < children.length; i++)
          if (i < animateCount)
            children[i]
                .animate()
                .fadeIn(
                  duration: effectiveDuration,
                  delay: Duration(milliseconds: i * stepMs),
                  curve: Motion.curves.standard,
                )
                .slideY(
                  begin: slideYBegin,
                  end: 0,
                  duration: effectiveDuration,
                  delay: Duration(milliseconds: i * stepMs),
                  curve: Motion.curves.standard,
                )
          else
            children[i],
      ],
    );
  }
}
