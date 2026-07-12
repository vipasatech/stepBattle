import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/colors.dart';
import '../providers/auth_provider.dart';
import '../providers/tab_focus_provider.dart';
import '../sheets/buy_xp_sheet.dart';

/// Center "Buy XP" CTA — a violet-tinted stadium showing the user's
/// current XP balance with a `+` glyph, wrapped in a 1.2 s clockwise
/// sweep animation that runs once whenever the widget mounts. The
/// sweep is a narrow bright arc of brand violet that travels around
/// the perimeter — the pattern Strava uses on its Upgrade button.
/// After the arc completes one full rotation, the stroke fades out
/// over ~0.4 s so the steady state is just a calm tinted pill.
///
/// Home AppBar puts this in the centre title slot; Profile does the
/// same so the buy-XP affordance reads the same across pages.
///
/// The widget also listens to [homeTabFocusTickProvider] so the sweep
/// replays every time the user re-focuses the Home tab. Widgets on
/// other screens (Profile) don't observe the tick meaningfully — they
/// simply fire once on mount and stay steady until dismissed.
///
/// Implemented as a [CustomPainter] over a [SweepGradient] shader so
/// the effect costs one repaint per frame for ~1.6 s and zero after
/// that.
class BuyXpCta extends ConsumerStatefulWidget {
  const BuyXpCta({super.key});

  @override
  ConsumerState<BuyXpCta> createState() => _BuyXpCtaState();
}

class _BuyXpCtaState extends ConsumerState<BuyXpCta>
    with SingleTickerProviderStateMixin {
  /// Total animation lifecycle: 1.2 s sweep + 0.4 s fade-out.
  static const _totalDuration = Duration(milliseconds: 1600);

  /// Fraction of the controller spent on the rotation vs the fade-out.
  /// 0.75 means 1200 ms rotating, 400 ms fading.
  static const _sweepEnds = 0.75;

  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(vsync: this, duration: _totalDuration);
    // First run on mount (cold app launch OR entering a screen that
    // hosts this widget).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.forward(from: 0);
    });
    // The shell keeps HomeScreen alive across tab switches, so
    // initState on the Home CTA only fires once per session.
    // Subsequent visits to Home tick `homeTabFocusTickProvider`
    // (see MainShell) and we replay the sweep here.
    ref.listenManual<int>(homeTabFocusTickProvider, (prev, next) {
      if (!mounted) return;
      _controller.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        useRootNavigator: true,
        backgroundColor: Colors.transparent,
        builder: (_) => const BuyXpSheet(),
      ),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return CustomPaint(
            foregroundPainter: _SweepBorderPainter(
              progress: _controller.value,
              sweepEnds: _sweepEnds,
              color: AppColors.primary,
              highlight: AppColors.tertiary,
            ),
            child: child,
          );
        },
        child: Consumer(
          builder: (context, ref, _) {
            final balance =
                ref.watch(currentUserProvider).valueOrNull?.totalXP ?? 0;
            return Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 26, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.25),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bolt, color: AppColors.primary, size: 16),
                  const SizedBox(width: 5),
                  Text(
                    _fmtBalance(balance),
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      fontWeight: FontWeight.w900,
                      fontSize: 14,
                      letterSpacing: 0.2,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Icon(Icons.add_circle,
                      color: AppColors.primary.withValues(alpha: 0.85),
                      size: 16),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// Compact-format the XP balance for the pill: <1K verbatim,
  /// <1M as "4.0K" / "12K", millions as "1.2M". Keeps the pill
  /// width stable across orders of magnitude.
  static String _fmtBalance(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) {
      final k = n / 1000.0;
      return '${k.toStringAsFixed(k < 10 ? 1 : 0)}K';
    }
    return '${(n / 1000000).toStringAsFixed(1)}M';
  }
}

/// Paints a rotating bright arc around the stadium pill's perimeter,
/// then fades the whole stroke to invisible. The "arc" is just a
/// narrow bright band in a [SweepGradient] whose angle is offset by
/// `rotationProgress * 2π` each frame.
class _SweepBorderPainter extends CustomPainter {
  /// 0..1 controller value covering both phases.
  final double progress;

  /// Fraction of [progress] dedicated to the sweep; the remainder is
  /// the fade-out.
  final double sweepEnds;
  final Color color;
  final Color highlight;

  _SweepBorderPainter({
    required this.progress,
    required this.sweepEnds,
    required this.color,
    required this.highlight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || progress >= 1) return;

    final inFade = progress > sweepEnds;
    final rotation =
        inFade ? 1.0 : (progress / sweepEnds).clamp(0.0, 1.0);
    final fadeAlpha = inFade
        ? 1.0 -
            ((progress - sweepEnds) / (1 - sweepEnds)).clamp(0.0, 1.0)
        : 1.0;

    final rect = Offset.zero & size;
    final radius = size.height / 2;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(0.5),
      Radius.circular(radius),
    );

    final start = -math.pi / 2 + (rotation * 2 * math.pi);
    final shader = SweepGradient(
      transform: GradientRotation(start),
      colors: [
        color.withValues(alpha: 0.0),
        color.withValues(alpha: 0.55 * fadeAlpha),
        highlight.withValues(alpha: 0.95 * fadeAlpha),
        color.withValues(alpha: 0.55 * fadeAlpha),
        color.withValues(alpha: 0.0),
        color.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 0.10, 0.18, 0.26, 0.36, 1.0],
    ).createShader(rect);

    final paint = Paint()
      ..shader = shader
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(_SweepBorderPainter old) =>
      old.progress != progress;
}
