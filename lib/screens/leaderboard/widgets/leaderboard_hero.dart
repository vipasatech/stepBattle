import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../config/colors.dart';
import '../../../models/leaderboard_entry_model.dart';
import '../../../providers/tab_focus_provider.dart';
import '../../../widgets/avatar_circle.dart';

/// Top-of-board hero — the #1 leader spotlighted with:
///   • Sunburst ray backdrop in muted gold.
///   • The user's avatar centre-frame.
///   • A rotating brand-violet sweep arc around the avatar circle
///     that fires on mount + every time the user re-focuses the
///     Ranks tab (mirrors the +XP CTA on Home). The arc fades to
///     invisible after one full rotation so the steady state is a
///     calm centered avatar.
///   • A small crown perched on top of the avatar.
///   • Big XP number + crown-tagged name below.
class LeaderboardHero extends ConsumerStatefulWidget {
  final LeaderboardEntry topEntry;

  /// Scope banner ("YOUR FRIENDS" / "HYDERABAD" + "Top by XP"),
  /// rendered inside the hero so the rays background can span both
  /// the banner and the top-user profile — per the boundaries the
  /// user asked for (rays end just below the tabs bar on top and
  /// just above the column-header row on bottom).
  final Widget scopeBanner;

  const LeaderboardHero({
    super.key,
    required this.topEntry,
    required this.scopeBanner,
  });

  @override
  ConsumerState<LeaderboardHero> createState() => _LeaderboardHeroState();
}

class _LeaderboardHeroState extends ConsumerState<LeaderboardHero>
    with SingleTickerProviderStateMixin {
  /// 1.2 s sweep + 0.4 s fade-out (same envelope as +XP CTA).
  static const _totalDuration = Duration(milliseconds: 1600);
  static const _sweepEnds = 0.75;

  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _totalDuration);
    // First run on mount (cold launch or first Ranks tap).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.forward(from: 0);
    });
    // Re-fire whenever the shell reports the user just landed on Ranks.
    ref.listenManual<int>(ranksTabFocusTickProvider, (prev, next) {
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
    final theme = Theme.of(context);

    // Avatar centre Y from the top of the hero — anchors the rays so
    // wedges emanate from the crown-topped face:
    //   padTop (8) + scope-banner (30) + gap (12) + crown (26)
    //     + gap (4) + avatar half-height (34) = 114
    const double avatarCentreY = 114;

    return Stack(
      // topCenter so the (mainAxisSize.min) Column sits centred
      // horizontally within the full-width rays layer.
      alignment: Alignment.topCenter,
      children: [
        // ---- Full-bleed rays layer -------------------------------
        // Fills the whole hero widget: top edge = the imaginary line
        // between the tabs bar and the scope banner, bottom edge =
        // the imaginary line above the column-header row. The scope
        // banner + crown + avatar + XP + name all sit ON TOP of it.
        Positioned.fill(
          child: CustomPaint(
            painter: _RaysPainter(
              centreY: avatarCentreY,
              light: Colors.white.withValues(alpha: 0.06),
              dark: Colors.white.withValues(alpha: 0.015),
            ),
          ),
        ),

        // ---- Content column on top -------------------------------
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Scope banner brings its own 20-dp horizontal padding.
            const SizedBox(height: 8),
            widget.scopeBanner,
            const SizedBox(height: 12),

            // Crown standalone above the avatar.
            Icon(
              MdiIcons.crown,
              size: 26,
              color: AppColors.amber,
            ),
            const SizedBox(height: 4),
            // Avatar + sweep border share a 68 dp box so the arc
            // and the border coincide.
            SizedBox(
              width: 68,
              height: 68,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Center(
                    child: AvatarCircle(
                      radius: 30,
                      imageUrl: widget.topEntry.avatarURL,
                      initials: _initials(widget.topEntry.displayName),
                      borderColor: Colors.transparent,
                      borderWidth: 0,
                    ),
                  ),
                  AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) => CustomPaint(
                      foregroundPainter: _CircleSweepPainter(
                        progress: _controller.value,
                        sweepEnds: _sweepEnds,
                        color: AppColors.primary,
                        highlight: AppColors.tertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 6),

            // ---- Big XP value + label ----
            Text(
              _fmt(widget.topEntry.totalXP),
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w900,
                fontFamily: 'Manrope',
                letterSpacing: -0.8,
                height: 1.0,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'XP',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                letterSpacing: 1.6,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),

            // ---- Trophy + name of #1 ----
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.emoji_events,
                  color: AppColors.amber,
                  size: 16,
                ),
                const SizedBox(width: 6),
                Text(
                  widget.topEntry.displayName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ],
    );
  }

  static String _initials(String name) {
    if (name.isEmpty) return '?';
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name[0].toUpperCase();
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
// Rays painter — alternating pie-slice wedges radiating from centre.
// Reference image the user shared shows 16 wedges around a central
// character, in two subtly-different shades against a dark base.
// This paints [light] wedges on the even indices and [dark] wedges
// on the odd indices — the container background under the CustomPaint
// stays fully visible between them so the effect blends with any
// Profile / Ranks surface tint.
// =============================================================================
class _RaysPainter extends CustomPainter {
  /// Y-coordinate (from the top of the paint area) that the wedges
  /// radiate from. Horizontally the centre is always mid-width. Set
  /// to the avatar's centre-y so rays appear to emanate from behind
  /// the character rather than from the geometric middle of the box.
  final double centreY;
  final Color light;
  final Color dark;

  const _RaysPainter({
    required this.centreY,
    required this.light,
    required this.dark,
  });

  static const int _wedgeCount = 16;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = Offset(size.width / 2, centreY);
    // Radius reaches the farthest corner of the paint area from
    // [centre] so every pixel of the hero is covered by a wedge.
    final maxDx = math.max(centre.dx, size.width - centre.dx);
    final maxDy = math.max(centre.dy, size.height - centre.dy);
    final radius = math.sqrt(maxDx * maxDx + maxDy * maxDy);
    const sweep = 2 * math.pi / _wedgeCount;

    for (int i = 0; i < _wedgeCount; i++) {
      final startAngle = i * sweep - math.pi / 2;
      final paint = Paint()
        ..color = (i.isEven ? light : dark)
        ..style = PaintingStyle.fill;
      final path = Path()
        ..moveTo(centre.dx, centre.dy)
        ..lineTo(
          centre.dx + radius * math.cos(startAngle),
          centre.dy + radius * math.sin(startAngle),
        )
        ..arcTo(
          Rect.fromCircle(center: centre, radius: radius),
          startAngle,
          sweep,
          false,
        )
        ..close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_RaysPainter old) =>
      old.centreY != centreY ||
      old.light != light ||
      old.dark != dark;
}

// =============================================================================
// Circular sweep painter — port of home's _SweepBorderPainter to a
// perfect circle. Rotates a bright band around the circumference for
// [sweepEnds] of the progress, then fades the whole stroke out.
// =============================================================================
class _CircleSweepPainter extends CustomPainter {
  final double progress;
  final double sweepEnds;
  final Color color;
  final Color highlight;

  _CircleSweepPainter({
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
    // Start the bright band at 12 o'clock, then rotate around.
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
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    // Circle centred inside the box; radius shrunk by half the stroke
    // so the arc paints inside the bounds.
    final centre = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 1.25;
    canvas.drawCircle(centre, radius, paint);
  }

  @override
  bool shouldRepaint(_CircleSweepPainter old) => old.progress != progress;
}
