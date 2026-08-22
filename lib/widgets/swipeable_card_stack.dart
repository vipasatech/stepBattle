import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/colors.dart';
import '../config/motion.dart';

/// A swipe-through stack of cards with progress dots + dead-swipe bounce.
///
/// Behaviour (direction convention flipped in 1.1.6+24 per user request —
/// matches Tinder / most swipe-card patterns):
///   • The front card is fully visible and interactive; up to
///     [peekCount] back cards render behind at progressively smaller
///     scale + downward offset, giving the classic "stack of paper" cue.
///   • Swipe LEFT (past [swipeThreshold] or flung with velocity) commits
///     and advances to the NEXT card. Swipe RIGHT goes back to the
///     PREVIOUS card. Deck is LINEAR — cards don't loop.
///   • Once the user reaches the last card, further LEFT swipes trigger
///     a "dead swipe" animation: the card yields ~1.2× threshold then
///     bounces back with an elastic curve, and a soft haptic click
///     fires so the user physically feels the end of the deck. Same
///     bounce happens on RIGHT swipe from the first card.
///   • Below the stack, a row of dots shows total count + current
///     position. Tapping a dot jumps to that card immediately.
///   • Tap on the front card (no drag) → [onTap] with the current
///     top index. Ideal for opening the item's detail screen.
///
/// Motion:
///   • Drag maps 1:1 to translation + a small rotation proportional
///     to horizontal offset (max ~14°) so the card "tilts" as it goes.
///   • Release below threshold → snap back with the emphasised curve.
///   • Release above threshold on a middle card → animate off screen
///     in ~250ms, advance topIndex, next card promotes.
///   • Release above threshold on the LAST card → dead-swipe bounce.
///
/// Reduced-motion: consumers can gate on `MediaQuery.disableAnimations`
/// externally; internally the widget still uses AnimationController
/// (mostly cubic-beziers) so honouring it just means setting
/// [enabled: false] on the parent to fall back to a static top card.
class SwipeableCardStack extends StatefulWidget {
  final List<Widget> children;

  /// Max cards to render behind the front card. 2 gives the classic
  /// "one card peeking, one more hinted below" look.
  final int peekCount;

  /// Vertical inset between successive back cards, in px. Combined
  /// with [scaleStep] this determines how visible the peek is —
  /// picking values where `stackOffset > (frontHeight * (1 - scaleStep) / 2)`
  /// guarantees the back card's bottom edge peeks below the front card.
  /// Defaults calibrated for a ~200dp card.
  final double stackOffset;

  /// Scale ratio between the front card and the card behind it.
  /// Compounds — the third card is `frontScale * scaleStep^2`.
  final double scaleStep;

  /// Callback when the user taps (not drags) the front card. Receives
  /// the index in [children] of the top item.
  final void Function(int topIndex)? onTap;

  /// Horizontal drag distance (in px) after which release commits a
  /// swipe. Below this it snaps back.
  final double swipeThreshold;

  /// Whether to render the tappable progress dots below the stack.
  /// Turn OFF only for very small decks (say, single-card fallback)
  /// where dots would look silly.
  final bool showDots;

  const SwipeableCardStack({
    super.key,
    required this.children,
    this.peekCount = 2,
    // 24dp offset + 0.92 scaleStep — calibrated so the back card's
    // bottom edge peeks ~12dp below the front card's bottom edge,
    // giving the "stack of paper" hint the previous defaults hid.
    this.stackOffset = 24,
    this.scaleStep = 0.92,
    this.swipeThreshold = 90,
    this.onTap,
    this.showDots = true,
  });

  @override
  State<SwipeableCardStack> createState() => _SwipeableCardStackState();
}

class _SwipeableCardStackState extends State<SwipeableCardStack>
    with SingleTickerProviderStateMixin {
  /// Current top card's position in [widget.children]. Linear — never
  /// wraps back to 0 automatically. The user can tap a dot to jump
  /// backwards / anywhere in the deck.
  int _topIndex = 0;

  /// Active horizontal drag delta (px). Positive = right, negative = left.
  /// Zero when no drag or during the snap/dead-swipe animation.
  double _drag = 0;

  /// True while a commit / dead-swipe animation is in flight; drag
  /// input is ignored until it lands.
  bool _committing = false;

  late final AnimationController _committer;

  bool get _atLastCard => _topIndex >= widget.children.length - 1;

  @override
  void initState() {
    super.initState();
    _committer = AnimationController(vsync: this, duration: Motion.d.base);
    _committer.addListener(() {
      // While committing, _drag is driven by the animation value.
      setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant SwipeableCardStack old) {
    super.didUpdateWidget(old);
    // Rebuild if the child list changed (new items arrived). Preserve
    // topIndex where possible so a data refresh doesn't yank the user's
    // context; clamp so we don't point past the new list's end.
    if (widget.children.length != old.children.length) {
      _topIndex = _topIndex.clamp(0, widget.children.length - 1);
      _drag = 0;
    }
  }

  @override
  void dispose() {
    _committer.dispose();
    super.dispose();
  }

  bool get _atFirstCard => _topIndex <= 0;

  void _onPanUpdate(DragUpdateDetails d) {
    if (_committing) return;
    // Elastic resistance at deck boundaries — even during the drag,
    // the card only follows the finger at 40% strength when the user
    // is trying to swipe past a boundary, so they physically feel the
    // "wall" before releasing.
    //   • drag < 0 (swipe LEFT / advance) is elastic on the last card
    //   • drag > 0 (swipe RIGHT / back) is elastic on the first card
    // Convention flipped in 1.1.6+24 per user request — LEFT=forward
    // matches Tinder / most swipe-card patterns.
    // Mid-deck swipes get full 1:1 tracking either way.
    final delta = d.delta.dx;
    final trying = _drag + delta;
    final hitEnd = _atLastCard && trying < 0;
    final hitStart = _atFirstCard && trying > 0;
    final effectiveDelta = (hitEnd || hitStart) ? delta * 0.4 : delta;
    setState(() => _drag += effectiveDelta);
  }

  void _onPanEnd(DragEndDetails d) {
    if (_committing) return;
    final v = d.velocity.pixelsPerSecond.dx;
    final past = _drag.abs() > widget.swipeThreshold;
    final flung = v.abs() > 700 && v.sign == _drag.sign;
    if (!(past || flung)) {
      _snapBack();
      return;
    }
    // Direction-aware routing (1.1.6+24 — swapped from prior LEFT=back):
    //   • Swipe LEFT  (drag < 0) → advance forward. Dead-swipe on last card.
    //   • Swipe RIGHT (drag > 0) → go back. Dead-swipe on first card.
    // Both directions share the same slide-and-promote animation
    // (with sign flipped for the exit direction) so the visual verb
    // stays consistent — the difference is only which index changes.
    final swipingForward = _drag < 0;
    if (swipingForward) {
      if (_atLastCard) {
        _deadSwipeBounce();
      } else {
        _advance();
      }
    } else {
      if (_atFirstCard) {
        _deadSwipeBounce();
      } else {
        _goBack();
      }
    }
  }

  /// Advance to the next card. The current front card slides LEFT off
  /// screen (matching the LEFT-swipe direction post-1.1.6+24), then
  /// _topIndex increments and the previously-peeked back card takes
  /// its place at full size.
  Future<void> _advance() async {
    _committing = true;
    final screenW = MediaQuery.of(context).size.width;
    final startDrag = _drag;
    final endDrag = -(screenW + 200); // negative = off the LEFT edge
    _committer.duration = Motion.d.base;
    _committer.reset();
    final anim = _committer.drive(
      Tween<double>(begin: startDrag, end: endDrag).chain(
        CurveTween(curve: Motion.curves.emphasized),
      ),
    );
    void update() => setState(() => _drag = anim.value);
    _committer.addListener(update);
    await _committer.forward();
    _committer.removeListener(update);
    if (mounted) {
      setState(() {
        _topIndex = (_topIndex + 1).clamp(0, widget.children.length - 1);
        _drag = 0;
        _committing = false;
      });
    }
  }

  /// Go back to the previous card. Mirror of [_advance] — slides RIGHT
  /// off screen, then _topIndex decrements. Called when swipe is RIGHT
  /// (drag > 0) and there IS a card behind the current one.
  Future<void> _goBack() async {
    _committing = true;
    final screenW = MediaQuery.of(context).size.width;
    final startDrag = _drag;
    final endDrag = screenW + 200; // positive = off the RIGHT edge
    _committer.duration = Motion.d.base;
    _committer.reset();
    final anim = _committer.drive(
      Tween<double>(begin: startDrag, end: endDrag).chain(
        CurveTween(curve: Motion.curves.emphasized),
      ),
    );
    void update() => setState(() => _drag = anim.value);
    _committer.addListener(update);
    await _committer.forward();
    _committer.removeListener(update);
    if (mounted) {
      setState(() {
        _topIndex = (_topIndex - 1).clamp(0, widget.children.length - 1);
        _drag = 0;
        _committing = false;
      });
    }
  }

  /// Dead-swipe bounce — user tried to advance past the last card.
  /// Card is already partially dragged; we animate it to a small
  /// overshoot (roughly the swipeThreshold) then spring it back to
  /// zero with an elastic curve. Fires a light haptic tick so the
  /// user physically feels the "you're at the end" event.
  Future<void> _deadSwipeBounce() async {
    _committing = true;
    HapticFeedback.lightImpact();
    // Phase 1 — tug outward to the overshoot point (fast).
    final direction = _drag < 0 ? -1 : 1;
    final overshoot = direction * (widget.swipeThreshold * 1.35);
    _committer.duration = const Duration(milliseconds: 120);
    _committer.reset();
    final tugAnim = _committer.drive(
      Tween<double>(begin: _drag, end: overshoot).chain(
        CurveTween(curve: Curves.easeOut),
      ),
    );
    void tugUpdate() => setState(() => _drag = tugAnim.value);
    _committer.addListener(tugUpdate);
    await _committer.forward();
    _committer.removeListener(tugUpdate);
    // Phase 2 — spring back to zero with elastic bounce.
    _committer.duration = const Duration(milliseconds: 520);
    _committer.reset();
    final springAnim = _committer.drive(
      Tween<double>(begin: overshoot, end: 0).chain(
        CurveTween(curve: Curves.elasticOut),
      ),
    );
    void springUpdate() => setState(() => _drag = springAnim.value);
    _committer.addListener(springUpdate);
    await _committer.forward();
    _committer.removeListener(springUpdate);
    if (mounted) {
      setState(() {
        _drag = 0;
        _committing = false;
      });
    }
  }

  Future<void> _snapBack() async {
    _committing = true;
    _committer.duration = Motion.d.base;
    _committer.reset();
    final anim = _committer.drive(
      Tween<double>(begin: _drag, end: 0).chain(
        CurveTween(curve: Motion.curves.emphasized),
      ),
    );
    void update() => setState(() => _drag = anim.value);
    _committer.addListener(update);
    await _committer.forward();
    _committer.removeListener(update);
    if (mounted) {
      setState(() {
        _drag = 0;
        _committing = false;
      });
    }
  }

  /// Tapping a dot jumps directly to that card. No animation — the
  /// current front card is replaced instantly (feels like a page jump
  /// rather than a swipe, which is what dot-taps read as in every
  /// mobile carousel).
  void _jumpTo(int index) {
    if (_committing || index == _topIndex) return;
    setState(() {
      _topIndex = index.clamp(0, widget.children.length - 1);
      _drag = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.children.isEmpty) return const SizedBox.shrink();
    if (widget.children.length == 1) return widget.children.first;

    // Which children are currently visible in the stack. Front is at
    // _topIndex; back cards are the next peekCount indices (if they
    // exist — no wrap around, so a deck near its end shows fewer
    // peekers naturally).
    final visibleIndices = <int>[];
    for (int i = 0; i <= widget.peekCount; i++) {
      final idx = _topIndex + i;
      if (idx >= widget.children.length) break;
      visibleIndices.add(idx);
    }

    // Column: Stack + optional dots strip.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          alignment: Alignment.topCenter,
          clipBehavior: Clip.none,
          children: [
            // Back cards FIRST in the list → paint BELOW the front
            // card. Rendered in reverse depth so the deepest sits at
            // the bottom of the paint order.
            for (int i = visibleIndices.length - 1; i >= 1; i--)
              _backCardOverlay(depth: i, childIndex: visibleIndices[i]),
            _frontCard(childIndex: visibleIndices.first),
          ],
        ),
        if (widget.showDots) _buildDots(),
      ],
    );
  }

  /// Back card rendered as a Positioned.fill overlay INSIDE the Stack
  /// (sized to the front card). Scales down from topCenter + offsets
  /// down so the peek strip reads correctly.
  Widget _backCardOverlay({required int depth, required int childIndex}) {
    final scale = _pow(widget.scaleStep, depth);
    final dy = widget.stackOffset * depth;
    // As the front card is dragged, the depth-1 peek card grows
    // slightly toward full size — foreshadows its promotion.
    final progress = (_drag.abs() /
            (MediaQuery.of(context).size.width * 0.6))
        .clamp(0.0, 1.0);
    final scaleBoost = depth == 1 ? progress * (1.0 - scale) : 0.0;
    return Positioned.fill(
      child: IgnorePointer(
        child: Transform.translate(
          offset: Offset(0, dy * (1 - (depth == 1 ? progress : 0))),
          child: Transform.scale(
            alignment: Alignment.topCenter,
            scale: scale + scaleBoost,
            child: Opacity(
              opacity: depth == 2 ? 0.72 : 1.0,
              child: widget.children[childIndex],
            ),
          ),
        ),
      ),
    );
  }

  Widget _frontCard({required int childIndex}) {
    // Map horizontal drag → rotation (radians). At swipeThreshold
    // we're at ~14° tilt, felt like a natural "throwing" gesture.
    // For the dead-swipe elastic phase, the rotation also elastically
    // returns because it's derived from _drag which is animating.
    const maxRot = 0.24; // ~14°
    final rot = (_drag / (widget.swipeThreshold * 2))
        .clamp(-1.0, 1.0) * maxRot;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onTap?.call(childIndex),
      onPanUpdate: _onPanUpdate,
      onPanEnd: _onPanEnd,
      child: Transform.translate(
        offset: Offset(_drag, 0),
        child: Transform.rotate(
          angle: rot,
          child: widget.children[childIndex],
        ),
      ),
    );
  }

  /// Tappable progress dots. Active dot is a stretched pill in brand
  /// violet; inactive dots are small circles at 20% white. Tapping any
  /// dot jumps to that card. Sits directly under the stack with a
  /// small vertical gap so it visually belongs to the deck above.
  Widget _buildDots() {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (int i = 0; i < widget.children.length; i++)
            _Dot(
              active: i == _topIndex,
              onTap: () => _jumpTo(i),
            ),
        ],
      ),
    );
  }
}

/// One dot in the progress row. Active dot is a 20×6 stretched pill,
/// inactive dot is a 6×6 circle. Animates size + color on active
/// changes so tapping a dot feels smoothly connected to the jump.
class _Dot extends StatelessWidget {
  final bool active;
  final VoidCallback onTap;

  const _Dot({required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: Motion.d.fast,
        curve: Motion.curves.standard,
        margin: const EdgeInsets.symmetric(horizontal: 3),
        width: active ? 20 : 6,
        height: 6,
        decoration: BoxDecoration(
          color: active
              ? AppColors.primary
              : AppColors.onSurface.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(3),
        ),
      ),
    );
  }
}

/// Simple positive-integer power. Avoids the dart:math dep + gives
/// us the exact same value each build (no floating-point drift on
/// repeated Math.pow calls).
double _pow(double base, int exp) {
  var r = 1.0;
  for (var i = 0; i < exp; i++) {
    r *= base;
  }
  return r;
}
