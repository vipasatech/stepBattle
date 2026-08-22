import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../config/colors.dart';
import '../../../providers/step_provider.dart';
import '../../../utils/hive_lifecycle.dart';

/// Prominent Home-tab card that nudges pedometer-only users to connect
/// Health Connect (or Google Fit) so we get EXACT hourly step history
/// instead of the time-proportional estimation the pedometer-only
/// backfill produces when the app is closed.
///
/// Show conditions (all must be true):
///   • Pedometer is producing steps (native sensor available)
///   • Neither Health Connect nor Google Fit is contributing data
///   • User hasn't dismissed the card within the last [_dismissTtlDays]
///
/// Dismissal is stored in the shared Hive box as a millisecond
/// timestamp. On expiry the card reappears — persistent nudge without
/// being obnoxious.
class HealthSyncNudgeCard extends ConsumerWidget {
  const HealthSyncNudgeCard({super.key});

  static const String _dismissKey = 'nudge_hc_dismissed_at_ms';
  static const int _dismissTtlDays = 7;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Rebuild when the aggregator ticks so the card appears / disappears
    // as sources come online.
    ref.watch(todayStepsAsyncProvider);
    final reading = ref.read(stepAggregatorProvider).lastReading;
    if (reading == null) return const SizedBox.shrink();

    final hcHasData = reading.healthConnectSteps > 0;
    final fitHasData = (reading.googleFitSteps ?? 0) > 0;
    // Suppress when a richer source is already contributing — user is
    // already getting exact tracking, no nudge needed.
    if (hcHasData || fitHasData) return const SizedBox.shrink();
    // Suppress when the pedometer itself hasn't produced any reading —
    // that's the true-empty state that NoSourceGate handles as a
    // blocking modal. This nudge is for the "pedometer works but no
    // HC feeder" middle state.
    if (reading.nativeSteps <= 0) return const SizedBox.shrink();
    // Suppress when the user dismissed recently.
    if (_recentlyDismissed()) return const SizedBox.shrink();

    return _NudgeCard(
      onSetUp: () => context.push('/profile/health-setup'),
      onDismiss: () => _markDismissed(),
    );
  }

  bool _recentlyDismissed() {
    final box = safeSharedBox();
    if (box == null) return false;
    final ms = box.get(_dismissKey);
    if (ms is! int) return false;
    final elapsedDays =
        (DateTime.now().millisecondsSinceEpoch - ms) / (86400 * 1000);
    return elapsedDays < _dismissTtlDays;
  }

  void _markDismissed() {
    final box = safeSharedBox();
    if (box == null) return;
    box.put(_dismissKey, DateTime.now().millisecondsSinceEpoch);
  }
}

/// The actual card visual — separated so the outer widget stays a
/// pure ConsumerWidget without setState churn. Rebuilds via the
/// Riverpod invalidation on dismiss (parent's rebuild path).
class _NudgeCard extends StatefulWidget {
  final VoidCallback onSetUp;
  final VoidCallback onDismiss;
  const _NudgeCard({required this.onSetUp, required this.onDismiss});

  @override
  State<_NudgeCard> createState() => _NudgeCardState();
}

class _NudgeCardState extends State<_NudgeCard> {
  bool _hidden = false;

  @override
  Widget build(BuildContext context) {
    if (_hidden) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.primary.withValues(alpha: 0.14),
              AppColors.primary.withValues(alpha: 0.04),
            ],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: AppColors.primary.withValues(alpha: 0.30),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.20),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.favorite_outline,
                  color: AppColors.primary,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Get exact step tracking',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppColors.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Connect Health Connect for precise history — even when the app is closed.',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.onSurfaceVariant,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: widget.onSetUp,
                      behavior: HitTestBehavior.opaque,
                      child: Row(
                        children: [
                          Text(
                            'Connect →',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                iconSize: 18,
                padding: const EdgeInsets.all(6),
                constraints: const BoxConstraints(),
                onPressed: () {
                  widget.onDismiss();
                  setState(() => _hidden = true);
                },
                icon: Icon(
                  Icons.close,
                  color: AppColors.onSurfaceVariant.withValues(alpha: 0.7),
                ),
                tooltip: 'Dismiss for a week',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
