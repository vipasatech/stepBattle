import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/colors.dart';

/// One-shot celebration overlay shown after a successful Razorpay XP
/// top-up. Visual language mirrors the subscription "Welcome to Pro"
/// overlay (dim backdrop + top+bottom confetti emitters + centered
/// light card with a purple gradient icon).
///
/// Show with [showXpPurchaseCelebration]:
///
///   await showXpPurchaseCelebration(context, xpAmount: 500);
///
/// The future completes when the user taps to dismiss or the auto-
/// dismiss timer fires (~4.5s), whichever comes first.
Future<void> showXpPurchaseCelebration(
  BuildContext context, {
  required int xpAmount,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierDismissible: false,
      barrierColor: Colors.transparent,
      transitionDuration: Duration.zero,
      pageBuilder: (_, __, ___) => _XpCelebrationOverlay(xpAmount: xpAmount),
    ),
  );
}

class _XpCelebrationOverlay extends StatefulWidget {
  final int xpAmount;
  const _XpCelebrationOverlay({required this.xpAmount});

  @override
  State<_XpCelebrationOverlay> createState() => _XpCelebrationOverlayState();
}

class _XpCelebrationOverlayState extends State<_XpCelebrationOverlay>
    with TickerProviderStateMixin {
  static const _kEntry = Duration(milliseconds: 380);
  static const _kHold  = Duration(milliseconds: 4200);
  static const _kExit  = Duration(milliseconds: 320);

  late final AnimationController _entry;
  late final AnimationController _confetti;
  late final AnimationController _exit;
  late final List<_ConfettiPiece> _pieces;
  Timer? _autoDismiss;

  @override
  void initState() {
    super.initState();
    HapticFeedback.mediumImpact();
    Future.delayed(const Duration(milliseconds: 90), () {
      if (mounted) HapticFeedback.lightImpact();
    });

    final rnd = math.Random(widget.xpAmount * 31 + 7);
    _pieces = [
      for (int i = 0; i < 45; i++) _ConfettiPiece.fromTop(rnd),
      for (int i = 0; i < 45; i++) _ConfettiPiece.fromBottom(rnd),
    ];

    _entry    = AnimationController(vsync: this, duration: _kEntry)..forward();
    _confetti = AnimationController(vsync: this, duration: _kEntry + _kHold)
      ..forward();
    _exit     = AnimationController(vsync: this, duration: _kExit);

    _autoDismiss = Timer(_kEntry + _kHold, _dismiss);
  }

  @override
  void dispose() {
    _autoDismiss?.cancel();
    _entry.dispose();
    _confetti.dispose();
    _exit.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    _autoDismiss?.cancel();
    if (!mounted) return;
    if (_exit.status == AnimationStatus.forward ||
        _exit.status == AnimationStatus.completed) {
      return;
    }
    await _exit.forward();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_entry, _confetti, _exit]),
      builder: (_, __) {
        final entryT =
            Curves.easeOut.transform(_entry.value.clamp(0.0, 1.0));
        final aliveOpacity = (1.0 - _exit.value).clamp(0.0, 1.0);
        final scaleT =
            Curves.elasticOut.transform(_entry.value.clamp(0.0, 1.0));
        final scale = 0.6 + scaleT * 0.4;

        return GestureDetector(
          onTap: _dismiss,
          behavior: HitTestBehavior.opaque,
          child: Opacity(
            opacity: aliveOpacity,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  color: Colors.black.withValues(alpha: 0.62 * entryT),
                ),
                IgnorePointer(
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: _ConfettiPainter(
                      pieces: _pieces,
                      progress: _confetti.value,
                    ),
                  ),
                ),
                Transform.scale(
                  scale: scale,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: _XpCard(
                      xpAmount: widget.xpAmount,
                      onCta: _dismiss,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _XpCard extends StatelessWidget {
  final int xpAmount;
  final VoidCallback onCta;
  const _XpCard({required this.xpAmount, required this.onCta});

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.primary;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.35),
            blurRadius: 60,
            spreadRadius: 2,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Container(
          color: const Color(0xFFF7F5FA),
          child: Stack(
            children: [
              // Ambient purple amoeba blob in the top-left corner —
              // matches the subscription welcome card's visual language
              // so the two celebration surfaces feel like one system.
              Positioned(
                top: -30,
                left: -40,
                child: IgnorePointer(
                  child: SizedBox(
                    width: 200,
                    height: 160,
                    child: CustomPaint(
                      painter: _AmoebaBlobPainter(color: accent),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 28, 28, 22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [accent, const Color(0xFF7C3AED)],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.45),
                        blurRadius: 22,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.bolt,
                    color: Colors.white,
                    size: 44,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  '+${_fmt(xpAmount)} XP',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF161616),
                    fontFamily: 'Space Grotesk',
                    fontSize: 34,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.4,
                    decoration: TextDecoration.none,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Added to your balance',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF6B6B72),
                    fontFamily: 'Manrope',
                    fontSize: 13.5,
                    height: 1.4,
                    decoration: TextDecoration.none,
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: onCta,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF141414),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      textStyle: const TextStyle(
                        fontFamily: 'Manrope',
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.3,
                      ),
                    ),
                    child: const Text('Great!'),
                  ),
                ),
              ],
            ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _fmt(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}

// ---------------------------------------------------------------------------
// Confetti (same physics as subscription_welcome_gate — duplicated for
// module isolation; if this pattern lands in a third surface, promote it
// to a shared widget).
// ---------------------------------------------------------------------------

class _ConfettiPiece {
  final double xFrac;
  final double yFrac;
  final double vx;
  final double vy;
  final double gravity;
  final Color color;
  final double width;
  final double height;
  final double rotationSpeed;
  final double startRotation;

  const _ConfettiPiece({
    required this.xFrac,
    required this.yFrac,
    required this.vx,
    required this.vy,
    required this.gravity,
    required this.color,
    required this.width,
    required this.height,
    required this.rotationSpeed,
    required this.startRotation,
  });

  static const _palette = <Color>[
    Color(0xFFEF4444),
    Color(0xFFF97316),
    Color(0xFFFACC15),
    Color(0xFF22C55E),
    Color(0xFF3B82F6),
    Color(0xFFA855F7),
    Color(0xFFEC4899),
  ];

  factory _ConfettiPiece.fromTop(math.Random rnd) => _ConfettiPiece(
        xFrac: rnd.nextDouble(),
        yFrac: -0.05 - rnd.nextDouble() * 0.15,
        vx: (rnd.nextDouble() - 0.5) * 0.4,
        vy: 0.05 + rnd.nextDouble() * 0.15,
        gravity: 0.28,
        color: _palette[rnd.nextInt(_palette.length)],
        width: 6 + rnd.nextDouble() * 6,
        height: 10 + rnd.nextDouble() * 10,
        rotationSpeed: (rnd.nextDouble() - 0.5) * 6,
        startRotation: rnd.nextDouble() * math.pi * 2,
      );

  factory _ConfettiPiece.fromBottom(math.Random rnd) => _ConfettiPiece(
        xFrac: rnd.nextDouble(),
        yFrac: 1.05 + rnd.nextDouble() * 0.05,
        vx: (rnd.nextDouble() - 0.5) * 0.5,
        vy: -1.3 - rnd.nextDouble() * 0.5,
        gravity: 0.9,
        color: _palette[rnd.nextInt(_palette.length)],
        width: 6 + rnd.nextDouble() * 6,
        height: 10 + rnd.nextDouble() * 10,
        rotationSpeed: (rnd.nextDouble() - 0.5) * 8,
        startRotation: rnd.nextDouble() * math.pi * 2,
      );
}

class _ConfettiPainter extends CustomPainter {
  final List<_ConfettiPiece> pieces;
  final double progress;
  _ConfettiPainter({required this.pieces, required this.progress});

  static const double _durationSec = 4.5;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.clamp(0.0, 1.0) * _durationSec;
    final paint = Paint()..isAntiAlias = true;

    for (final p in pieces) {
      final xFrac = p.xFrac + p.vx * t;
      final yFrac = p.yFrac + p.vy * t + 0.5 * p.gravity * t * t;
      if (yFrac < -0.2 || yFrac > 1.2 || xFrac < -0.1 || xFrac > 1.1) continue;

      final normalized = progress.clamp(0.0, 1.0);
      final fade = normalized > 0.88
          ? (1.0 - (normalized - 0.88) / 0.12).clamp(0.0, 1.0)
          : 1.0;

      final cx = xFrac * size.width;
      final cy = yFrac * size.height;
      final rot = p.startRotation + p.rotationSpeed * t;

      paint.color = p.color.withValues(alpha: fade);
      canvas.save();
      canvas.translate(cx, cy);
      canvas.rotate(rot);
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset.zero,
          width: p.width,
          height: p.height,
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter old) =>
      old.progress != progress;
}

/// Ambient purple amoeba blob painter — soft asymmetric radial gradient
/// in the top-left of the card. Same visual as the subscription welcome
/// card so both celebration surfaces read as one system.
class _AmoebaBlobPainter extends CustomPainter {
  final Color color;
  _AmoebaBlobPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w * 0.10, 0)
      ..cubicTo(
        w * 0.45, h * 0.02,
        w * 0.75, h * 0.05,
        w * 0.95, h * 0.30,
      )
      ..cubicTo(
        w * 1.08, h * 0.55,
        w * 0.85, h * 0.80,
        w * 0.60, h * 0.92,
      )
      ..cubicTo(
        w * 0.35, h * 1.02,
        w * 0.10, h * 0.95,
        w * 0.02, h * 0.72,
      )
      ..cubicTo(
        w * -0.08, h * 0.50,
        w * -0.05, h * 0.20,
        w * 0.10, 0,
      )
      ..close();

    final paint = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.4, -0.4),
        radius: 1.1,
        colors: [
          color.withValues(alpha: 0.30),
          color.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, w, h));

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _AmoebaBlobPainter old) => old.color != color;
}
