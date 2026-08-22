import 'dart:async';

import 'package:flutter/material.dart';

/// Speech-bubble tooltip anchored to a grey streak flame, with a
/// typewriter reveal. Explains WHY the flame has gone grey (the user
/// is in streak recovery — missed a day) and HOW to save the streak
/// (hit today's mission, then tomorrow's).
///
/// Placement: auto-flips above/below the anchor based on available
/// vertical space; the tail always points at the anchor's centre.
/// Dismisses on tap-outside, tap-on-bubble, or 5 s after typing
/// completes.
///
/// Usage: wrap the flame icon (or its tap target) with this widget.
/// Pass `enabled = true` when the flame is grey. When `enabled` is
/// false, the tap falls through to [onTapWhenDisabled] (used on the
/// Profile Streak stat which normally opens the history sheet).
class StreakGreyTooltip extends StatefulWidget {
  final Widget child;
  final bool enabled;
  final bool inRecovery;
  final bool todayMissionDone;
  final VoidCallback? onTapWhenDisabled;

  const StreakGreyTooltip({
    super.key,
    required this.child,
    required this.enabled,
    required this.inRecovery,
    required this.todayMissionDone,
    this.onTapWhenDisabled,
  });

  /// Copy chosen from the two conditions that can grey the flame.
  /// The flame today greys only when `inRecovery` is true (see
  /// `_StreakStripState` + `_StreakStat`), so we branch on whether
  /// today's mission is already done inside that.
  static String messageFor({
    required bool inRecovery,
    required bool todayMissionDone,
  }) {
    if (inRecovery && !todayMissionDone) {
      return "You missed yesterday, and today's mission isn't done. "
          "Hit your step goal to save the streak.";
    }
    if (inRecovery && todayMissionDone) {
      return "You missed yesterday. Keep the momentum tomorrow to save "
          "the streak.";
    }
    if (!todayMissionDone) {
      return "Today's mission isn't done. Hit your step goal to keep "
          "the streak alive.";
    }
    // Fallback — shouldn't reach here while the flame is grey, but if
    // callers ever wire the tooltip to a coloured state, this reads
    // sensibly instead of showing nothing.
    return "Your streak is safe — keep it up!";
  }

  @override
  State<StreakGreyTooltip> createState() => _StreakGreyTooltipState();
}

class _StreakGreyTooltipState extends State<StreakGreyTooltip> {
  OverlayEntry? _entry;

  void _show() {
    if (_entry != null) return;
    final overlay = Overlay.of(context);
    final anchorBox = context.findRenderObject() as RenderBox?;
    if (anchorBox == null || !anchorBox.attached) return;
    final anchorTopLeft = anchorBox.localToGlobal(Offset.zero);
    final anchorSize = anchorBox.size;

    _entry = OverlayEntry(
      builder: (_) => _TooltipBubble(
        anchorTopLeft: anchorTopLeft,
        anchorSize: anchorSize,
        message: StreakGreyTooltip.messageFor(
          inRecovery: widget.inRecovery,
          todayMissionDone: widget.todayMissionDone,
        ),
        onDismiss: _hide,
      ),
    );
    overlay.insert(_entry!);
  }

  void _hide() {
    _entry?.remove();
    _entry = null;
  }

  @override
  void dispose() {
    _hide();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.enabled ? _show : widget.onTapWhenDisabled,
      child: widget.child,
    );
  }
}

class _TooltipBubble extends StatefulWidget {
  final Offset anchorTopLeft;
  final Size anchorSize;
  final String message;
  final VoidCallback onDismiss;

  const _TooltipBubble({
    required this.anchorTopLeft,
    required this.anchorSize,
    required this.message,
    required this.onDismiss,
  });

  @override
  State<_TooltipBubble> createState() => _TooltipBubbleState();
}

class _TooltipBubbleState extends State<_TooltipBubble>
    with TickerProviderStateMixin {
  static const double _bubbleMaxWidth = 280;
  static const double _bubblePadding = 14;
  static const double _tailHeight = 10;
  static const double _tailWidth = 18;
  static const double _sideMargin = 16;
  static const double _anchorGap = 4;
  static const Duration _charDelay = Duration(milliseconds: 30);
  static const Duration _autoDismissAfter = Duration(seconds: 5);

  int _visibleChars = 0;
  Timer? _typeTimer;
  Timer? _dismissTimer;
  late final AnimationController _caretController;
  late final AnimationController _fadeController;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 160),
    )..forward();
    _caretController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat();
    _typeTimer = Timer.periodic(_charDelay, (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_visibleChars >= widget.message.length) {
        t.cancel();
        _caretController.stop();
        _dismissTimer = Timer(_autoDismissAfter, _dismiss);
        setState(() {});
        return;
      }
      setState(() => _visibleChars++);
    });
  }

  Future<void> _dismiss() async {
    _typeTimer?.cancel();
    _dismissTimer?.cancel();
    if (!mounted) return;
    await _fadeController.reverse();
    widget.onDismiss();
  }

  @override
  void dispose() {
    _typeTimer?.cancel();
    _dismissTimer?.cancel();
    _caretController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final anchorCenter = widget.anchorTopLeft +
        Offset(widget.anchorSize.width / 2, widget.anchorSize.height / 2);

    // Bubble horizontal placement: prefer centred on anchor, then
    // clamp to a safe margin from each screen edge.
    final rawLeft = anchorCenter.dx - _bubbleMaxWidth / 2;
    final maxLeft = size.width - _bubbleMaxWidth - _sideMargin;
    final left = rawLeft.clamp(_sideMargin, maxLeft).toDouble();
    final tailX = anchorCenter.dx - left;

    // Rough vertical budget for the bubble (title fits in ~110 dp; we
    // reserve 140 to be safe including tail). If less than that above
    // the anchor, we flip below.
    const bubbleHeightBudget = 140.0;
    final spaceAbove = widget.anchorTopLeft.dy;
    final placeAbove = spaceAbove > bubbleHeightBudget;

    final visibleText = widget.message.substring(0, _visibleChars);
    final done = _visibleChars >= widget.message.length;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    // Bubble reads as a mono-outline speech bubble on both themes.
    // Dark: dark card fill, white outline. Light: white fill, black
    // outline — matches the reference vector art.
    final fill = isDark ? const Color(0xFF111827) : Colors.white;
    final outline = isDark ? Colors.white : Colors.black;
    final textColor = isDark ? Colors.white : Colors.black;

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _dismiss,
          ),
        ),
        Positioned(
          left: left,
          top: placeAbove
              ? null
              : widget.anchorTopLeft.dy +
                  widget.anchorSize.height +
                  _anchorGap,
          bottom: placeAbove
              ? size.height - widget.anchorTopLeft.dy + _anchorGap
              : null,
          child: FadeTransition(
            opacity: _fadeController,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _dismiss,
              child: SizedBox(
                width: _bubbleMaxWidth,
                child: CustomPaint(
                  painter: _BubbleBackground(
                    fill: fill,
                    outline: outline,
                    tailX: tailX,
                    tailOnBottom: placeAbove,
                    tailHeight: _tailHeight,
                    tailWidth: _tailWidth,
                  ),
                  child: Padding(
                    // Bubble content sits inside the rectangle; the
                    // tail extends outside it, so we reserve the tail's
                    // height on the side that has it.
                    padding: EdgeInsets.fromLTRB(
                      _bubblePadding,
                      _bubblePadding + (placeAbove ? 0 : _tailHeight),
                      _bubblePadding,
                      _bubblePadding + (placeAbove ? _tailHeight : 0),
                    ),
                    child: RichText(
                      text: TextSpan(
                        text: visibleText,
                        style: TextStyle(
                          fontFamily: 'Manrope',
                          fontSize: 13.5,
                          height: 1.35,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                        children: [
                          if (!done)
                            WidgetSpan(
                              alignment: PlaceholderAlignment.middle,
                              child: AnimatedBuilder(
                                animation: _caretController,
                                builder: (_, __) {
                                  final on = _caretController.value < 0.5;
                                  return Opacity(
                                    opacity: on ? 1 : 0,
                                    child: Container(
                                      width: 2,
                                      height: 14,
                                      margin: const EdgeInsets.only(left: 2),
                                      color: textColor,
                                    ),
                                  );
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Paints the speech-bubble outline (rounded rect + triangular tail)
/// as a single unioned path so the stroke wraps the whole shape with
/// no seams where the tail meets the rectangle.
class _BubbleBackground extends CustomPainter {
  final Color fill;
  final Color outline;
  final double tailX;
  final bool tailOnBottom;
  final double tailHeight;
  final double tailWidth;

  _BubbleBackground({
    required this.fill,
    required this.outline,
    required this.tailX,
    required this.tailOnBottom,
    required this.tailHeight,
    required this.tailWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const radius = 12.0;
    final rectTop = tailOnBottom ? 0.0 : tailHeight;
    final rectBottom = tailOnBottom ? size.height - tailHeight : size.height;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTRB(0, rectTop, size.width, rectBottom),
      const Radius.circular(radius),
    );

    final rectPath = Path()..addRRect(rrect);
    final tailPath = Path();
    // Clamp the tail's base so it never sticks out past the rounded
    // corners of the rectangle — otherwise the union stroke breaks.
    final minTailX = radius + tailWidth / 2 + 2;
    final maxTailX = size.width - radius - tailWidth / 2 - 2;
    final safeTailX = tailX.clamp(minTailX, maxTailX);
    if (tailOnBottom) {
      tailPath.moveTo(safeTailX - tailWidth / 2, rectBottom);
      tailPath.lineTo(safeTailX, rectBottom + tailHeight);
      tailPath.lineTo(safeTailX + tailWidth / 2, rectBottom);
      tailPath.close();
    } else {
      tailPath.moveTo(safeTailX - tailWidth / 2, rectTop);
      tailPath.lineTo(safeTailX, rectTop - tailHeight);
      tailPath.lineTo(safeTailX + tailWidth / 2, rectTop);
      tailPath.close();
    }
    final combined = Path.combine(PathOperation.union, rectPath, tailPath);

    canvas.drawPath(
      combined,
      Paint()
        ..color = fill
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      combined,
      Paint()
        ..color = outline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _BubbleBackground old) {
    return old.fill != fill ||
        old.outline != outline ||
        old.tailX != tailX ||
        old.tailOnBottom != tailOnBottom ||
        old.tailHeight != tailHeight ||
        old.tailWidth != tailWidth;
  }
}
