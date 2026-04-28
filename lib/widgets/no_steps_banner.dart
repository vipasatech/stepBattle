import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../config/colors.dart';
import '../providers/step_provider.dart';
import '../services/step_source_aggregator.dart';

/// Auto-shows on the home screen when *every* step source has reported 0
/// (or errored) for a while — the most common signal that the user is on
/// an OEM whose Health Connect bridge isn't feeding us data.
///
/// The banner is the proactive equivalent of the user staring at "0 steps"
/// for an hour and wondering if the app is broken. Tap → opens the
/// step setup wizard / debug screen so they can fix it.
///
/// Trigger logic:
///   - Aggregate steps == 0
///   - AND any of:
///       * native source has an error AND HC has an error
///       * native source unavailable (permission denied, missing sensor)
///       * AND it's been at least 10 min since the app first read 0
///
/// We keep the threshold short (10 min) for first-launch users so they
/// don't have to wait an hour to see the diagnostic. Once the user has
/// dismissed the banner once, we suppress it for the rest of today.
class NoStepsBanner extends ConsumerStatefulWidget {
  const NoStepsBanner({super.key});

  @override
  ConsumerState<NoStepsBanner> createState() => _NoStepsBannerState();
}

class _NoStepsBannerState extends ConsumerState<NoStepsBanner> {
  StepReading? _reading;
  Timer? _timer;
  DateTime? _firstZeroAt;
  bool _dismissed = false;

  static const _showAfter = Duration(minutes: 10);

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final reading =
        await ref.read(stepAggregatorProvider).readWithDebug();
    if (!mounted) return;
    setState(() {
      _reading = reading;
      if (reading.aggregate == 0) {
        _firstZeroAt ??= DateTime.now();
      } else {
        _firstZeroAt = null;
      }
    });
  }

  bool get _shouldShow {
    if (_dismissed) return false;
    final r = _reading;
    if (r == null) return false;
    if (r.aggregate > 0) return false;
    final since = _firstZeroAt;
    if (since == null) return false;
    if (DateTime.now().difference(since) < _showAfter) return false;

    // Show only when at least one source is failing — pure 0s are
    // ambiguous (user might just not have walked yet today).
    final allErrored = (r.nativeError != null || !_hasNativeReading(r)) &&
        (r.healthConnectError != null || r.healthConnectSteps == 0);
    return allErrored;
  }

  /// Native source actively producing readings (vs. just stuck at 0).
  bool _hasNativeReading(StepReading r) {
    final native = ref.read(nativeStepServiceProvider);
    return native.isAvailable && r.nativeError == null;
  }

  @override
  Widget build(BuildContext context) {
    if (!_shouldShow) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => context.push('/profile/health-setup'),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.amber.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: AppColors.amber.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.amber.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.warning_amber,
                      color: AppColors.amber, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Steps not flowing',
                          style: theme.textTheme.titleSmall?.copyWith(
                              color: AppColors.amber,
                              fontWeight: FontWeight.w800)),
                      Text(
                        'Tap to fix step tracking on your device.',
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: AppColors.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  color: AppColors.onSurfaceVariant,
                  onPressed: () => setState(() => _dismissed = true),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
