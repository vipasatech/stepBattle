import 'package:flutter/material.dart';

/// Which side the notch (small triangle tail) sits on. Points AT the
/// target — so if the card sits BELOW the target, the notch is on TOP
/// of the card, pointing up.
enum TooltipNotchSide { top, bottom, none }

/// Tour dialog card — v7 (2026-09-04, adds notch + interactive fix).
///
/// Adds a small triangle notch pointing at the target so the card
/// visually "belongs to" the highlighted widget. Notch position is
/// computed by the overlay based on card-vs-target geometry.
class TourTooltip extends StatelessWidget {
  final String title;
  final String description;
  final int stepNumber;
  final int totalSteps;

  /// Top-right X — same effect as Skip (dismisses tour + marks done).
  final VoidCallback onClose;

  /// Bottom-left secondary — hidden on step 1 (no back to go to).
  final VoidCallback? onBack;

  /// Bottom-right primary — advances or finishes.
  final VoidCallback onNext;

  /// Non-null when this step is offering a permission: the primary
  /// button becomes "Allow" and runs this instead of advancing, and a
  /// "Not now" appears beside it wired to [onNext]. Goes null once the
  /// capability is granted, so the card reverts to a plain Next.
  final VoidCallback? onAllow;

  /// True while [onAllow] is in flight — the OS prompt is on screen, or
  /// we are re-probing after it closed.
  final bool allowBusy;

  /// True on the last step → primary label becomes "Finish".
  final bool isLast;

  /// Which side to draw the notch on (top / bottom / none). Overlay
  /// computes this based on whether the card sits above or below the
  /// target.
  final TooltipNotchSide notchSide;

  /// Horizontal position of the notch as a fraction of card width
  /// [0..1]. 0.5 = centred. Overlay computes this so the notch tip
  /// aligns with the target's horizontal centre.
  final double notchFraction;

  const TourTooltip({
    super.key,
    required this.title,
    required this.description,
    required this.stepNumber,
    required this.totalSteps,
    required this.onClose,
    required this.onNext,
    this.onAllow,
    this.allowBusy = false,
    required this.isLast,
    this.onBack,
    this.notchSide = TooltipNotchSide.none,
    this.notchFraction = 0.5,
  });

  @override
  Widget build(BuildContext context) {
    // Purple gradient — LIGHT violet at top-left, deep violet at
    // bottom-right so the tonal shift is visibly a gradient rather
    // than a flat purple field. Two very different lightness values
    // (light lavender → deep violet) for max visible gradation.
    const lightPurple = Color(0xFFB185F5); // light lavender
    const midPurple = Color(0xFF7C3AED);  // primary brand
    const darkPurple = Color(0xFF5B21B6); // deeper violet at end
    const gradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [lightPurple, midPurple, darkPurple],
      stops: [0.0, 0.55, 1.0],
    );
    // Notch colour tracks the side it attaches to so it reads as a
    // natural extension of the card's edge. Top notch = card is
    // below target = notch is at the card's top-left corner region,
    // where the gradient starts LIGHT. Bottom notch = card is above
    // target = notch is at the card's bottom-right, where the
    // gradient ends DARK.
    final notchColor =
        notchSide == TooltipNotchSide.top ? lightPurple : darkPurple;
    const textColor = Color(0xFFFFFFFF);
    final mutedText = textColor.withValues(alpha: 0.82);
    final borderColor = textColor.withValues(alpha: 0.22);

    return CustomPaint(
      // Notch painter renders on top of the card border, sticking out
      // toward the target. Drawn AFTER the card body so it visually
      // extends the card's shape rather than being cut off.
      foregroundPainter: _NotchPainter(
        side: notchSide,
        fraction: notchFraction,
        color: notchColor,
      ),
      // Material ancestor so the InkResponse on the X close (and any
      // future ripple-based widgets inside the card) has the ink
      // surface it needs. The overlay's outer tree deliberately has
      // NO Material so its Stack doesn't participate in hit testing —
      // Material is scoped to just this card.
      child: Material(
        type: MaterialType.transparency,
        child: Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 14),
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Row 1: title + close X ────────────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 4, right: 4),
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.1,
                      height: 1.2,
                    ),
                  ),
                ),
              ),
              InkResponse(
                onTap: onClose,
                radius: 18,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    Icons.close_rounded,
                    color: mutedText,
                    size: 18,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // ── Row 2: description ────────────────────────────────────
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              description,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: mutedText,
                fontSize: 13,
                fontWeight: FontWeight.w400,
                height: 1.35,
              ),
            ),
          ),
          const SizedBox(height: 10),
          // ── Row 3: step counter + Back/Next ───────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                '$stepNumber / $totalSteps',
                style: TextStyle(
                  color: textColor.withValues(alpha: 0.45),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
              const Spacer(),
              if (onBack != null) ...[
                _CardButton(
                  label: 'Back',
                  onPressed: onBack!,
                  filled: false,
                  textColor: textColor,
                  borderColor: borderColor,
                ),
                const SizedBox(width: 8),
              ],
              if (onAllow != null) ...[
                _CardButton(
                  label: 'Not now',
                  onPressed: onNext,
                  filled: false,
                  textColor: textColor,
                  borderColor: borderColor,
                ),
                const SizedBox(width: 8),
              ],
              _CardButton(
                label: onAllow != null
                    ? (allowBusy ? 'Waiting…' : 'Allow')
                    : (isLast ? 'Finish' : 'Next'),
                onPressed: allowBusy ? () {} : (onAllow ?? onNext),
                filled: true,
                // Solid white pill with deep-violet text — high
                // contrast against the purple gradient card body.
                textColor: darkPurple,
                borderColor: textColor,
                fillColor: textColor,
              ),
            ],
          ),
        ],
      ),
      ),
      ),
    );
  }
}

/// Paints a small triangle notch on the specified side of the card,
/// horizontally at [fraction] of the card's width. Fill matches the
/// card background so it reads as an extension of the card.
class _NotchPainter extends CustomPainter {
  final TooltipNotchSide side;
  final double fraction;
  final Color color;

  const _NotchPainter({
    required this.side,
    required this.fraction,
    required this.color,
  });

  static const double _notchHalfWidth = 9;
  static const double _notchHeight = 8;

  @override
  void paint(Canvas canvas, Size size) {
    if (side == TooltipNotchSide.none) return;
    final f = fraction.clamp(0.06, 0.94);
    final centerX = size.width * f;
    final path = Path();
    if (side == TooltipNotchSide.top) {
      // Notch sits at the top edge, pointing UP.
      path.moveTo(centerX - _notchHalfWidth, 0);
      path.lineTo(centerX, -_notchHeight);
      path.lineTo(centerX + _notchHalfWidth, 0);
      path.close();
    } else {
      // Notch sits at the bottom edge, pointing DOWN.
      path.moveTo(centerX - _notchHalfWidth, size.height);
      path.lineTo(centerX, size.height + _notchHeight);
      path.lineTo(centerX + _notchHalfWidth, size.height);
      path.close();
    }
    // Soft drop shadow so the notch reads as extending the card's
    // depth (the card has its own shadow; this stays consistent).
    canvas.drawShadow(path, Colors.black.withValues(alpha: 0.35), 4, false);
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _NotchPainter oldDelegate) =>
      oldDelegate.side != side ||
      oldDelegate.fraction != fraction ||
      oldDelegate.color != color;
}

/// Small pill button used inside the tour card. Outlined or filled.
class _CardButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final bool filled;
  final Color textColor;
  final Color borderColor;
  final Color? fillColor;

  const _CardButton({
    required this.label,
    required this.onPressed,
    required this.filled,
    required this.textColor,
    required this.borderColor,
    this.fillColor,
  });

  @override
  Widget build(BuildContext context) {
    if (filled) {
      return FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: fillColor,
          foregroundColor: textColor,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          minimumSize: const Size(0, 36),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
          elevation: 0,
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      );
    }
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: textColor,
        side: BorderSide(color: borderColor, width: 1),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        minimumSize: const Size(0, 36),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
