import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../config/colors.dart';

/// First-run landing page — a 5-slide carousel with a very intentional
/// look:
///
///   • Violet gradient background per slide (each tab gets a slightly
///     different accent so swiping feels tactile).
///   • Floating phone-frame mockup with a soft violet ambient glow,
///     a subtle screen shine gradient, and a gentle up-and-down bob
///     that makes the frame feel weightless while stationary.
///   • Parallax on swipe: as the PageView drags, the phone frame
///     rotates slightly on its Y-axis and shifts by a fraction of the
///     drag, creating a depth-of-field peek at the neighbouring slide.
///
/// Missing PNGs fall back to a "drop `<file>` in assets/mockups/"
/// placeholder inside the frame, so a fresh clone renders without
/// crashing.
///
/// Routing: entry point for signed-out users.
///   • `Join for free` → `/signup`
///   • `Log in`        → `/login`
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _controller = PageController();

  /// Continuous page position (integer part = current page, fractional
  /// part = drag progress toward the next). Drives the parallax +
  /// tilt on each slide. Rebuilds on every scroll offset change via
  /// the controller listener.
  double _pageOffset = 0;

  static const _slides = <_Slide>[
    _Slide(
      asset: 'assets/mockups/home.jpeg',
      title: 'Your day at a glance.',
      subtitle:
          "Steps, streaks, battles, and today's target — one screen.",
      accentTop: Color(0xFF7C3AED),
      accentBottom: Color(0xFF1B1030),
    ),
    _Slide(
      asset: 'assets/mockups/battles.jpeg',
      title: 'Battle friends in step races.',
      subtitle:
          '1v1, group, or team — pick your fight, walk your way up.',
      accentTop: Color(0xFF9333EA),
      accentBottom: Color(0xFF2A0B45),
    ),
    _Slide(
      asset: 'assets/mockups/track.jpeg',
      title: 'Track every run.',
      subtitle:
          'Real-time GPS, live pace, and a share-ready map when you finish.',
      accentTop: Color(0xFF6D28D9),
      accentBottom: Color(0xFF120A20),
    ),
    _Slide(
      asset: 'assets/mockups/profile.jpeg',
      title: 'Watch your progress climb.',
      subtitle:
          'Trendlines, streaks, and personal bests — every step counted.',
      accentTop: Color(0xFF8B5CF6),
      accentBottom: Color(0xFF17091F),
    ),
    _Slide(
      asset: 'assets/mockups/leaderboard.jpeg',
      title: 'Own the leaderboard.',
      subtitle:
          'Friends, district, and world rankings updated every step.',
      accentTop: Color(0xFFA855F7),
      accentBottom: Color(0xFF1B0A2E),
    ),
  ];

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  void _onScroll() {
    final page = _controller.page ?? 0;
    if (page != _pageOffset) {
      setState(() => _pageOffset = page);
    }
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentPage = _pageOffset.round().clamp(0, _slides.length - 1);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // ---- Slide carousel ---------------------------------
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _slides.length,
                itemBuilder: (_, i) {
                  // Distance from this slide's centre in "pages"
                  // (0 when centred, +/-1 when the next/prev slide
                  // is fully in view). Drives per-slide parallax +
                  // rotation.
                  final delta = i - _pageOffset;
                  return _SlideView(slide: _slides[i], delta: delta);
                },
              ),
            ),

            // ---- Page dots --------------------------------------
            Padding(
              padding: const EdgeInsets.only(bottom: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (int i = 0; i < _slides.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        width: i == currentPage ? 22 : 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: i == currentPage
                              ? AppColors.primary
                              : Colors.white.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // ---- CTAs -------------------------------------------
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      onPressed: () => context.go('/signup'),
                      child: Text(
                        'Join for free',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => context.go('/login'),
                    child: Text(
                      'Log in',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Slide {
  final String asset;
  final String title;
  final String subtitle;
  final Color accentTop;
  final Color accentBottom;

  const _Slide({
    required this.asset,
    required this.title,
    required this.subtitle,
    required this.accentTop,
    required this.accentBottom,
  });
}

class _SlideView extends StatelessWidget {
  final _Slide slide;

  /// Distance from the centre of this slide in "pages" (see the
  /// PageView.builder in the parent). Used to apply parallax + tilt
  /// as the user swipes.
  final double delta;

  const _SlideView({required this.slide, required this.delta});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // How "off-centre" this slide is, clamped to [-1, 1]. When
    // stationary this is 0. When the next slide is fully in view
    // this is -1 (this slide is leaving to the left).
    final clampedDelta = delta.clamp(-1.0, 1.0);
    // Rotate the phone frame around its Y-axis in proportion to
    // the drag — subtle, capped at ~14° for a peek-not-flip feel.
    final tilt = -clampedDelta * (math.pi / 12);
    // Shift the frame horizontally by a fraction of the drag to
    // exaggerate the parallax against the (stationary) caption.
    final parallax = -clampedDelta * 40.0;
    // Fade the caption slightly as the slide leaves the centre so
    // the eye stays on whatever's incoming.
    final captionOpacity = (1.0 - clampedDelta.abs()).clamp(0.0, 1.0);

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            slide.accentTop.withValues(alpha: 0.55),
            slide.accentBottom,
          ],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Text(
              'STEPBATTLE',
              style: theme.textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontFamily: 'Manrope',
                fontStyle: FontStyle.italic,
                fontWeight: FontWeight.w900,
                letterSpacing: 3,
              ),
            ),
          ),
          const SizedBox(height: 20),
          // Phone-frame mockup with parallax + tilt applied. The
          // _FloatingPhoneFrame widget handles the perpetual bob,
          // ambient glow, and screen shine internally so this
          // Transform only owns swipe-driven motion.
          Expanded(
            child: Center(
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.001) // perspective
                  ..translate(parallax)
                  ..rotateY(tilt),
                child: _FloatingPhoneFrame(
                  assetPath: slide.asset,
                  glow: slide.accentTop,
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          // Caption stack — opacity fades in as this slide centres.
          Opacity(
            opacity: captionOpacity,
            child: Column(
              children: [
                Text(
                  slide.title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    height: 1.1,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  slide.subtitle,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white.withValues(alpha: 0.72),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

/// Phone-frame mockup with:
///   • Fixed 9:19.5 aspect ratio (modern phone shape).
///   • Thin white outline for a device silhouette.
///   • Two-layer ambient glow (accent-tinted + neutral shadow) so
///     the frame reads as floating above the gradient.
///   • Continuous gentle bob (up/down 6 dp, 3 s cycle) driven by
///     TweenAnimationBuilder — pure animation, no controller
///     lifecycle to manage.
///   • Diagonal screen shine overlay for a premium glass feel.
///   • Notch stub at the top mimicking iPhone Dynamic Island.
class _FloatingPhoneFrame extends StatefulWidget {
  final String assetPath;
  final Color glow;
  const _FloatingPhoneFrame({required this.assetPath, required this.glow});

  @override
  State<_FloatingPhoneFrame> createState() => _FloatingPhoneFrameState();
}

class _FloatingPhoneFrameState extends State<_FloatingPhoneFrame>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bob;

  @override
  void initState() {
    super.initState();
    _bob = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _bob.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _bob,
      builder: (context, child) {
        // Ease the linear controller into a sine-shape offset so the
        // top and bottom of the bob feel weightless (hangs slightly
        // at the extremes).
        final t = Curves.easeInOut.transform(_bob.value);
        final dy = -3.0 + (t - 0.5) * -6.0; // -6..0 dp range
        return Transform.translate(
          offset: Offset(0, dy),
          child: child,
        );
      },
      child: AspectRatio(
        aspectRatio: 9 / 19.5,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(36),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.9),
                width: 2,
              ),
              boxShadow: [
                // Accent-tinted ambient glow behind the frame.
                BoxShadow(
                  color: widget.glow.withValues(alpha: 0.55),
                  blurRadius: 60,
                  spreadRadius: 4,
                ),
                // Neutral drop-shadow for grounded depth.
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.55),
                  blurRadius: 40,
                  offset: const Offset(0, 20),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(34),
              child: Stack(
                children: [
                  // Screen content or fallback.
                  Positioned.fill(
                    child: Image.asset(
                      widget.assetPath,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          _MissingMockupFallback(
                        assetName: widget.assetPath.split('/').last,
                      ),
                    ),
                  ),
                  // Screen shine — subtle diagonal white gradient
                  // sweeping across the top-left of the screen for a
                  // premium glass feel.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Colors.white.withValues(alpha: 0.14),
                              Colors.white.withValues(alpha: 0.0),
                              Colors.white.withValues(alpha: 0.0),
                              Colors.white.withValues(alpha: 0.06),
                            ],
                            stops: const [0.0, 0.35, 0.75, 1.0],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Notch stub at the top mimicking iPhone Dynamic
                  // Island — small horizontal pill in front of the
                  // screen content.
                  Positioned(
                    top: 8,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        width: 64,
                        height: 14,
                        decoration: BoxDecoration(
                          color: Colors.black,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Rendered inside the phone frame when the PNG for a slide is
/// missing. Keeps the layout intact so the developer sees a
/// pointer to the README instead of a Flutter red-screen exception.
class _MissingMockupFallback extends StatelessWidget {
  final String assetName;
  const _MissingMockupFallback({required this.assetName});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(20),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.image_outlined,
            color: Colors.white54,
            size: 40,
          ),
          const SizedBox(height: 12),
          Text(
            'Drop\n$assetName\nin assets/mockups/',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}
