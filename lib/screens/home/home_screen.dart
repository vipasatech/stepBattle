import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../config/colors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/notification_provider.dart';
import '../../providers/tab_focus_provider.dart';
import '../../providers/user_provider.dart';
import '../../sheets/buy_xp_sheet.dart';
import '../../sheets/complete_profile_sheet.dart';
import '../../sheets/notifications_sheet.dart';
import '../../widgets/avatar_circle.dart';
import '../../widgets/friends_app_bar_button.dart';
import '../../widgets/no_steps_banner.dart';
import 'widgets/overview_card.dart';
import 'widgets/stat_pills_row.dart';
import 'widgets/active_battle_card.dart';
import 'widgets/daily_target_card.dart';
import 'widgets/map_preview_card.dart';
import 'widgets/streak_strip.dart';
import 'widgets/todays_session_card.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final unreadCount = ref.watch(unreadNotificationCountProvider);

    // Catch-up sheet for users who onboarded before migration 0016. Pops
    // once per session if the survey fields (DOB/gender/fitness) are
    // missing. Idempotent — see `maybeShowCompleteProfileSheet`.
    final me = ref.watch(currentUserProvider).valueOrNull;
    if (me != null) {
      maybeShowCompleteProfileSheet(context, me);
    }

    // New top-bar topology (replaces the old wordmark + 5-action row):
    //
    //   ┌─ leading ──────────────┐ ┌── title ──┐ ┌── actions ─┐
    //   │ (Profile)(Friends)     │ │  +XP CTA  │ │   🔔²      │
    //   └────────────────────────┘ └───────────┘ └────────────┘
    //
    //   • Profile + Friends sit in the hardest-to-reach corner (low-
    //     frequency identity actions).
    //   • +XP CTA gets the center slot for maximum visual pull, paired
    //     with a 1.2 s sweep animation around its border that fires once
    //     on every Home mount (the user explicitly asked for this).
    //   • Notification bell with its badge stays right — that's where
    //     the eye expects it and the thumb finds it easily.
    return Scaffold(
      appBar: AppBar(
        // Make room for the Profile avatar + Friends button in the
        // leading slot — defaults to 56 which only fits one.
        leadingWidth: 100,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: () => context.push('/profile'),
                child: AvatarCircle(
                  radius: 18,
                  imageUrl: profile?.avatarURL,
                  initials: _initials(profile?.displayName),
                  borderColor: AppColors.outlineVariant,
                  borderWidth: 1,
                ),
              ),
              const SizedBox(width: 8),
              const FriendsAppBarButton(),
            ],
          ),
        ),
        centerTitle: true,
        title: const _BuyXpCta(),
        actions: [
          _BellButton(unreadCount: unreadCount),
          const SizedBox(width: 12),
        ],
      ),
      body: const _HomeBody(),
    );
  }

  static String _initials(String? name) {
    if (name == null || name.isEmpty) return '?';
    final parts = name.split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name[0].toUpperCase();
  }
}

/// Center "Buy XP" CTA in the Home AppBar.
///
/// Wraps a violet-tinted stadium with a 1.2 s clockwise sweep animation
/// that runs once whenever the widget mounts. The sweep is a narrow
/// bright arc of brand violet that travels around the perimeter — the
/// pattern Strava uses on its Upgrade button. After the arc completes
/// one full rotation, the stroke fades out over ~0.4 s so the steady
/// state is just a calm tinted pill (no permanent moving border to
/// distract from the rest of the screen).
///
/// Implemented as a [CustomPainter] over a [SweepGradient] shader so the
/// effect costs one repaint per frame for ~1.6 s and zero after that.
class _BuyXpCta extends ConsumerStatefulWidget {
  const _BuyXpCta();

  @override
  ConsumerState<_BuyXpCta> createState() => _BuyXpCtaState();
}

class _BuyXpCtaState extends ConsumerState<_BuyXpCta>
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
    _controller = AnimationController(
      vsync: this,
      duration: _totalDuration,
    );
    // First run on mount (cold app launch + Home is the initial tab).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.forward(from: 0);
    });
    // The indexedStack shell keeps HomeScreen alive across tab switches,
    // so initState only fires once per session. Subsequent visits to
    // the Home tab tick `homeTabFocusTickProvider` (see MainShell) and
    // we replay the sweep here.
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
              // Longer pill: extra horizontal padding makes it read
              // as a stadium, vertical stays compact so the AppBar
              // doesn't grow.
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
/// then fades the whole stroke to invisible. The "arc" is just a narrow
/// bright band in a [SweepGradient] whose angle is offset by
/// `rotationProgress * 2π` each frame.
class _SweepBorderPainter extends CustomPainter {
  /// 0..1 controller value covering both phases.
  final double progress;
  /// Fraction of [progress] dedicated to the sweep; the remainder is the
  /// fade-out.
  final double sweepEnds;
  /// Brand violet — the base / tail colour of the gradient.
  final Color color;
  /// Brighter violet at the centre of the bright arc.
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
    final rotation = inFade
        ? 1.0
        : (progress / sweepEnds).clamp(0.0, 1.0);
    final fadeAlpha = inFade
        ? 1.0 - ((progress - sweepEnds) / (1 - sweepEnds)).clamp(0.0, 1.0)
        : 1.0;

    final rect = Offset.zero & size;
    final radius = size.height / 2;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(0.5),
      Radius.circular(radius),
    );

    // The sweep angle = -π/2 puts the start at 12 o'clock so the bright
    // band emerges from the top centre on the first frame, which reads
    // most naturally as "the button is about to glow".
    final start = -math.pi / 2 + (rotation * 2 * math.pi);
    final shader = SweepGradient(
      center: Alignment.center,
      startAngle: 0,
      endAngle: 2 * math.pi,
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

class _BellButton extends StatelessWidget {
  final int unreadCount;
  const _BellButton({required this.unreadCount});

  @override
  Widget build(BuildContext context) {
    // Pull surface + on-surface colours from Theme so this widget is
    // subscribed to the InheritedWidget — without that dependency, the
    // bell's background was reading a stale value from the static
    // AppColors getter on theme toggle and only updated after the next
    // touch event jolted a rebuild.
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        useRootNavigator: true,
        backgroundColor: Colors.transparent,
        builder: (_) => const NotificationsSheet(),
      ),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(Icons.notifications_outlined,
                color: scheme.onSurface, size: 20),
            if (unreadCount > 0)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  constraints:
                      const BoxConstraints(minWidth: 16, minHeight: 16),
                  decoration: BoxDecoration(
                    color: scheme.error,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: scheme.surface, width: 1.5),
                  ),
                  child: Text(
                    unreadCount > 9 ? '9+' : '$unreadCount',
                    style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _HomeBody extends StatelessWidget {
  const _HomeBody();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 120),
      children: const [
        // Auto-diagnostic banner — only renders when every step source
        // has been failing/empty for 10+ minutes. Self-suppressing if
        // dismissed or once steps start flowing.
        NoStepsBanner(),

        // Streak strip — flame chip + swipeable week PageView. Tapping
        // a past day opens the per-date Day Summary.
        StreakStrip(),
        SizedBox(height: 28),

        // Section 1: Overview card + stat pills
        OverviewCard(),
        SizedBox(height: 12),
        StatPillsRow(),

        SizedBox(height: 32),

        // Section 2: Active Battle
        ActiveBattleCard(),

        SizedBox(height: 32),

        // Today's track session (only renders when the user has a
        // qualifying run/walk from today — see TodaysSessionCard for
        // the show criteria). Self-hides via SizedBox.shrink when
        // there's nothing to show, so it doesn't add a phantom gap
        // on days without a session.
        TodaysSessionCard(),

        // Section 3: Today's mission — the personalized step target
        // (replaces the old multi-row daily missions list).
        DailyTargetCard(),

        SizedBox(height: 32),

        // Section 4: Map preview
        MapPreviewCard(),
      ],
    );
  }
}
