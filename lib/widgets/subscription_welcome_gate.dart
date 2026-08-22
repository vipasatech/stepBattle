import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/colors.dart';
import '../models/subscription_model.dart';
import '../providers/subscription_provider.dart';

/// Watches the user's subscription tier and pops a one-time
/// "Welcome to Pro / Family" celebration overlay when they upgrade
/// from Free to a paid tier (or from Pro to Family).
///
/// Persistence — a `SharedPreferences` entry under the key
/// `subscription_ack_tier` stores the last-celebrated tier. The
/// overlay only fires when the CURRENT paid tier differs from the
/// stored one. Downgrades and repeat-app-opens don't re-fire it.
///
/// Trigger points:
///   * on first frame after the widget mounts (covers "user came
///     back to the app AFTER the payment settled while backgrounded")
///   * whenever subscriptionProvider emits a new value (covers
///     "app is already open and the webhook just landed")
class SubscriptionWelcomeGate extends ConsumerStatefulWidget {
  final Widget child;
  const SubscriptionWelcomeGate({super.key, required this.child});

  @override
  ConsumerState<SubscriptionWelcomeGate> createState() =>
      _SubscriptionWelcomeGateState();
}

class _SubscriptionWelcomeGateState
    extends ConsumerState<SubscriptionWelcomeGate> {
  static const _prefsKey = 'subscription_ack_tier';
  SubscriptionTier? _showing;
  bool _initialCheckDone = false;

  @override
  Widget build(BuildContext context) {
    ref.listen<SubscriptionState>(subscriptionProvider, (prev, next) {
      if (!_initialCheckDone) return;
      // Only treat this as a real downgrade — and clear the ack —
      // when we saw the user on a paid tier last emit and now they're
      // on free. That's the ONLY moment where clearing is safe. The
      // initial-load path never clears, because subscriptionProvider
      // emits a transient `free` before Supabase resolves the true
      // tier, and clearing then would make the popup re-fire on
      // every cold launch.
      final wasPaid = prev != null && prev.tier != SubscriptionTier.basic;
      _maybeCelebrate(next.tier, isRealDowngrade: wasPaid);
    });

    if (!_initialCheckDone) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _initialCheckDone = true;
        // Initial mount — never clear (see above).
        _maybeCelebrate(
          ref.read(subscriptionProvider).tier,
          isRealDowngrade: false,
        );
      });
    }

    return Stack(
      children: [
        widget.child,
        if (_showing != null)
          _CelebrationOverlay(
            key: ValueKey(_showing!.wire),
            tier: _showing!,
            onDone: () {
              if (mounted) setState(() => _showing = null);
            },
          ),
      ],
    );
  }

  Future<void> _maybeCelebrate(
    SubscriptionTier tier, {
    required bool isRealDowngrade,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    if (tier == SubscriptionTier.basic) {
      // Clear ack ONLY on a real live downgrade so the sequence
      // Pro → Free → Pro fires the popup on the re-upgrade. Cold
      // launches that transiently read Free before Supabase resolves
      // do NOT clear — otherwise the popup re-fires every launch.
      if (isRealDowngrade) await prefs.remove(_prefsKey);
      return;
    }

    final acked = prefs.getString(_prefsKey);
    if (acked == tier.wire) return; // already celebrated this tier
    await prefs.setString(_prefsKey, tier.wire);
    if (!mounted) return;
    setState(() => _showing = tier);
  }
}

/// Full-screen overlay: dimmed backdrop, confetti shower from top +
/// bottom emitters, centered light card with a gradient crown, title,
/// subtitle, and dark "Start Exploring" pill. Dismisses on any tap
/// (background or button).
class _CelebrationOverlay extends StatefulWidget {
  final SubscriptionTier tier;
  final VoidCallback onDone;
  const _CelebrationOverlay({
    super.key,
    required this.tier,
    required this.onDone,
  });

  @override
  State<_CelebrationOverlay> createState() => _CelebrationOverlayState();
}

class _CelebrationOverlayState extends State<_CelebrationOverlay>
    with TickerProviderStateMixin {
  static const _kEntry = Duration(milliseconds: 400);
  static const _kHold = Duration(milliseconds: 5500);
  static const _kExit = Duration(milliseconds: 350);

  late final AnimationController _entry;
  late final AnimationController _confetti;
  late final AnimationController _exit;
  late final List<_ConfettiPiece> _pieces;
  Timer? _autoDismiss;

  @override
  void initState() {
    super.initState();

    // Celebratory haptic burst — medium impact right on appear,
    // then a lighter tap ~100 ms later so it feels like the
    // confetti actually "popped" rather than a single vibration.
    // Non-blocking; ignored on devices without haptic hardware.
    HapticFeedback.mediumImpact();
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) HapticFeedback.lightImpact();
    });

    // 90 pieces total — 45 falling from above, 45 launching from
    // below. Deterministic per-tier seed so the animation is stable
    // frame-to-frame (matters for hot reloads during dev).
    final rnd = math.Random(widget.tier.index * 137 + 11);
    _pieces = [
      for (int i = 0; i < 45; i++) _ConfettiPiece.fromTop(rnd),
      for (int i = 0; i < 45; i++) _ConfettiPiece.fromBottom(rnd),
    ];

    _entry = AnimationController(vsync: this, duration: _kEntry)..forward();
    // Confetti runs the full entry+hold window so it keeps drifting
    // behind the card even after the card has settled.
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

  String get _title => widget.tier == SubscriptionTier.max
      ? 'Welcome to Family!'
      : 'Welcome to Pro!';

  String get _subtitle => widget.tier == SubscriptionTier.max
      ? 'Full access unlocked — for up to 4 accounts. Every seat gets '
          'unlimited public battles, 60 private joins, and a 1000 XP '
          'streak bonus.'
      : 'Full access to unlimited battles, private joins, extended '
          'history, and a 500 XP monthly streak bonus.';

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
                  // Confetti — fills the whole overlay so pieces from
                  // top emitter fall past the card and pieces from
                  // bottom emitter rise past it.
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
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: _WelcomeCard(
                        tier: widget.tier,
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

/// The card itself — light near-white surface, purple-gradient icon
/// circle at the top, dark title, muted subtitle, dark pill CTA.
/// Modeled on the reference "Welcome to Pro!" card style.
class _WelcomeCard extends StatelessWidget {
  final SubscriptionTier tier;
  final String title;
  final String subtitle;
  final VoidCallback onCta;

  const _WelcomeCard({
    required this.tier,
    required this.title,
    required this.subtitle,
    required this.onCta,
  });

  @override
  Widget build(BuildContext context) {
    final accent = tier == SubscriptionTier.max
        ? AppColors.tertiary
        : AppColors.primary;

    // Outer container carries the shadow. Inner ClipRRect clips
    // the decorative amoeba to the card's rounded corners without
    // clipping the shadow.
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
              // Ambient amoeba blob in the top-left corner.
              // IgnorePointer so it never eats taps meant for the
              // CTA below.
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
                padding: const EdgeInsets.fromLTRB(28, 24, 28, 22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 68,
                      height: 68,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            accent,
                            tier == SubscriptionTier.max
                                ? AppColors.tertiary.withValues(alpha: 0.75)
                                : const Color(0xFF7C3AED),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: accent.withValues(alpha: 0.45),
                            blurRadius: 20,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                      // Material's verified-badge glyph (rosette +
                      // checkmark). Rendered white on the accent
                      // gradient. Legal, transparent, zero-asset.
                      child: const Icon(
                        Icons.verified,
                        color: Colors.white,
                        size: 40,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFF161616),
                        fontFamily: 'Space Grotesk',
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.3,
                        // Overrides any OEM overlay (Samsung "AI
                        // Text" / Bixby lookup, etc.) that draws
                        // dashed underlines on top of Flutter text.
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
                        child: const Text('Start Exploring'),
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

/// Paints a soft asymmetric blob in the top-left corner of the
/// welcome card. Four cubic Bezier segments describe an organic
/// closed shape that reads as "amoeba", filled with a radial
/// gradient anchored near the top-left so intensity falls off
/// toward the card's centre. Low alpha keeps the blob ambient —
/// visible but never dominant.
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

// ---------------------------------------------------------------------------
// Confetti physics + painter
// ---------------------------------------------------------------------------

/// A single confetti rectangle. Each piece is a rigid body driven by
/// simple projectile motion — horizontal drift is added on top of the
/// vertical trajectory so pieces don't fall in a boring straight line.
class _ConfettiPiece {
  /// Screen-space start position expressed as fractions of the
  /// viewport (so it stays correct across phone sizes). x ∈ [0, 1],
  /// y is 0 at the top of the viewport and 1 at the bottom.
  final double xFrac;
  final double yFrac;

  /// Initial velocity in fractions-of-viewport per second. Positive
  /// y = downward. Top emitters get vy = 0..0.2 (drift down slowly),
  /// bottom emitters get vy = -1.2..-1.8 (fly up fast).
  final double vx;
  final double vy;

  /// Vertical gravity in fractions-of-viewport per second². Same
  /// for every piece so the "shower" reads as a single system.
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

  /// Piece falling from above the screen — starts a bit above y=0
  /// with a small downward push; gravity carries the rest.
  factory _ConfettiPiece.fromTop(math.Random rnd) {
    return _ConfettiPiece(
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
  }

  /// Piece launching from below the screen — starts just off the
  /// bottom, initial velocity is upward, gravity brings it back down.
  factory _ConfettiPiece.fromBottom(math.Random rnd) {
    return _ConfettiPiece(
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
}

class _ConfettiPainter extends CustomPainter {
  final List<_ConfettiPiece> pieces;
  final double progress; // 0..1 across the full entry+hold duration
  _ConfettiPainter({required this.pieces, required this.progress});

  // `progress` is 0..1 across ~5.9s of animation. Multiply to get a
  // realistic "seconds" value for the projectile math — otherwise
  // the pieces barely move.
  static const double _durationSec = 5.9;

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.clamp(0.0, 1.0) * _durationSec;
    final paint = Paint()..isAntiAlias = true;

    for (final p in pieces) {
      // Simple projectile motion: pos = start + v*t + 0.5*g*t²
      final xFrac = p.xFrac + p.vx * t;
      final yFrac = p.yFrac + p.vy * t + 0.5 * p.gravity * t * t;

      // Off-screen pieces don't need to be drawn.
      if (yFrac < -0.2 || yFrac > 1.2 || xFrac < -0.1 || xFrac > 1.1) {
        continue;
      }

      // Late-fade: pieces dim to zero over the final 12% of the
      // window so the shower doesn't cut off abruptly on dismiss.
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
