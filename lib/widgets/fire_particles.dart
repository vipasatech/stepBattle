import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Ambient fire-particles field rendered BEHIND a target widget (the
/// streak flame on Home). Small glowing dots rise from the base of the
/// stage, drift upward with a touch of horizontal jitter, and fade to
/// zero opacity as they climb — creating a subtle "embers rising off a
/// flame" impression without a heavy VFX system.
///
/// Design goals:
///   • Subtle. Never competes with the flame itself for attention.
///   • Colour-linked. Consumers pass in [colour] so the particles
///     match `AppColors.streakActive` (orange) OR `streakGrey` (in
///     recovery) without hard-coding either.
///   • Cheap. One [Ticker], one [CustomPainter], one paint per frame.
///     No per-particle widgets — those would allocate 30+ Elements
///     every second and dirty the whole streak strip.
///
/// Usage:
///   Stack(
///     alignment: Alignment.center,
///     children: [
///       Positioned.fill(child: FireParticles(colour: AppColors.streakActive)),
///       Icon(Icons.local_fire_department, ...),
///     ],
///   )
///
/// The widget is layout-agnostic — it paints across the full extent of
/// its parent. Pair with `Positioned.fill` inside a stack so it sits
/// behind the icon and both share bounds.
class FireParticles extends StatefulWidget {
  /// Base colour of every particle. Alpha is applied per-particle
  /// based on its remaining life.
  final Color colour;

  /// Number of concurrent particles. Higher = denser field, but each
  /// costs one draw call per frame. 12–20 is the sweet spot for a
  /// small anchor icon; the default is calibrated for the streak
  /// flame on the Home strip (~64dp square).
  final int particleCount;

  /// Enable / disable the animation without unmounting. When false
  /// the ticker stops and the canvas paints nothing — used by
  /// callers that want to freeze the effect on reduced-motion or
  /// when the icon is off-screen.
  final bool enabled;

  const FireParticles({
    super.key,
    required this.colour,
    this.particleCount = 14,
    this.enabled = true,
  });

  @override
  State<FireParticles> createState() => _FireParticlesState();
}

class _FireParticlesState extends State<FireParticles>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _rng = math.Random();
  late final List<_Particle> _particles;
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    _particles = List.generate(widget.particleCount, (_) => _spawn(seeded: true));
    _ticker = createTicker(_onTick);
    if (widget.enabled) _ticker.start();
  }

  @override
  void didUpdateWidget(covariant FireParticles old) {
    super.didUpdateWidget(old);
    if (widget.enabled != old.enabled) {
      if (widget.enabled) {
        _last = Duration.zero;
        _ticker.start();
      } else {
        _ticker.stop();
      }
    }
    // If the colour changed (streak flipped from active to recovery
    // or back), the existing particles adopt the new hue on the next
    // frame — the painter reads widget.colour directly.
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  /// Spawn a fresh particle. `seeded: true` scatters lifetime so the
  /// initial field isn't all synchronised at t=0.
  ///
  /// Coordinate system convention:
  ///   • x = 0..1 horizontal across the paint box
  ///   • y = 0..1 vertical, 0 = top, 1 = bottom
  ///   • Particles spawn near the ICON'S TOP EDGE (y ≈ 0.55 given the
  ///     layout parents the widget so the icon occupies the LOWER
  ///     portion of the paint box) and rise upward to y = 0.
  ///
  /// Previously particles started at y = 1.0 (bottom of the paint
  /// box) and rose past the icon. Tester feedback: it read as embers
  /// coming from BELOW the flame, not from the flame. This version
  /// spawns emerging FROM the icon itself so the effect reads as
  /// "sparks going into the air."
  _Particle _spawn({bool seeded = false}) {
    // Horizontal position: centred with a Gaussian-ish spread so most
    // particles rise near the icon's midline, a few off to the sides.
    final xJitter = (_rng.nextDouble() - 0.5) * 0.4;
    // Upward speed: 0.35–0.6 (fraction of parent height per second).
    final speed = 0.35 + _rng.nextDouble() * 0.25;
    // Spawn just below the icon's top edge (where the flame's "tip"
    // is). Paint area is 88dp: 24dp of "sky" above the 64dp SizedBox
    // (via Positioned top:-24 in the caller). Icon centered in the
    // 64dp box means icon-top-edge sits at y = 24 + 8 = 32 within
    // the 88dp paint area = fraction 0.36. Particles spawn at 0.4
    // (a hair below icon top, so they emerge FROM the flame's crown
    // and rise into the 24dp of sky above).
    final spawnY = 0.4 + (_rng.nextDouble() * 0.06);
    return _Particle(
      x: 0.5 + xJitter,
      y: spawnY,
      speed: speed,
      size: 1.4 + _rng.nextDouble() * 2.2,
      driftAmplitude: 0.02 + _rng.nextDouble() * 0.06,
      driftPhase: _rng.nextDouble() * math.pi * 2,
      life: seeded ? _rng.nextDouble() : 1.0,
    );
  }

  void _onTick(Duration elapsed) {
    final delta = _last == Duration.zero
        ? const Duration(milliseconds: 16)
        : elapsed - _last;
    _last = elapsed;
    final dt = delta.inMicroseconds / 1e6;

    for (var i = 0; i < _particles.length; i++) {
      final p = _particles[i];
      p.y -= p.speed * dt;
      p.life -= dt * 0.9;   // ~1.1s per full life at speed=0.5
      if (p.life <= 0 || p.y <= 0) {
        _particles[i] = _spawn();
      }
    }
    // Only mark for paint — layout doesn't change, so a single
    // setState → CustomPaint repaint per frame is cheap.
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _ParticlePainter(
          particles: _particles,
          colour: widget.colour,
        ),
      ),
    );
  }
}

/// Single particle state — mutated in place each tick to avoid list
/// churn. `x` and `y` are normalised (0..1) so the painter can scale
/// them to whatever size the parent measures.
class _Particle {
  double x;
  double y;
  double speed;          // fraction of height per second
  double size;           // px radius at full life
  double driftAmplitude; // fraction of width for the horizontal sway
  double driftPhase;     // radians offset so all particles don't sway in lockstep
  double life;           // 1.0 → 0.0, drives alpha + size fade

  _Particle({
    required this.x,
    required this.y,
    required this.speed,
    required this.size,
    required this.driftAmplitude,
    required this.driftPhase,
    required this.life,
  });
}

class _ParticlePainter extends CustomPainter {
  final List<_Particle> particles;
  final Color colour;

  _ParticlePainter({required this.particles, required this.colour});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.2);

    for (final p in particles) {
      // Sway using a sine curve on the residual life so the particle
      // trails a soft S-curve upward, not a straight line.
      final sway = math.sin(p.life * math.pi * 3 + p.driftPhase) *
          p.driftAmplitude;
      final cx = (p.x + sway).clamp(0.05, 0.95) * size.width;
      final cy = p.y * size.height;
      // Fade profile: ease-out from 1.0 → 0 so particles bloom in
      // opacity briefly at spawn, then fade quickly toward the top.
      final t = p.life.clamp(0.0, 1.0);
      final alpha = (t * t * 0.9).clamp(0.0, 0.9);
      // Shrink as they rise so the top of the trail dissolves cleanly.
      final radius = p.size * (0.6 + 0.4 * t);
      paint.color = colour.withValues(alpha: alpha);
      canvas.drawCircle(Offset(cx, cy), radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter old) => true;
}
