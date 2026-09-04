import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/colors.dart';
import '../../providers/auth_provider.dart';
import '../../utils/cross_isolate_kv.dart';
import '../../utils/network_errors.dart';
import '../../widgets/no_network_sheet.dart';

/// First-run landing page.
///
/// Structure (four slides, one horizontal arena panorama split into
/// four chunks so swiping pans across a continuous top-down street):
///
///   • Arena chunk fills the whole Scaffold as `BoxFit.cover`
///     background, bleeding behind status bar, buttons, and system
///     nav. Four avatars are baked into each chunk on the road strip,
///     rotated 90° so they face east along the panorama.
///   • On top of the arena, a fixed overlay stack (from top → bottom):
///       – Header:  chapter title + short description
///       – Spacer   (arena+avatars visible through this gap)
///       – Card:    the actual tab component screenshot
///       – Dots:    page indicator
///       – Join for free button
///       – Log in text link
///   • Text/card overlays cross-fade with page position so the current
///     slide's copy is opaque while adjacent slides are dim.
///
/// Routing: entry point for signed-out users.
///   • `Join for free` → `/signup`
///   • `Log in`        → `/login`
class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  final _controller = PageController();

  /// Continuous page position (integer part = current page, fractional
  /// part = drag progress toward the next). Drives the header + card
  /// cross-fade so overlays fade when a slide is mid-transition.
  double _pageOffset = 0;

  /// Last-signed-in email hint (auth-persistence fix 2026-08-30). When
  /// non-null, the CTA row swaps `Join for free` + `Log in` for a
  /// one-tap `Continue as <email>` primary + `Not you?` fallback link.
  /// Preserved across session-death signOuts; cleared only on explicit
  /// user signOut. Sync-read once in [initState] because we don't need
  /// to react to changes mid-screen — the hint is set BEFORE welcome
  /// ever renders (during the previous sign-in that succeeded).
  String? _lastEmail;

  /// Last sign-in METHOD — one of 'google' / 'email' / null. Paired
  /// with [_lastEmail] so the Continue-as button fires the right flow
  /// directly instead of dropping the user on /login. Null = fall back
  /// to /login prefill (older users pre-2026-09-04).
  String? _lastMethod;

  /// Spinner state on the Continue-as button while Google sign-in or
  /// OTP send is in flight. Also disables the row so a double-tap
  /// doesn't fire twice.
  bool _busy = false;

  // Titles taken verbatim from the original marketing illustrations.
  // Assets are two per slide:
  //   • `arena` — the panorama chunk with 4 avatars baked onto the road
  //   • `component` — the actual tab-component screenshot
  static const _slides = <_Slide>[
    _Slide(
      arena: 'assets/illustrations/Slide 1_Phone_1080x2340.png',
      component: 'assets/illustrations/component_1.png',
      title: 'Every Step Counts',
      subtitle:
          "Steps, streaks, and today's target — one screen.",
    ),
    _Slide(
      arena: 'assets/illustrations/Slide 2_Phone_1080x2340.png',
      component: 'assets/illustrations/component_2.png',
      title: 'Every Battle Matters',
      subtitle:
          '1v1, group, or team — pick your fight, walk your way up.',
    ),
    _Slide(
      arena: 'assets/illustrations/Slide 3_Phone_1080x2340.png',
      component: 'assets/illustrations/component_3.png',
      title: 'Track & Share',
      subtitle: 'Real-time GPS with a share-ready map.',
    ),
    _Slide(
      arena: 'assets/illustrations/Slide 4_Phone_1080x2340.png',
      component: 'assets/illustrations/component_4.png',
      title: 'Track Your Progress',
      subtitle: 'Trendlines, streaks, and personal bests.',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    _lastEmail = CrossIsolateKV.getLastSignedInEmailSync();
    _lastMethod = CrossIsolateKV.getLastSignInMethodSync();
  }

  /// "Continue as [email]" handler — fires the SAME sign-in flow the
  /// user used last time so they land back where they came from with
  /// zero extra taps:
  ///   • `google` → open the Google account picker directly
  ///   • `email`  → send an OTP + jump straight to /verify-otp
  ///   • null (pre-2026-09-04 hint) → fall back to /login prefill
  ///
  /// Errors surface as a SnackBar; the row's [_busy] flag is cleared
  /// in `finally` so a failure leaves the button usable. Network
  /// errors get a friendlier "no internet" sheet via [showNoNetworkSheet].
  Future<void> _continueAsLastUser() async {
    if (_busy) return;
    final email = _lastEmail;
    if (email == null || email.isEmpty) return;
    final method = _lastMethod;

    // No method stored → fall back to legacy prefill behaviour so users
    // who last signed in BEFORE this fix still see a working button.
    if (method == null || method.isEmpty) {
      final uri = Uri(
        path: '/login',
        queryParameters: {'prefillEmail': email},
      );
      context.go(uri.toString());
      return;
    }

    setState(() => _busy = true);
    try {
      if (method == 'google') {
        await ref.read(authServiceProvider).signInWithGoogle();
        // On success the router listens to auth state and moves to
        // /home (or /onboarding). No manual navigation needed here.
      } else if (method == 'email') {
        await ref.read(authServiceProvider).sendEmailOtp(email);
        await CrossIsolateKV.savePendingOtp(email: email, mode: 'login');
        if (!mounted) return;
        context.go(
          '/verify-otp?email=${Uri.encodeQueryComponent(email)}&mode=login',
        );
      } else {
        // Unknown method → same legacy fallback as null.
        final uri = Uri(
          path: '/login',
          queryParameters: {'prefillEmail': email},
        );
        if (!mounted) return;
        context.go(uri.toString());
      }
    } catch (e) {
      if (!mounted) return;
      if (isNetworkError(e)) {
        final retry = await showNoNetworkSheet(context);
        if (!mounted) return;
        setState(() => _busy = false);
        if (retry == true) _continueAsLastUser();
        return;
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

  /// Cross-fade helper — opacity is 1.0 when a slide's index is
  /// centred, 0.0 when the neighbour is fully in view.
  double _opacityFor(int index) {
    final delta = (index - _pageOffset).clamp(-1.0, 1.0).abs();
    return (1.0 - delta).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentPage = _pageOffset.round().clamp(0, _slides.length - 1);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ─── Layer 1: swipeable arena panorama ─────────────────
          // The arena chunk is zoomed 114% (only marginally more
          // than the previous 1.08 — still avoids the tight
          // "over-zoomed" feel of 1.15) and shifted to the maximum
          // possible position with Alignment(0, 1.0) so the arena's
          // BOTTOM hugs the container bottom and its TOP (rooftops)
          // is clipped hardest. The combined effect lands the upper
          // sidewalk right under the description with no dead
          // building gap.
          PageView.builder(
            controller: _controller,
            itemCount: _slides.length,
            itemBuilder: (_, i) => ClipRect(
              child: LayoutBuilder(
                builder: (ctx, cons) {
                  final w = cons.maxWidth * 1.14;
                  final h = cons.maxHeight * 1.14;
                  return OverflowBox(
                    minWidth: w, maxWidth: w,
                    minHeight: h, maxHeight: h,
                    alignment: const Alignment(0, 1),
                    child: Image.asset(
                      _slides[i].arena,
                      fit: BoxFit.cover,
                      alignment: Alignment.center,
                      errorBuilder: (_, __, ___) => Container(
                        color: const Color(0xFF1B0A2E),
                        alignment: Alignment.center,
                        child: Text(
                          'Missing ${_slides[i].arena.split('/').last}',
                          style: const TextStyle(color: Colors.white54),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),

          // ─── Layer 2: top+bottom scrims for legibility ─────────
          const IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0xCC0F0821), // deep violet, ~80% alpha at very top
                    Color(0x000F0821), // clears by 22%
                    Color(0x000F0821), // stays clear through the road area
                    Color(0xF20F0821), // deep at the bottom card+CTA area
                  ],
                  stops: [0.0, 0.22, 0.55, 1.0],
                ),
              ),
            ),
          ),

          // ─── Layer 3: non-interactive overlays (header + card
          //   + dots). Wrapped in IgnorePointer so PageView swipes
          //   pass through to the arena below. ─────────────────────
          Positioned.fill(
            child: SafeArea(
              child: IgnorePointer(
                child: Padding(
                  // 24 bottom padding matches Layer 4's fromLTRB(24, 0, 24, 24)
                  // so Column's bottom lines up with the top of Layer 4's
                  // button content — the reserved SizedBox below then sits
                  // exactly where the buttons render, and the dots land
                  // right above it.
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
                  child: Column(
                    children: [
                      // Header — cross-faded per slide
                      SizedBox(
                        height: 108,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            for (int i = 0; i < _slides.length; i++)
                              Opacity(
                                opacity: _opacityFor(i),
                                child: _HeaderText(
                                  title: _slides[i].title,
                                  subtitle: _slides[i].subtitle,
                                  theme: theme,
                                ),
                              ),
                          ],
                        ),
                      ),

                      const Spacer(),

                      // Component screenshot — cross-faded per slide.
                      // Slide 3 (map) is now cropped vertically to the
                      // pin bounding box (top of green pin to bottom
                      // of red pin) while keeping full horizontal
                      // width, giving aspect ~1.62 which matches the
                      // other slides' cards. No AspectRatio wrapper
                      // needed — all 4 render at the same container
                      // size. Slide 3 still overrides `backgroundAlpha`
                      // for path visibility.
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 280),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            for (int i = 0; i < _slides.length; i++)
                              Opacity(
                                opacity: _opacityFor(i),
                                child: _ComponentCard(
                                  asset: _slides[i].component,
                                  backgroundAlpha: i == 2 ? 0.36 : 0.72,
                                ),
                              ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 14),

                      // Page dots
                      Row(
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
                                      : Colors.white.withValues(alpha: 0.35),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                            ),
                        ],
                      ),

                      // 20dp gap between dots and buttons so the
                      // dots have visual breathing room.
                      const SizedBox(height: 20),

                      // Space reserved for Layer 4's button content
                      // (48 button + 12 gap + 40 log-in = 100dp).
                      // The SafeArea + 24dp bottom padding are shared
                      // with Layer 4, so we only reserve the button
                      // stack's intrinsic height here.
                      const SizedBox(height: 48 + 12 + 40),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // ─── Layer 4: interactive CTAs pinned to the bottom ────
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: _lastEmail != null
                    ? _returningUserCtas(context, theme, _lastEmail!)
                    : _freshUserCtas(context, theme),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// CTA stack for a fresh install (no last-email hint stored). Same
  /// two-button layout that welcome has always shown: `Join for free`
  /// (primary → /signup) + `Log in` text link (→ /login).
  Widget _freshUserCtas(BuildContext context, ThemeData theme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Padding-based sizing (no fixed height) so the button
        // grows with the user's system font scale instead of
        // clipping "Join for free" at larger sizes. minimumSize
        // still keeps the tap target ≥ 52 dp at default scale.
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
              ),
              padding: const EdgeInsets.symmetric(vertical: 14),
              minimumSize: const Size.fromHeight(52),
            ),
            onPressed: () => context.go('/signup'),
            child: Text(
              'Join for free',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Log in — same padding-based approach so the pill
        // grows with font scale rather than clipping.
        TextButton(
          onPressed: () => context.go('/login'),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
            minimumSize: const Size.fromHeight(44),
          ),
          child: Text(
            'Log in',
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              color: AppColors.primary,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }

  /// CTA stack for a returning user whose session was recovered from
  /// the last-email hint (auth-persistence fix 2026-08-30). Shows a
  /// one-tap `Continue as <email>` primary that routes to `/login` with
  /// the email pre-filled (Google sign-in users tap Google as usual;
  /// OTP users skip typing and go straight to Send Code). Below it, a
  /// `Not <email>? Use a different account` link clears the hint and
  /// falls back to the fresh-user flow.
  Widget _returningUserCtas(
      BuildContext context, ThemeData theme, String email) {
    // Elide long emails so a very long username never breaks the button
    // layout. Native ellipsis on the Text handles the middle-of-string
    // truncation for us via maxLines:1 + overflow:ellipsis.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
              ),
              padding: const EdgeInsets.symmetric(
                  vertical: 12, horizontal: 20),
              minimumSize: const Size.fromHeight(58),
            ),
            onPressed: _busy ? null : _continueAsLastUser,
            child: _busy
                ? const SizedBox(
                    height: 22,
                    width: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Continue as',
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.75),
                          fontWeight: FontWeight.w500,
                          fontSize: 12,
                          letterSpacing: 0.15,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        email,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 12),
        // Fallback: clear the hint + route to /login so the user picks
        // a different account. `setState` so the current screen also
        // re-renders as fresh-user next time it's visible.
        TextButton(
          onPressed: () async {
            // clearLastSignedInEmail also clears the stored method
            // (2026-09-04 fix) so the next welcome render reads as a
            // clean fresh-user state.
            await CrossIsolateKV.clearLastSignedInEmail();
            if (!context.mounted) return;
            setState(() {
              _lastEmail = null;
              _lastMethod = null;
            });
            context.go('/login');
          },
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 20),
            minimumSize: const Size.fromHeight(44),
          ),
          child: Text(
            'Not you? Sign in with a different account',
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppColors.primary,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ),
      ],
    );
  }
}

class _Slide {
  final String arena;
  final String component;
  final String title;
  final String subtitle;

  const _Slide({
    required this.arena,
    required this.component,
    required this.title,
    required this.subtitle,
  });
}

class _HeaderText extends StatelessWidget {
  final String title;
  final String subtitle;
  final ThemeData theme;

  const _HeaderText({
    required this.title,
    required this.subtitle,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.headlineSmall?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            fontSize: 28,
            height: 1.05,
            letterSpacing: -0.5,
            shadows: const [
              Shadow(
                color: Colors.black87,
                blurRadius: 14,
                offset: Offset(0, 3),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: Colors.white.withValues(alpha: 0.85),
            fontSize: 13,
            height: 1.35,
            shadows: const [
              Shadow(
                color: Colors.black54,
                blurRadius: 8,
                offset: Offset(0, 2),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ComponentCard extends StatelessWidget {
  final String asset;
  // 0.72 matches the app's `coming_soon_sheet`; slides with dense
  // dark content (e.g. slide 3 map) pass a lower value to let more
  // arena bleed through behind the card.
  final double backgroundAlpha;
  const _ComponentCard({required this.asset, this.backgroundAlpha = 0.72});

  @override
  Widget build(BuildContext context) {
    // Dark-glass card — same style as the app's `coming_soon_sheet`
    // (dark #14141A + primary-tinted border). Gives the transparent
    // PNGs something to sit on so the white text / thin trendlines
    // stay legible over the busy arena underneath.
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF14141A).withValues(alpha: backgroundAlpha),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.4),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      padding: const EdgeInsets.all(6),
      child: Image.asset(
        asset,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => Container(
          color: const Color(0xFF14082D),
          padding: const EdgeInsets.all(24),
          child: Text(
            'Missing ${asset.split('/').last}',
            style: const TextStyle(color: Colors.white54),
          ),
        ),
      ),
    );
  }
}
