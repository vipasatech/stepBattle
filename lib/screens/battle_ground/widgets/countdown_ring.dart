import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../config/colors.dart';

/// Circular countdown that fills *down* from green → amber → red as time
/// runs out, with the remaining time label in the center.
class CountdownRing extends StatelessWidget {
  final Duration remaining;
  final Duration total;
  final double size;

  const CountdownRing({
    super.key,
    required this.remaining,
    required this.total,
    this.size = 68,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pct = total.inSeconds <= 0
        ? 0.0
        : (remaining.inSeconds / total.inSeconds).clamp(0.0, 1.0);

    Color ringColor;
    if (pct > 0.5) {
      ringColor = AppColors.primary;
    } else if (pct > 0.2) {
      ringColor = AppColors.amber;
    } else {
      ringColor = AppColors.error;
    }

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Backdrop circle
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.1),
              ),
            ),
          ),
          // Ring progress
          SizedBox(
            width: size - 6,
            height: size - 6,
            child: CustomPaint(
              painter: _RingPainter(pct: pct, color: ringColor),
            ),
          ),
          // Label
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _primary(remaining),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                  height: 1.0,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                _secondary(remaining),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.7),
                  letterSpacing: 1.5,
                  fontSize: 9,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Largest non-zero unit.
  static String _primary(Duration r) {
    if (r.isNegative || r == Duration.zero) return '0';
    if (r.inDays >= 1) return '${r.inDays}d';
    if (r.inHours >= 1) return '${r.inHours}h';
    if (r.inMinutes >= 1) return '${r.inMinutes}m';
    return '${r.inSeconds}s';
  }

  static String _secondary(Duration r) {
    if (r.inDays >= 1) return '${r.inHours % 24}H LEFT';
    if (r.inHours >= 1) return '${r.inMinutes % 60}M LEFT';
    if (r.inMinutes >= 1) return '${r.inSeconds % 60}S LEFT';
    return 'ENDED';
  }
}

class _RingPainter extends CustomPainter {
  final double pct;
  final Color color;

  _RingPainter({required this.pct, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2;

    final track = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, radius, track);

    final fg = Paint()
      ..color = color
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: 2 * math.pi,
        colors: [
          color.withValues(alpha: 0.4),
          color,
        ],
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(Rect.fromCircle(center: center, radius: radius));

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * pct,
      false,
      fg,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.pct != pct || oldDelegate.color != color;
}
