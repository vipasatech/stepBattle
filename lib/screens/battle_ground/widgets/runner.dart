import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../config/colors.dart';
import '../../../widgets/avatar_circle.dart';

/// A running figure — avatar + animated legs + shadow + dust + name chip.
/// The caller is responsible for positioning (via [Positioned]) and passing
/// the continuous [time] (seconds, monotonically increasing).
class Runner extends StatefulWidget {
  final String displayName;
  final String? avatarURL;
  final int steps;

  /// `time` is the global scene tick in seconds (continuous, monotonic).
  final double time;

  /// Whether this runner represents the current user (blue glow).
  final bool isMe;

  /// Whether this runner is currently the overall leader (crown).
  final bool isLeader;

  /// `1.0` under normal cadence. Values >1 cause faster leg swing when
  /// the runner is actively sliding forward.
  final double pace;

  /// If true, the scene has ended — freeze legs + show winner badge.
  final bool frozen;

  /// If true and frozen, this runner is the battle winner.
  final bool isWinner;

  const Runner({
    super.key,
    required this.displayName,
    required this.avatarURL,
    required this.steps,
    required this.time,
    required this.isMe,
    required this.isLeader,
    this.pace = 1.0,
    this.frozen = false,
    this.isWinner = false,
  });

  @override
  State<Runner> createState() => _RunnerState();
}

class _RunnerState extends State<Runner> {
  int _lastSteps = 0;
  double _stepBumpUntil = 0.0;

  @override
  void initState() {
    super.initState();
    _lastSteps = widget.steps;
  }

  @override
  void didUpdateWidget(covariant Runner old) {
    super.didUpdateWidget(old);
    if (widget.steps > old.steps) {
      _lastSteps = widget.steps;
      // Pop the step-count chip for 900ms after any increase.
      _stepBumpUntil = widget.time + 0.9;
    }
  }

  @override
  Widget build(BuildContext context) {
    const avatarRadius = 26.0;
    const totalHeight = 140.0;
    const totalWidth = 110.0;

    // Running cadence: 2.4 Hz base, sped up by pace during slides.
    final effectivePace = widget.frozen ? 0.0 : widget.pace;
    final phase = widget.time * 2 * math.pi * 2.4 * effectivePace;

    // Body bob — subtle up/down with each footfall
    final bob = widget.frozen
        ? 0.0
        : (math.sin(phase * 0.5).abs() * -5.0 + 2.0);

    // Lean forward when actively moving fast
    final lean = widget.frozen
        ? 0.0
        : math.min((widget.pace - 1.0) * 0.12, 0.18);

    // Step chip pop scale
    final chipScale =
        widget.time < _stepBumpUntil ? 1.0 + (_stepBumpUntil - widget.time) * 0.3 : 1.0;

    return SizedBox(
      width: totalWidth,
      height: totalHeight,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.bottomCenter,
        children: [
          // ------- Shadow (squashes on bob) -------
          Positioned(
            bottom: 2,
            child: _Shadow(intensity: 0.5 + bob.abs() * 0.06),
          ),

          // ------- Dust puffs behind feet -------
          if (!widget.frozen)
            Positioned(
              bottom: 0,
              child: _DustTrail(
                phase: phase,
                active: effectivePace > 0.8,
              ),
            ),

          // ------- Legs (painted) -------
          Positioned(
            bottom: 10,
            child: SizedBox(
              width: 40,
              height: 30,
              child: CustomPaint(
                painter: _LegsPainter(
                  phase: phase,
                  color: widget.isMe ? AppColors.primary : AppColors.amber,
                  frozen: widget.frozen,
                ),
              ),
            ),
          ),

          // ------- Avatar (bobs, leans) -------
          Positioned(
            bottom: 36,
            child: Transform.translate(
              offset: Offset(0, bob),
              child: Transform.rotate(
                angle: lean,
                child: _AvatarHalo(
                  isMe: widget.isMe,
                  isLeader: widget.isLeader,
                  child: AvatarCircle(
                    radius: avatarRadius,
                    imageUrl: widget.avatarURL,
                    initials: widget.displayName.isNotEmpty
                        ? widget.displayName[0].toUpperCase()
                        : '?',
                    borderColor: widget.isMe
                        ? AppColors.primary
                        : AppColors.amber,
                    borderWidth: 2,
                  ),
                ),
              ),
            ),
          ),

          // ------- Crown for leader -------
          if (widget.isLeader && !widget.frozen)
            Positioned(
              bottom: 36 + avatarRadius * 2 + 4,
              child: _Crown(time: widget.time),
            ),

          // ------- Winner badge (frozen state only) -------
          if (widget.frozen && widget.isWinner)
            Positioned(
              bottom: 36 + avatarRadius * 2 + 4,
              child: _WinnerBadge(),
            ),

          // ------- Name + step chip (floating above) -------
          Positioned(
            top: 0,
            child: Transform.scale(
              scale: chipScale,
              child: _NameChip(
                name: widget.displayName,
                steps: _lastSteps,
                isMe: widget.isMe,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Name + step chip
// =============================================================================
class _NameChip extends StatelessWidget {
  final String name;
  final int steps;
  final bool isMe;
  const _NameChip(
      {required this.name, required this.steps, required this.isMe});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = isMe ? AppColors.primary : AppColors.amber;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.5)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            isMe ? 'You' : name,
            style: theme.textTheme.labelSmall?.copyWith(
              color: accent,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
            ),
          ),
          Text(
            _fmt(steps),
            style: theme.textTheme.labelSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  static String _fmt(int n) {
    if (n == 0) return '0';
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}

// =============================================================================
// Shadow
// =============================================================================
class _Shadow extends StatelessWidget {
  final double intensity;
  const _Shadow({required this.intensity});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44 * intensity,
      height: 8,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(22),
      ),
    );
  }
}

// =============================================================================
// Dust trail
// =============================================================================
class _DustTrail extends StatelessWidget {
  final double phase;
  final bool active;
  const _DustTrail({required this.phase, required this.active});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 60,
      height: 14,
      child: CustomPaint(
        painter: _DustPainter(phase: phase, active: active),
      ),
    );
  }
}

class _DustPainter extends CustomPainter {
  final double phase;
  final bool active;
  _DustPainter({required this.phase, required this.active});

  @override
  void paint(Canvas canvas, Size size) {
    if (!active) return;
    // Three puffs that fade as they drift backward
    for (var i = 0; i < 3; i++) {
      final life = ((phase * 0.15 + i * 0.33) % 1.0);
      final x = size.width * (0.5 - life * 0.9);
      final alpha = (1.0 - life) * 0.35;
      final r = 4 + life * 5;
      canvas.drawCircle(
        Offset(x, size.height - 3),
        r,
        Paint()..color = Colors.white.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DustPainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.active != active;
}

// =============================================================================
// Legs — articulated stick figure, left + right out of phase
// =============================================================================
class _LegsPainter extends CustomPainter {
  final double phase;
  final Color color;
  final bool frozen;

  _LegsPainter({
    required this.phase,
    required this.color,
    required this.frozen,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, 0);
    final hipWidth = 8.0;
    final legLen = 18.0;

    if (frozen) {
      // Standing still — legs slightly apart, straight down
      final legPaint = Paint()
        ..color = color.withValues(alpha: 0.85)
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke;
      canvas.drawLine(center.translate(-hipWidth / 2, 0),
          center.translate(-hipWidth / 2, legLen), legPaint);
      canvas.drawLine(center.translate(hipWidth / 2, 0),
          center.translate(hipWidth / 2, legLen), legPaint);
      return;
    }

    final legPaint = Paint()
      ..color = color.withValues(alpha: 0.9)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Left leg
    _drawLeg(canvas, center.translate(-hipWidth / 2, 0), phase, legLen, legPaint);
    // Right leg — opposite phase
    _drawLeg(canvas, center.translate(hipWidth / 2, 0),
        phase + math.pi, legLen, legPaint);
  }

  void _drawLeg(
      Canvas canvas, Offset hip, double p, double totalLen, Paint paint) {
    // Upper leg swings forward/back; knee + foot derived.
    final swing = math.sin(p) * 12.0; // horizontal swing
    final lift = (math.cos(p * 1.0).clamp(-0.2, 1.0)) * 4.0; // vertical lift
    final kneeBend = math.max(0.0, math.sin(p)) * 6.0;

    final knee = hip.translate(swing * 0.6, totalLen * 0.5 - lift - kneeBend);
    final foot = hip.translate(swing, totalLen - lift);

    canvas.drawLine(hip, knee, paint);
    canvas.drawLine(knee, foot, paint);
  }

  @override
  bool shouldRepaint(covariant _LegsPainter oldDelegate) =>
      oldDelegate.phase != phase ||
      oldDelegate.color != color ||
      oldDelegate.frozen != frozen;
}

// =============================================================================
// Avatar halo — soft glow + breathing pulse
// =============================================================================
class _AvatarHalo extends StatelessWidget {
  final bool isMe;
  final bool isLeader;
  final Widget child;
  const _AvatarHalo({
    required this.isMe,
    required this.isLeader,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final color = isMe
        ? AppColors.primary
        : (isLeader ? AppColors.gold : AppColors.amber);
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: isLeader ? 0.55 : 0.3),
            blurRadius: isLeader ? 18 : 10,
            spreadRadius: isLeader ? 2 : 0,
          ),
        ],
      ),
      child: child,
    );
  }
}

// =============================================================================
// Crown — bobbing gold element above leader
// =============================================================================
class _Crown extends StatelessWidget {
  final double time;
  const _Crown({required this.time});

  @override
  Widget build(BuildContext context) {
    final bob = math.sin(time * 3.0) * 2.0;
    return Transform.translate(
      offset: Offset(0, bob),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFFFFE45C), Color(0xFFFFB400)],
          ),
          borderRadius: BorderRadius.circular(6),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFFFD700).withValues(alpha: 0.7),
              blurRadius: 8,
            ),
          ],
        ),
        child: const Text('\u2605',
            style: TextStyle(
              fontSize: 14,
              color: Color(0xFF6B3B00),
              fontWeight: FontWeight.w900,
            )),
      ),
    );
  }
}

class _WinnerBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFFFE45C), Color(0xFFFFB400)],
        ),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
              color: const Color(0xFFFFD700).withValues(alpha: 0.6),
              blurRadius: 12),
        ],
      ),
      child: const Text('WINNER',
          style: TextStyle(
            fontFamily: 'Manrope',
            fontSize: 10,
            fontWeight: FontWeight.w900,
            color: Color(0xFF6B3B00),
            letterSpacing: 1.2,
          )),
    );
  }
}
