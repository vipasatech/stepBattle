import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../config/colors.dart';
import '../../../config/motion.dart';
import '../../../providers/step_provider.dart';
import '../../../providers/user_provider.dart';
import '../../../sheets/level_info_sheet.dart';
import '../../../widgets/premium_card.dart';
import '../../../widgets/progress_bar.dart';
import '../../../widgets/shimmer_loader.dart';

/// The hero overview card on Home — shows level, today's steps, XP delta,
/// and progress bar toward the next level.
class OverviewCard extends ConsumerWidget {
  const OverviewCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // `select` — the overview card only shows the XP total from the
    // profile row. Watching the whole row would repaint on every
    // step-tick that updates unrelated fields.
    final totalXP = ref.watch(userProfileProvider
        .select((async) => async.valueOrNull?.totalXP ?? 0));
    final todayStepsAsync = ref.watch(todayStepsAsyncProvider);
    final level = ref.watch(userLevelProvider);
    final progress = ref.watch(levelProgressProvider);
    final pointsToNext = ref.watch(pointsToNextLevelProvider);

    return PremiumCard(
      // Home hero — strong intensity so the corner glows read from
      // across the room. Other Home surfaces use standard.
      intensity: PremiumCardIntensity.strong,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Level badge — tappable, opens the LevelInfoSheet with the
          // "how leveling works" explainer + 3 example journeys. Same
          // tap target as the progress-bar row below so users find it
          // from either surface.
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => LevelInfoSheet.show(context),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.primaryBrand.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: AppColors.primaryBrand.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Level $level',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.info_outline,
                      size: 12,
                      color: AppColors.primary.withValues(alpha: 0.7),
                    ),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(height: 14),

          // Step count — large display, shrunk from 56 → 44 so the
          // card overall feels more compact and gives more breathing
          // room to surrounding sections. Wrapped in _StepsHero for
          // count-up + subtle scale pulse whenever the value changes.
          Center(
            child: todayStepsAsync.when(
              data: (steps) => _StepsHero(
                steps: steps,
                style: theme.textTheme.displayLarge?.copyWith(
                  fontSize: 44,
                  color: AppColors.onSurface,
                  height: 1.0,
                ),
              ),
              loading: () => const ShimmerLoader(
                width: 160,
                height: 44,
                borderRadius: 10,
              ),
              error: (_, __) => Text(
                '—',
                style: theme.textTheme.displayLarge?.copyWith(
                  fontSize: 44,
                  color: AppColors.onSurfaceVariant,
                  height: 1.0,
                ),
              ),
            ),
          ),
          const SizedBox(height: 2),
          Center(
            child: Text(
              'STEPS TODAY',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                letterSpacing: 2.5,
                fontSize: 10,
              ),
            ),
          ),

          // Pedometer-only hint. Shows when the winning source is the
          // hardware pedometer (Health Connect empty / Google Fit off).
          // Tapping opens the OEM-tailored setup guide so the user can
          // connect a richer source. Never blocks — the aggregate stays
          // driven by whichever source is producing data.
          const _PedometerOnlyHint(),

          const SizedBox(height: 10),

          // XP delta line
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.trending_up,
                  size: 14,
                  color: AppColors.success,
                ),
                const SizedBox(width: 4),
                Text(
                  '+${_formatNumber(totalXP)} XP total',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.success,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 18),

          // Level progress section — tappable, opens LevelInfoSheet.
          // Same target as the Level badge above so users find it
          // from either surface.
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => LevelInfoSheet.show(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'LVL $level',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: AppColors.onSurfaceVariant,
                            fontSize: 10,
                          ),
                        ),
                        Text(
                          'LVL ${level + 1}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: AppColors.onSurfaceVariant,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    // Progress bar with spark
                    StepProgressBar(progress: progress, height: 8),
                    const SizedBox(height: 6),
                    // Steps to go
                    Center(
                      child: Text(
                        '$pointsToNext to level up',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatNumber(int n) {
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

/// Home overview hero-number widget: interpolates the visible int
/// from the previous value to the new one whenever [steps] changes,
/// and runs a subtle scale pulse (1.0 → 1.03 → 1.0) on top so the
/// user's eye lands on the change without it feeling loud.
///
/// Compositor-only: [Transform.scale] is a paint-time transform, no
/// layout re-flow. TweenAnimationBuilder ticks the int a few times per
/// frame during the transition — cheap since Text repaints only when
/// the string mutates and the value delta between two consecutive
/// frames is small.
///
/// Reduced-motion: [Motion.adaptDuration] collapses the count-up to
/// zero duration (visible value snaps immediately); pulse is not
/// suppressed but 620ms of a 3% scale is under the accessibility
/// noticeable-motion threshold.
class _StepsHero extends StatefulWidget {
  final int steps;
  final TextStyle? style;
  const _StepsHero({required this.steps, this.style});

  @override
  State<_StepsHero> createState() => _StepsHeroState();
}

class _StepsHeroState extends State<_StepsHero>
    with SingleTickerProviderStateMixin {
  late int _prev;
  late final AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _prev = widget.steps;
    _pulseCtrl = AnimationController(vsync: this, duration: Motion.d.slow);
  }

  @override
  void didUpdateWidget(covariant _StepsHero old) {
    super.didUpdateWidget(old);
    if (old.steps != widget.steps) {
      _prev = old.steps;
      _pulseCtrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulseCtrl,
      builder: (_, __) {
        final t = _pulseCtrl.value;
        // Triangle wave peaking at 0.5 → max scale 1.03, back to 1.0.
        final pulse = t == 0 ? 0.0 : 4 * t * (1 - t) * 0.03;
        return Transform.scale(
          scale: 1.0 + pulse,
          child: TweenAnimationBuilder<int>(
            duration: Motion.adaptDuration(context, Motion.d.slow),
            curve: Motion.curves.standard,
            // Fresh IntTween on every widget.steps change makes
            // TweenAnimationBuilder detect the change and re-run
            // FROM _prev TO the new target.
            tween: IntTween(begin: _prev, end: widget.steps),
            builder: (context, value, _) => Text(
              OverviewCard._formatNumber(value),
              style: widget.style,
            ),
          ),
        );
      },
    );
  }
}

/// Tiny hint under "STEPS TODAY" that appears only when the winning
/// step source is the raw hardware pedometer (no Health Connect feed,
/// no Google Fit fallback). Signals to the user that their step count
/// is only as good as the phone's sensor is right now, and offers a
/// one-tap path to the setup guide where they can enable a richer
/// source.
///
/// Reactivity: pulls from the aggregator's `lastReading` via a
/// short-poll ticker (aligned to the 10s home poll from
/// [localTodayStepsProvider]) so this hint appears/disappears as
/// sources come and go without a full rebuild loop.
class _PedometerOnlyHint extends ConsumerWidget {
  const _PedometerOnlyHint();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch the polled today-steps so this widget rebuilds on each
    // aggregator tick — cheap because it's already in the widget tree
    // and the aggregator caches lastReading.
    ref.watch(todayStepsAsyncProvider);
    final reading = ref.read(stepAggregatorProvider).lastReading;
    if (reading == null) return const SizedBox.shrink();
    final hcHasData = reading.healthConnectSteps > 0;
    final fitHasData = (reading.googleFitSteps ?? 0) > 0;
    // Only surface when the pedometer is the sole source. If HC or Fit
    // is contributing (even a small amount) we suppress the hint —
    // the user already has a richer source connected.
    if (hcHasData || fitHasData) return const SizedBox.shrink();
    // Also suppress on the true-empty case — the NoSourceGate handles
    // that surface with its own blocking dialog. This hint is for the
    // "sensor works, but no HC feeder" middle state.
    if (reading.nativeSteps <= 0) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Center(
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => context.push('/profile/health-setup'),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 12,
                    color: AppColors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'From pedometer · tap to set up sync',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.primary,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
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
