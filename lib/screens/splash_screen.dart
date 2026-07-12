import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/colors.dart';
import '../providers/auth_provider.dart';

/// Cold-launch splash. Static brand logo centered, with three concentric
/// rings pulsing outward behind it (the "spiral" sonar effect). No video,
/// no animated character — that's parked until a hand-built character
/// animation lands in assets/animations/.
///
/// Routing is robust against flaky networks:
///   • Uses Supabase's *cached* user synchronously, so a cold-start that
///     can't refresh the access token still lands on /home.
///   • Hard 5-second ceiling — splash never sits longer than that even
///     if the auth stream is stuck loading.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  /// 1800 ms ring pulse — three rings phase-staggered by 1/3 of the cycle
  /// so the outward sweep feels continuous.
  late final AnimationController _ringCtrl;

  /// Minimum wall-clock display so the splash doesn't flash by even when
  /// auth resolves in tens of milliseconds.
  static const _minDisplay = Duration(milliseconds: 1400);

  /// Hard ceiling. Decides routing from Supabase's local cache when the
  /// auth stream gets stuck (DNS failure, endless refresh retries, etc.).
  static const _maxDisplay = Duration(seconds: 5);

  Timer? _floorTimer;
  Timer? _ceilingTimer;
  bool _floorElapsed = false;
  bool _routed = false;

  @override
  void initState() {
    super.initState();
    _ringCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();

    _floorTimer = Timer(_minDisplay, () {
      if (!mounted) return;
      setState(() => _floorElapsed = true);
      _maybeRoute();
    });

    _ceilingTimer = Timer(_maxDisplay, _forceRoute);
  }

  @override
  void dispose() {
    _floorTimer?.cancel();
    _ceilingTimer?.cancel();
    _ringCtrl.dispose();
    super.dispose();
  }

  /// Supabase's in-memory session — works offline; populated synchronously
  /// during `Supabase.initialize` in main.dart from secure storage.
  User? get _cachedUser => Supabase.instance.client.auth.currentUser;

  void _maybeRoute() {
    if (_routed) return;
    if (!_floorElapsed) return;

    final auth = ref.read(authStateProvider);
    if (!auth.isLoading) {
      final user = auth.valueOrNull;
      if (user == null) {
        _go('/welcome');
        return;
      }
      _decideLoggedInDest();
      return;
    }

    // Auth stream still loading — fall back to cached user.
    if (_cachedUser != null) {
      _decideLoggedInDest();
    }
  }

  void _decideLoggedInDest() {
    final onboarded = ref.read(hasCompletedOnboardingProvider).valueOrNull;
    _go(onboarded == false ? '/onboarding' : '/home');
  }

  void _forceRoute() {
    if (_routed) return;
    if (_cachedUser != null) {
      _decideLoggedInDest();
    } else {
      _go('/welcome');
    }
  }

  void _go(String dest) {
    if (_routed) return;
    _routed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.go(dest);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authStateProvider, (_, __) => _maybeRoute());
    ref.listen(hasCompletedOnboardingProvider, (_, __) => _maybeRoute());

    final size = MediaQuery.of(context).size;

    return Scaffold(
      body: Stack(
        children: [
          const _GradientBackdrop(),

          // Soft frosted-glass orbs for depth — Strava / Apple Fitness vibe.
          _BlurredOrb(
            top: size.height * 0.10,
            left: size.width * 0.10,
            radius: 140,
            color: const Color(0xFFA855F7).withValues(alpha: 0.55),
          ),
          _BlurredOrb(
            bottom: size.height * 0.08,
            right: size.width * 0.05,
            radius: 180,
            color: const Color(0xFF7C3AED).withValues(alpha: 0.55),
          ),

          // Spiral / pulse rings + centered static logo. Container size
          // and scale formula chosen so the outermost ring at its peak
          // (~231 dp) sits about 1.45× the logo's 160 dp — matching the
          // tight ring spread visible in the native Android splash. Earlier
          // values (280 dp + scale up to 1.5) had rings ballooning to
          // ~2.6× the logo, which created a visible mismatch when handing
          // off from the native splash to this widget.
          Center(
            child: SizedBox(
              width: 220,
              height: 220,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  for (var i = 0; i < 3; i++)
                    AnimatedBuilder(
                      animation: _ringCtrl,
                      builder: (_, __) {
                        final phase = (_ringCtrl.value + i / 3) % 1.0;
                        // Tightened: 0.75 → 1.05 (vs old 0.55 → 1.5).
                        final scale = 0.75 + phase * 0.30;
                        final opacity =
                            (1.0 - phase).clamp(0.0, 1.0) * 0.55;
                        return Opacity(
                          opacity: opacity,
                          child: Transform.scale(
                            scale: scale,
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white
                                      .withValues(alpha: 0.85),
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  // Static logo — circular, no bounce, no tilt. The outer
                  // decoration uses BoxShape.circle so the drop shadow
                  // matches the ClipOval cropped image.
                  Container(
                    width: 160,
                    height: 160,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.25),
                          blurRadius: 24,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: ClipOval(
                      child: Image.asset(
                        'assets/logos/logo_square.png',
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Wordmark + tagline.
          // Wordmark + tagline. Manrope w900 for the wordmark, w500 for
          // the tagline — matches the native splash's branding-image
          // typography exactly. Letter-spacing kept narrow (~1) so it
          // reads tighter than the previous 2 px which made the letters
          // feel disjointed.
          Positioned(
            left: 0,
            right: 0,
            bottom: 80,
            child: Column(
              children: [
                Text(
                  'StepBattle',
                  style: GoogleFonts.manrope(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.5,
                    shadows: [
                      Shadow(
                        color: Colors.black.withValues(alpha: 0.4),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Every step counts.',
                  style: GoogleFonts.manrope(
                    color: AppColors.onSurface.withValues(alpha: 0.75),
                    fontSize: 11,
                    letterSpacing: 1,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),

          // Indeterminate hairline — implies "loading" without a literal spinner.
          Positioned(
            left: 0,
            right: 0,
            bottom: 36,
            child: Center(
              child: SizedBox(
                width: 48,
                height: 3,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    backgroundColor: AppColors.onSurface.withValues(alpha: 0.15),
                    valueColor: AlwaysStoppedAnimation(
                      AppColors.onSurface.withValues(alpha: 0.8),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Backdrop — diagonal violet gradient that matches the launcher icon so the
// native launch screen and the Flutter splash read as one piece.
// =============================================================================
class _GradientBackdrop extends StatelessWidget {
  const _GradientBackdrop();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFFA855F7),
            Color(0xFF7C3AED),
            Color(0xFF4C1D95),
          ],
          stops: [0.0, 0.6, 1.0],
        ),
      ),
    );
  }
}

// =============================================================================
// Blurred orb — translucent circle behind a heavy blur. Two of these at
// opposing corners give the splash the "frosted glass over color" feel of
// modern fitness apps.
// =============================================================================
class _BlurredOrb extends StatelessWidget {
  final double? top;
  final double? bottom;
  final double? left;
  final double? right;
  final double radius;
  final Color color;

  const _BlurredOrb({
    this.top,
    this.bottom,
    this.left,
    this.right,
    required this.radius,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: top,
      bottom: bottom,
      left: left,
      right: right,
      child: IgnorePointer(
        child: ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
          child: Container(
            width: radius * 2,
            height: radius * 2,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}
