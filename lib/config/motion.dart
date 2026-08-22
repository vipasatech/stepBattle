import 'package:flutter/widgets.dart';

/// Motion design tokens — the single source of truth for every duration,
/// curve, and stagger interval in StepBattle.
///
/// Rules:
///   1. Never write `Duration(milliseconds: X)` inline in a widget. Pick
///      a token from [Motion.d] (durations) or [Motion.stagger].
///   2. Never write `Curves.easeOut` inline. Pick from [Motion.curves].
///   3. When you need a new duration / curve that isn't here, add it
///      here first and reference it — don't fork the system.
///
/// The tokens follow Material 3's motion spec (short → xslong) with
/// StepBattle-specific tuning:
///   • Fast surfaces (chip presses, toggle flips) use [d.fast].
///   • Base transitions (route changes, sheet opens) use [d.base].
///   • Celebrations (level-up, streak milestone, XP fly-in) use [d.slow]
///     or [d.xslow] so the user's eye can actually land on the effect.
///
/// Curves:
///   • [curves.standard] — the default. Ease-out with a soft landing;
///     works for 90 % of "thing appears" moments.
///   • [curves.emphasized] — sharper acceleration; use for user-initiated
///     transitions where feedback should feel snappy (button press,
///     tab switch).
///   • [curves.spring] — natural physics-y overshoot; use on celebration
///     moments (badge earn, level-up burst).
///   • [curves.decel] — slow start, fast end; use when leaving the
///     screen (dismiss, close).
///
/// Staggers are the inter-item delay when a list, grid, or card stack
/// animates in. Keeping the stagger set small means "premium" reads as
/// "fluid" not "slow".
class Motion {
  const Motion._();

  /// Duration tokens. Reference these instead of `Duration(...)`
  /// literals so app-wide motion can be retimed from one place.
  static const MotionDurations d = MotionDurations();

  /// Curve tokens.
  static const MotionCurves curves = MotionCurves();

  /// Stagger intervals between siblings in a list / grid / card stack.
  /// Small on purpose — even 100ms per row starts to feel sluggish on
  /// a 20-item list.
  static const MotionStaggers stagger = MotionStaggers();

  /// Returns [d] unless the user has enabled the OS "reduce motion"
  /// accessibility toggle — in that case returns [Duration.zero] so
  /// the animation resolves instantly. Every animation in the app
  /// should route its duration through this helper so accessibility
  /// preferences are honoured without per-widget branching.
  static Duration adaptDuration(BuildContext context, Duration d) {
    return MediaQuery.of(context).disableAnimations ? Duration.zero : d;
  }

  /// Two-phase spring bounce for scale animations driven by an
  /// [AnimationController] whose value ranges 0 → 1.
  ///
  /// Phase 1 (0 → 15%): fast linear rise from 1.0 to peak (1 + [amplitude]).
  /// Phase 2 (15% → 100%): elastic settle back to 1.0 with wobble.
  ///
  /// Replaces the old triangle-wave formula in streak celebrations
  /// (`1 + 0.35 * (1 - (t*2-1).abs())`) which had no overshoot on
  /// return and felt mechanical. Pair with [d.xslow] (620ms) so the
  /// elastic wobble has room to breathe.
  ///
  /// Reduced-motion note: caller should short-circuit by not running
  /// the controller at all (i.e., set displayScale = 1.0) when
  /// [MediaQuery.disableAnimations] is true; this helper is a pure
  /// math function and doesn't observe context.
  static double springBounce(double t, {double amplitude = 0.35}) {
    if (t <= 0 || t >= 1) return 1.0;
    if (t < 0.15) {
      return 1.0 + amplitude * (t / 0.15);
    }
    final u = (t - 0.15) / 0.85;
    final decay = Curves.elasticOut.transform(u); // 0 → 1 with overshoot
    return (1.0 + amplitude) - amplitude * decay;
  }
}

class MotionDurations {
  const MotionDurations();

  /// 120ms — micro-interactions (toggle flip, chip press, ripple echo).
  final Duration fast = const Duration(milliseconds: 120);

  /// 220ms — the workhorse. Route transitions, sheet opens, section
  /// swaps, most enter/exit choreography.
  final Duration base = const Duration(milliseconds: 220);

  /// 380ms — deliberate transitions where the user should notice the
  /// motion (dialog open, focus mode entry, hero image morphs).
  final Duration slow = const Duration(milliseconds: 380);

  /// 620ms — celebrations. Level-up, streak milestone, XP fly-in,
  /// battle-won burst. Anything longer feels indulgent.
  final Duration xslow = const Duration(milliseconds: 620);
}

class MotionCurves {
  const MotionCurves();

  /// Ease-out-cubic — soft landing, no overshoot. The safe default for
  /// "thing appears on screen".
  final Curve standard = Curves.easeOutCubic;

  /// Emphasized — snappier acceleration, quicker settle. Use when the
  /// user just did something and needs immediate feedback (tap → panel
  /// slides in).
  final Curve emphasized = Curves.easeOutQuint;

  /// Elastic spring — small overshoot, natural feel. Reserve for
  /// celebrations; overuse turns motion into noise.
  final Curve spring = const Cubic(0.34, 1.56, 0.64, 1.0);

  /// Decelerating exit — slow start, fast finish. The counterpart to
  /// [standard]; use on dismissals so exits don't feel like a hard cut.
  final Curve decel = Curves.easeInCubic;

  /// Linear — reserved for looping / continuous motion (progress bars
  /// during load, orbit animations). Do NOT use for one-shot effects.
  final Curve linear = Curves.linear;
}

class MotionStaggers {
  const MotionStaggers();

  /// 40ms — tight stagger for dense lists (leaderboard rows, chip rows).
  final Duration fast = const Duration(milliseconds: 40);

  /// 70ms — the default rhythm for card lists (Battles, Missions).
  final Duration base = const Duration(milliseconds: 70);

  /// 110ms — deliberate stagger for hero sequences (Home first mount,
  /// onboarding cards). Reserve for surfaces the user sees rarely.
  final Duration slow = const Duration(milliseconds: 110);
}
