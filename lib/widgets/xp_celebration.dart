import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/colors.dart';
import '../services/xp_celebration_bus.dart';

/// Wrap the app (or the authenticated shell) with this to auto-show a
/// celebration overlay whenever [XPCelebrationBus.instance] surfaces a
/// new `current` event. The overlay lives above [child] via a Stack
/// so nothing else in the widget tree has to know about celebrations —
/// code anywhere that calls `XPService.awardXP` gets a party for free.
///
/// Visual language matches the "Welcome to Pro" subscription card:
/// light near-white card, purple-gradient icon circle at top with a
/// gold star for XP, dark title / muted subtitle / dark pill CTA,
/// confetti shower (top + bottom emitters), and a subtle amoeba blob
/// in the top-left corner. Duplicated (rather than shared with
/// SubscriptionWelcomeGate) because the two celebrations have subtly
/// different durations, hit different frequencies, and one is bus-
/// driven while the other is prefs-gated — kept independent so future
/// tweaks to one don't drag the other along.
class XPCelebrationHost extends StatefulWidget {
  final Widget child;
  const XPCelebrationHost({super.key, required this.child});

  @override
  State<XPCelebrationHost> createState() => _XPCelebrationHostState();
}

class _XPCelebrationHostState extends State<XPCelebrationHost> {
  @override
  void initState() {
    super.initState();
    XPCelebrationBus.instance.current.addListener(_onEventChange);
  }

  @override
  void dispose() {
    XPCelebrationBus.instance.current.removeListener(_onEventChange);
    super.dispose();
  }

  void _onEventChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final event = XPCelebrationBus.instance.current.value;
    return Stack(
      children: [
        widget.child,
        if (event != null)
          _XPCelebrationOverlay(
            // Keyed on amount+reason+identity so back-to-back events
            // spin up distinct State instances and each replays its
            // in/hold/out animation cleanly.
            key: ValueKey(
                '${event.amount}-${event.reason}-${identityHashCode(event)}'),
            event: event,
            onDone: XPCelebrationBus.instance.completeCurrent,
          ),
      ],
    );
  }
}

class _XPCelebrationOverlay extends StatefulWidget {
  final XPAwardEvent event;
  final VoidCallback onDone;

  const _XPCelebrationOverlay({
    super.key,
    required this.event,
    required this.onDone,
  });

  @override
  State<_XPCelebrationOverlay> createState() =>
      _XPCelebrationOverlayState();
}

class _XPCelebrationOverlayState extends State<_XPCelebrationOverlay>
    with TickerProviderStateMixin {
  // XP fires frequently (any step-threshold, mission complete, battle
  // outcome) so the hold is deliberately shorter than the Welcome-to-
  // Pro card's ~5.5s — this needs to feel snappy, not blocking.
  static const _kEntry = Duration(milliseconds: 400);
  static const _kHold = Duration(milliseconds: 2400);
  static const _kExit = Duration(milliseconds: 350);

  late final AnimationController _entry;
  late final AnimationController _confetti;
  late final AnimationController _exit;
  late final List<_ConfettiPiece> _pieces;
  Timer? _autoDismiss;

  @override
  void initState() {
    super.initState();

    // Celebratory haptic burst — mediumImpact on entry, lightImpact
    // ~100 ms later so it reads as a "pop-tap" pairing with the
    // confetti burst. No-ops on devices without haptic hardware.
    HapticFeedback.mediumImpact();
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) HapticFeedback.lightImpact();
    });

    // 60 pieces total — 30 falling from above, 30 launching from
    // below. Deterministic per-event seed so hot reloads land the
    // pieces in the same spots (matters during dev iteration).
    final rnd = math.Random(widget.event.amount * 137 + 11);
    _pieces = [
      for (int i = 0; i < 30; i++) _ConfettiPiece.fromTop(rnd),
      for (int i = 0; i < 30; i++) _ConfettiPiece.fromBottom(rnd),
    ];

    _entry = AnimationController(vsync: this, duration: _kEntry)..forward();
    _confetti = AnimationController(
      vsync: this,
      duration: _kEntry + _kHold,
    )..forward();
    _exit = AnimationController(vsync: this, duration: _kExit);

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
    if (mounted) widget.onDone();
  }

  String get _title => '+${widget.event.amount} XP';

  String get _subtitle {
    final reason = widget.event.reason?.trim();
    if (reason == null || reason.isEmpty) {
      return 'Nice work — keep the streak going.';
    }
    return reason;
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

        return Positioned.fill(
          child: GestureDetector(
            onTap: _dismiss,
            behavior: HitTestBehavior.opaque,
            child: Opacity(
              opacity: aliveOpacity,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Dim backdrop
                  Container(
                    color: Colors.black.withValues(alpha: 0.62 * entryT),
                  ),
                  // Confetti — fills the whole overlay so top-emitter
                  // pieces fall past the card and bottom-emitter
                  // pieces rise past it.
                  IgnorePointer(
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: _ConfettiPainter(
                        pieces: _pieces,
                        progress: _confetti.value,
                      ),
                    ),
                  ),
                  // The card itself.
                  Transform.scale(
                    scale: scale,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: _XPCard(
                        title: _title,
                        subtitle: _subtitle,
                        onCta: _dismiss,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Light near-white card matching the Welcome-to-Pro layout. Gold-star
/// icon inside a purple-gradient circle at the top signals "XP" without
/// the loud gold typography we used to use.
class _XPCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onCta;

  const _XPCard({
    required this.title,
    required this.subtitle,
    required this.onCta,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.35),
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
              // Ambient amoeba blob in the top-left corner —
              // decorative only, IgnorePointer so it never eats
              // taps meant for the CTA below.
              Positioned(
                top: -30,
                left: -40,
                child: IgnorePointer(
                  child: SizedBox(
                    width: 200,
                    height: 160,
                    child: CustomPaint(
                      painter: _AmoebaBlobPainter(color: AppColors.primary),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 24, 28, 22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Purple-gradient circle with a gold star. Same
                    // physical geometry as the Welcome-to-Pro icon,
                    // just a different glyph.
                    Container(
                      width: 68,
                      height: 68,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            AppColors.primary,
                            const Color(0xFF7C3AED),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withValues(alpha: 0.45),
                            blurRadius: 20,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.star_rounded,
                        color: Color(0xFFFFD700),
                        size: 40,
                        shadows: [
                          Shadow(color: Color(0x66FFD700), blurRadius: 10),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFF161616),
                        fontFamily: 'Space Grotesk',
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.3,
                        // Overrides any OEM overlay (Samsung "AI
                        // Text" / Bixby lookup) that would otherwise
                        // draw dashed underlines on top of Flutter
                        // text.
                        decoration: TextDecoration.none,
                        decorationColor: Colors.transparent,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      subtitle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFF6B6B72),
                        fontFamily: 'Manrope',
                        fontSize: 13,
                        height: 1.5,
                        decoration: TextDecoration.none,
                        decorationColor: Colors.transparent,
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
                          padding:
                              const EdgeInsets.symmetric(vertical: 14),
                          textStyle: const TextStyle(
                            fontFamily: 'Manrope',
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.3,
                          ),
                        ),
                        child: const Text('Nice!'),
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
}

// ---------------------------------------------------------------------------
// Confetti + amoeba — kept private to this file so future tweaks to
// XP visuals don't require coordinating with SubscriptionWelcomeGate.
// (SubscriptionWelcomeGate has its own copies for the same reason —
// tolerate the duplication in exchange for zero cross-coupling.)
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
    Color(0xFFEF4444), // red
    Color(0xFFF97316), // orange
    Color(0xFFFACC15), // yellow
    Color(0xFF22C55E), // green
    Color(0xFF3B82F6), // blue
    Color(0xFFA855F7), // violet
    Color(0xFFEC4899), // pink
  ];

  factory _ConfettiPiece.fromTop(math.Random rnd) {
    return _ConfettiPiece(
      xFrac: rnd.nextDouble(),
      yFrac: -0.05 - rnd.nextDouble() * 0.15,
      vx: (rnd.nextDouble() - 0.5) * 0.4,
      vy: 0.05 + rnd.nextDouble() * 0.15,
      gravity: 0.3,
      color: _palette[rnd.nextInt(_palette.length)],
      width: 6 + rnd.nextDouble() * 6,
      height: 10 + rnd.nextDouble() * 10,
      rotationSpeed: (rnd.nextDouble() - 0.5) * 6,
      startRotation: rnd.nextDouble() * math.pi * 2,
    );
  }

  factory _ConfettiPiece.fromBottom(math.Random rnd) {
    return _ConfettiPiece(
      xFrac: rnd.nextDouble(),
      yFrac: 1.05 + rnd.nextDouble() * 0.05,
      vx: (rnd.nextDouble() - 0.5) * 0.5,
      vy: -1.3 - rnd.nextDouble() * 0.5,
      gravity: 0.95,
      color: _palette[rnd.nextInt(_palette.length)],
      width: 6 + rnd.nextDouble() * 6,
      height: 10 + rnd.nextDouble() * 10,
      rotationSpeed: (rnd.nextDouble() - 0.5) * 8,
      startRotation: rnd.nextDouble() * math.pi * 2,
    );
  }
}

class _ConfettiPainter extends CustomPainter {
  final List<_ConfettiPiece> pieces;
  final double progress; // 0..1 across the full entry+hold duration
  _ConfettiPainter({required this.pieces, required this.progress});

  // Match the total animation window ((_kEntry + _kHold) = 2.8 s) so
  // the projectile math produces realistic travel distances.
  static const double _durationSec = 2.8;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.clamp(0.0, 1.0) * _durationSec;
    final paint = Paint()..isAntiAlias = true;

    for (final p in pieces) {
      final xFrac = p.xFrac + p.vx * t;
      final yFrac = p.yFrac + p.vy * t + 0.5 * p.gravity * t * t;

      if (yFrac < -0.2 || yFrac > 1.2 || xFrac < -0.1 || xFrac > 1.1) {
        continue;
      }

      final normalized = progress.clamp(0.0, 1.0);
      final fade = normalized > 0.85
          ? (1.0 - (normalized - 0.85) / 0.15).clamp(0.0, 1.0)
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
