import 'dart:async';

import 'package:flutter/material.dart';

import '../config/colors.dart';

/// Tooltip-shaped affordance anchored to the home streak flame — state
/// aware. Behaviour depends on whether the flame is dormant (grey) or
/// active (orange):
///
///   • **Dormant** — 0-day streak OR recovery mode: shows the existing
///     speech-bubble tooltip with a typewriter reveal explaining WHY
///     the flame is grey and HOW to fix it (`messageFor`). Content
///     preserved verbatim from the pre-2026-08-30 revision.
///
///   • **Active** — streak ≥ 1 and not in recovery: shows a compact
///     button-styled pill anchored to the flame with the current
///     streak count and a chevron on the right edge signalling the pill
///     itself is tappable. This is a NEW variant added 2026-08-30 to
///     give the active flame the same tap affordance as the grey one
///     (previously tap-on-orange was a no-op).
///
/// Both variants are TAPPABLE. Tapping the bubble / pill body fires
/// [onOpenSheet] and dismisses; tap-outside dismisses without firing.
///
/// Placement: shared speech-bubble mechanism auto-flips above/below the
/// anchor based on available vertical space; the tail always points at
/// the anchor's centre. Dismisses on tap-outside, tap-on-body, or 5 s
/// after typing / pill entrance completes.
///
/// Usage: wrap the flame icon (or its tap target) with this widget.
/// [showActivePopup] controls whether the active-state pill is shown at
/// all. When false (Profile stats strip), an active-state tap opens the
/// sheet directly without the intermediate pill — preserves the
/// existing profile-tab UX which the home-tab redesign should not
/// change.
class StreakGreyTooltip extends StatefulWidget {
  final Widget child;
  final bool inRecovery;
  final bool todayMissionDone;

  /// Current streak day count. Drives the pill copy in the active
  /// variant and lets [messageFor] handle the fresh-user (0-day, no
  /// recovery) case with copy that reads better than the generic
  /// "your streak is safe" fallback the pre-2026-08-30 version fell
  /// through to.
  final int currentStreak;

  /// Called when the popup body (bubble or pill) is tapped. The widget
  /// dismisses the popup FIRST, then fires this callback — so the
  /// caller can safely open a sheet from the same context without
  /// overlay-stacking artifacts.
  final VoidCallback onOpenSheet;

  /// When true (default): active flame tap shows the pill popup; the
  /// user taps the pill body to open the sheet. When false: active
  /// flame tap opens the sheet directly (no popup step). Dormant state
  /// always shows the bubble regardless. Set false on surfaces that
  /// already treat the streak stat as a direct sheet trigger — namely
  /// the Profile stats strip, where the popup would be a regression.
  final bool showActivePopup;

  const StreakGreyTooltip({
    super.key,
    required this.child,
    required this.inRecovery,
    required this.todayMissionDone,
    required this.currentStreak,
    required this.onOpenSheet,
    this.showActivePopup = true,
  });

  /// Copy chosen from the two conditions that can grey the flame + a
  /// fresh-user (0-day, not in recovery) case that pre-2026-08-30 fell
  /// through to a generic fallback. All original branches preserved.
  ///
  /// Callers pass the current streak count so 0-day users get a
  /// welcoming "Start your streak" message instead of the vestigial
  /// "Your streak is safe" fallback.
  static String messageFor({
    required bool inRecovery,
    required bool todayMissionDone,
    required int currentStreak,
  }) {
    if (inRecovery && !todayMissionDone) {
      return "You missed yesterday, and today's mission isn't done. "
          "Hit your step goal to save the streak.";
    }
    if (inRecovery && todayMissionDone) {
      return "You missed yesterday. Keep the momentum tomorrow to save "
          "the streak.";
    }
    // Fresh user with no streak yet — friendly onboarding message.
    if (currentStreak == 0 && !todayMissionDone) {
      return "Start your streak — complete today's mission to earn day 1.";
    }
    if (currentStreak == 0 && todayMissionDone) {
      return "Great start! Come back tomorrow to grow your streak.";
    }
    // Retained legacy branches — active streak with today's mission
    // outstanding. Not reachable while the tooltip only fires on grey
    // flames, but callers that wire it to a coloured state get a
    // sensible line instead of nothing.
    if (!todayMissionDone) {
      return "Today's mission isn't done. Hit your step goal to keep "
          "the streak alive.";
    }
    return "Your streak is safe — keep it up!";
  }

  @override
  State<StreakGreyTooltip> createState() => _StreakGreyTooltipState();
}

class _StreakGreyTooltipState extends State<StreakGreyTooltip> {
  OverlayEntry? _entry;

  bool get _dormant => widget.inRecovery || widget.currentStreak == 0;

  void _handleTap() {
    if (_dormant) {
      _showBubble();
      return;
    }
    if (!widget.showActivePopup) {
      // Direct-open flow (Profile stats strip). Preserves the pre-fix
      // one-tap-to-sheet behaviour that surface has had for months.
      widget.onOpenSheet();
      return;
    }
    _showActivePill();
  }

  void _showBubble() => _mountOverlay(dormant: true);
  void _showActivePill() => _mountOverlay(dormant: false);

  void _mountOverlay({required bool dormant}) {
    if (_entry != null) return;
    final overlay = Overlay.of(context);
    final anchorBox = context.findRenderObject() as RenderBox?;
    if (anchorBox == null || !anchorBox.attached) return;
    final anchorTopLeft = anchorBox.localToGlobal(Offset.zero);
    final anchorSize = anchorBox.size;

    _entry = OverlayEntry(
      builder: (_) => _PopupHost(
        anchorTopLeft: anchorTopLeft,
        anchorSize: anchorSize,
        onDismiss: _hide,
        onOpenSheet: () {
          _hide();
          widget.onOpenSheet();
        },
        variant: dormant
            ? _PopupVariant.bubble
            : _PopupVariant.activePill,
        bubbleMessage: StreakGreyTooltip.messageFor(
          inRecovery: widget.inRecovery,
          todayMissionDone: widget.todayMissionDone,
          currentStreak: widget.currentStreak,
        ),
        activeStreakDays: widget.currentStreak,
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
      onTap: _handleTap,
      child: widget.child,
    );
  }
}

// =============================================================================
// Overlay host — one widget, two visual variants. Sharing the mount
// scaffolding (screen-tap-to-dismiss scrim + anchor-relative Positioned)
// keeps both variants pixel-consistent in their placement heuristics.
// =============================================================================

enum _PopupVariant { bubble, activePill }

class _PopupHost extends StatefulWidget {
  final Offset anchorTopLeft;
  final Size anchorSize;
  final VoidCallback onDismiss;
  final VoidCallback onOpenSheet;
  final _PopupVariant variant;

  // bubble variant only:
  final String bubbleMessage;

  // activePill variant only:
  final int activeStreakDays;

  const _PopupHost({
    required this.anchorTopLeft,
    required this.anchorSize,
    required this.onDismiss,
    required this.onOpenSheet,
    required this.variant,
    required this.bubbleMessage,
    required this.activeStreakDays,
  });

  @override
  State<_PopupHost> createState() => _PopupHostState();
}

class _PopupHostState extends State<_PopupHost>
    with TickerProviderStateMixin {
  static const double _sideMargin = 16;
  static const double _anchorGap = 4;
  static const double _tailHeight = 10;
  static const double _tailWidth = 18;

  // Bubble-variant constants (preserved from the pre-2026-08-30 impl).
  static const double _bubbleMaxWidth = 280;
  static const double _bubblePadding = 14;
  static const Duration _charDelay = Duration(milliseconds: 30);

  // Active-pill constants (new).
  static const double _pillMaxWidth = 220;
  static const double _pillVerticalPadding = 10;
  static const double _pillHorizontalPadding = 14;

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

    if (widget.variant == _PopupVariant.bubble) {
      // Bubble variant retains the typewriter reveal.
      _caretController = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 700),
      )..repeat();
      _typeTimer = Timer.periodic(_charDelay, (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        if (_visibleChars >= widget.bubbleMessage.length) {
          t.cancel();
          _caretController.stop();
          _dismissTimer = Timer(_autoDismissAfter, _dismiss);
          setState(() {});
          return;
        }
        setState(() => _visibleChars++);
      });
    } else {
      // Active pill has no typewriter — instant fade-in; still
      // auto-dismisses after 5 s so it doesn't linger if the user
      // walks away without acting.
      _caretController = AnimationController(vsync: this);
      _dismissTimer = Timer(_autoDismissAfter, _dismiss);
    }
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

    final popupWidth = widget.variant == _PopupVariant.bubble
        ? _bubbleMaxWidth
        : _pillMaxWidth;

    // Horizontal placement: prefer centred on anchor, then clamp to a
    // safe margin from each screen edge.
    final rawLeft = anchorCenter.dx - popupWidth / 2;
    final maxLeft = size.width - popupWidth - _sideMargin;
    final left = rawLeft.clamp(_sideMargin, maxLeft).toDouble();
    final tailX = anchorCenter.dx - left;

    // Vertical: place ABOVE the anchor if there's ~140 dp of headroom,
    // otherwise BELOW. Same heuristic for both variants keeps them
    // consistent in placement.
    const bubbleHeightBudget = 140.0;
    final spaceAbove = widget.anchorTopLeft.dy;
    final placeAbove = spaceAbove > bubbleHeightBudget;

    Widget popup;
    if (widget.variant == _PopupVariant.bubble) {
      popup = _bubbleContent(tailX: tailX, placeAbove: placeAbove);
    } else {
      popup = _pillContent(tailX: tailX, placeAbove: placeAbove);
    }

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // Tap-outside dismisses WITHOUT firing onOpenSheet — the
            // sheet only opens when the popup body itself is tapped.
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
            // Bubble variant keeps the fixed-width slot (its typewriter
            // reveal + speech-bubble outline read best at a stable
            // width). Pill variant hugs its content via IntrinsicWidth
            // centred inside the same slot so the orange outline sits
            // tight around the icon + label + chevron (2026-08-31
            // feedback — the old fixed 220 px pill had a big gap
            // between "streak" and the arrow).
            child: SizedBox(
              width: popupWidth,
              child: widget.variant == _PopupVariant.activePill
                  ? Center(child: IntrinsicWidth(child: popup))
                  : popup,
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Bubble content — grey-state variant. Preserved verbatim (aside
  // from the wrapping GestureDetector calling onOpenSheet instead of
  // onDismiss) so the visual and typewriter behaviour do not shift for
  // recovery-mode users.
  // ---------------------------------------------------------------------------

  Widget _bubbleContent({required double tailX, required bool placeAbove}) {
    final visibleText = widget.bubbleMessage.substring(0, _visibleChars);
    final done = _visibleChars >= widget.bubbleMessage.length;
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final fill = isDark ? const Color(0xFF111827) : Colors.white;
    final outline = isDark ? Colors.white : Colors.black;
    final textColor = isDark ? Colors.white : Colors.black;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onOpenSheet,
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
          padding: EdgeInsets.fromLTRB(
            _bubblePadding,
            _bubblePadding + (placeAbove ? 0 : _tailHeight),
            _bubblePadding,
            _bubblePadding + (placeAbove ? _tailHeight : 0),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              RichText(
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
              // Once the typewriter finishes, reveal a right-aligned
              // "Open streak ›" affordance so the bubble reads as a
              // tappable button, not just an info card. Matches the
              // active-pill chevron behaviour. Wrapped in AnimatedOpacity
              // so it fades in cleanly rather than popping the moment
              // the last character lands.
              if (done) ...[
                const SizedBox(height: 8),
                AnimatedOpacity(
                  opacity: done ? 1 : 0,
                  duration: const Duration(milliseconds: 220),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Open streak',
                        style: TextStyle(
                          fontFamily: 'Manrope',
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: AppColors.streakGrey,
                          letterSpacing: 0.2,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: AppColors.streakGrey,
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Pill content — active-streak variant. Same speech-bubble tail
  // mechanism as the grey bubble, but a compact one-line pill:
  //
  //   ┌────────────────────────────┐
  //   │ 🔥 N-day streak         ›  │
  //   └───────────────▼────────────┘
  //                   flame
  // ---------------------------------------------------------------------------

  Widget _pillContent({required double tailX, required bool placeAbove}) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    // Pill uses theme surface + subtle outline so it reads as a chip,
    // not a heavy speech bubble. Slightly less contrast than the grey
    // bubble because the active pill is celebratory (kept in the
    // orange semantic palette) rather than corrective.
    final fill = isDark
        ? const Color(0xFF1E1E23)
        : const Color(0xFFFFFFFF);
    final outline = AppColors.streakActive;
    final textColor = AppColors.streakActive;

    final label = widget.activeStreakDays == 1
        ? '1-day streak'
        : '${widget.activeStreakDays}-day streak';

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onOpenSheet,
      child: CustomPaint(
        painter: _BubbleBackground(
          fill: fill,
          outline: outline,
          tailX: tailX,
          tailOnBottom: placeAbove,
          tailHeight: _tailHeight,
          tailWidth: _tailWidth,
          // Thinner stroke than the grey speech-bubble — pill is a
          // supporting affordance, not a corrective alert.
          strokeWidth: 1.5,
          cornerRadius: 14,
          // Pill hugs its content and sits centred over the flame
          // (Center + IntrinsicWidth wrapper in _PopupHost.build), so
          // the tail always points at the pill's own horizontal
          // centre — which equals the flame's centre. Override the
          // tailX arithmetic to `size.width / 2` at paint time.
          centerTail: true,
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            _pillHorizontalPadding,
            _pillVerticalPadding + (placeAbove ? 0 : _tailHeight),
            _pillHorizontalPadding,
            _pillVerticalPadding + (placeAbove ? _tailHeight : 0),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.local_fire_department,
                color: AppColors.streakActive,
                size: 18,
              ),
              const SizedBox(width: 8),
              // No Expanded — text sizes to its content so the pill
              // hugs "1-day streak" tightly. maxLines + ellipsis stay
              // as a safety net if a future label grows past the
              // _pillMaxWidth constraint (won't for the current
              // "N-day streak" copy, but future-proof).
              Text(
                label,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: TextStyle(
                  fontFamily: 'Manrope',
                  fontSize: 13.5,
                  height: 1.15,
                  fontWeight: FontWeight.w800,
                  color: textColor,
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.chevron_right,
                color: textColor,
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Paints the speech-bubble outline (rounded rect + triangular tail)
/// as a single unioned path so the stroke wraps the whole shape with
/// no seams where the tail meets the rectangle. Shared by both the
/// grey-bubble and active-pill variants; caller passes stroke width
/// and corner radius per variant.
class _BubbleBackground extends CustomPainter {
  final Color fill;
  final Color outline;
  final double tailX;
  final bool tailOnBottom;
  final double tailHeight;
  final double tailWidth;
  final double strokeWidth;
  final double cornerRadius;

  /// When true, the tail is drawn at the painter's own horizontal
  /// centre (`size.width / 2`) instead of the anchor-derived [tailX].
  /// Used by the active-pill variant, whose parent Center + IntrinsicWidth
  /// already guarantees the pill sits centred over the flame — so the
  /// tail's correct spot is always the pill's own middle. The bubble
  /// variant leaves this false and uses the pre-computed [tailX].
  final bool centerTail;

  _BubbleBackground({
    required this.fill,
    required this.outline,
    required this.tailX,
    required this.tailOnBottom,
    required this.tailHeight,
    required this.tailWidth,
    this.strokeWidth = 2,
    this.cornerRadius = 12,
    this.centerTail = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rectTop = tailOnBottom ? 0.0 : tailHeight;
    final rectBottom = tailOnBottom ? size.height - tailHeight : size.height;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTRB(0, rectTop, size.width, rectBottom),
      Radius.circular(cornerRadius),
    );

    final rectPath = Path()..addRRect(rrect);
    final tailPath = Path();
    // Clamp the tail's base so it never sticks out past the rounded
    // corners of the rectangle — otherwise the union stroke breaks.
    final minTailX = cornerRadius + tailWidth / 2 + 2;
    final maxTailX = size.width - cornerRadius - tailWidth / 2 - 2;
    final effectiveTailX = centerTail ? size.width / 2 : tailX;
    final safeTailX = effectiveTailX.clamp(minTailX, maxTailX);
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
        ..strokeWidth = strokeWidth
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
        old.tailWidth != tailWidth ||
        old.strokeWidth != strokeWidth ||
        old.cornerRadius != cornerRadius ||
        old.centerTail != centerTail;
  }
}
