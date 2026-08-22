import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../config/colors.dart';
import '../../providers/step_provider.dart';
import '../../services/step_source_aggregator.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/shimmer_loader.dart';

/// Diagnostic screen for the step ingestion pipeline.
///
/// Shows each source's live value side-by-side so users (and us) can see
/// when one source is empty/stale. Useful for debugging the OEM
/// fragmentation problem — at a glance you can tell whether HC has a
/// feeder app pushing to it, and how stale it is vs. the hardware sensor.
class StepSourcesScreen extends ConsumerStatefulWidget {
  const StepSourcesScreen({super.key});

  @override
  ConsumerState<StepSourcesScreen> createState() => _StepSourcesScreenState();
}

class _StepSourcesScreenState extends ConsumerState<StepSourcesScreen> {
  StepReading? _reading;
  Timer? _timer;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _refresh();
    // Auto-refresh every 5s while screen is open.
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final reading =
        await ref.read(stepAggregatorProvider).readWithDebug();
    if (!mounted) return;
    setState(() {
      _reading = reading;
      _refreshing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reading = _reading;
    final native = ref.read(nativeStepServiceProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: Text('Step Sources',
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: reading == null
          ? ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: const [
                ShimmerLoader(height: 96, borderRadius: 20),
                SizedBox(height: 12),
                ShimmerCard(),
                SizedBox(height: 12),
                ShimmerCard(),
              ],
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              children: [
                _AggregateCard(reading: reading),
                const SizedBox(height: 20),
                _SourceCard(
                  title: 'Hardware Pedometer',
                  subtitle:
                      'Reads TYPE_STEP_COUNTER directly from the device sensor.',
                  steps: reading.nativeSteps,
                  latency: reading.nativeLatency,
                  error: reading.nativeError,
                  isWinner:
                      reading.aggregate == reading.nativeSteps &&
                          reading.nativeSteps > 0,
                ),
                const SizedBox(height: 12),
                _SourceCard(
                  title: 'Health Connect',
                  subtitle:
                      'Read from Health Connect. Requires an OEM app (Samsung Health, Mi Fitness, Google Fit) pushing data into it.',
                  steps: reading.healthConnectSteps,
                  latency: reading.healthConnectLatency,
                  error: reading.healthConnectError,
                  isWinner: reading.aggregate ==
                          reading.healthConnectSteps &&
                      reading.healthConnectSteps > 0,
                ),
                const SizedBox(height: 12),
                _GoogleFitCard(
                  reading: reading,
                  onToggleChanged: _refresh,
                ),
                const SizedBox(height: 24),
                _NativeInternals(snapshot: native.debugSnapshot()),
                const SizedBox(height: 12),
                Text(
                  'Auto-refreshes every 5 seconds. The aggregate is max(sources) — never a sum, since both sources read the same hardware counter.',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.onSurfaceVariant, height: 1.4),
                ),
              ],
            ),
    );
  }
}

// =============================================================================
// Aggregate hero card
// =============================================================================
class _AggregateCard extends StatelessWidget {
  final StepReading reading;
  const _AggregateCard({required this.reading});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('AGGREGATE',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                letterSpacing: 2,
              )),
          const SizedBox(height: 6),
          Text(
            _fmt(reading.aggregate),
            style: theme.textTheme.displaySmall?.copyWith(
              color: AppColors.primary,
              fontWeight: FontWeight.w900,
            ),
          ),
          Text('steps today',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppColors.onSurfaceVariant)),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(Icons.info_outline,
                  size: 14, color: AppColors.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Whichever source is highest wins. Sources read the same chip, so we never sum them.',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.onSurfaceVariant, height: 1.4),
                ),
              ),
            ],
          ),
        ],
      ),
    );
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
// Per-source card
// =============================================================================
class _SourceCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final int steps;
  final Duration latency;
  final String? error;
  final bool isWinner;

  const _SourceCard({
    required this.title,
    required this.subtitle,
    required this.steps,
    required this.latency,
    required this.error,
    required this.isWinner,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok = error == null && steps >= 0;
    final accent = isWinner
        ? AppColors.primary
        : (ok ? AppColors.onSurface : AppColors.error);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isWinner
              ? AppColors.primary.withValues(alpha: 0.4)
              : AppColors.onSurface.withValues(alpha: 0.06),
          width: isWinner ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700, color: accent)),
              ),
              if (isWinner)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('WINNING',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w900,
                        fontSize: 9,
                        letterSpacing: 1.2,
                      )),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(subtitle,
              style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.onSurfaceVariant, height: 1.4)),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(_fmt(steps),
                  style: theme.textTheme.headlineSmall?.copyWith(
                      color: accent, fontWeight: FontWeight.w900)),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('steps',
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.onSurfaceVariant)),
              ),
              const Spacer(),
              Text('${latency.inMilliseconds}ms',
                  style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.onSurfaceVariant)),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: AppColors.error.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline,
                      size: 14, color: AppColors.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(error!,
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: AppColors.error)),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
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
// Google Fit card with toggle (opt-in OAuth scope)
// =============================================================================
class _GoogleFitCard extends ConsumerStatefulWidget {
  final StepReading reading;
  final VoidCallback onToggleChanged;
  const _GoogleFitCard({
    required this.reading,
    required this.onToggleChanged,
  });

  @override
  ConsumerState<_GoogleFitCard> createState() => _GoogleFitCardState();
}

class _GoogleFitCardState extends ConsumerState<_GoogleFitCard> {
  // Toggle handler + _busy state were retired in 1.1.6+28 when the
  // Fit REST API deprecation forced the switch to a permanently-off
  // state (see build() below — Switch.onChanged is null). No path
  // enables Fit anymore, so no async work is needed. If Google ever
  // revives the REST API OR we add a client-library alternative,
  // restore _toggle + _busy here.

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fit = ref.watch(googleFitServiceProvider);
    final reading = widget.reading;
    final enabled = fit.isEnabled;
    final wasAutoDisabled = fit.wasAutoDisabledDueToDeprecation;
    final fitSteps = reading.googleFitSteps;
    final isWinner = enabled &&
        fitSteps != null &&
        reading.aggregate == fitSteps &&
        fitSteps > 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isWinner
              ? AppColors.primary.withValues(alpha: 0.4)
              : AppColors.onSurface.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Google Fit',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
              ),
              // Toggle is disabled unconditionally in 1.1.6+28 because
              // Google retired the Fit REST API on 2026-06-30 — every
              // call now 403s. The service auto-disables on 403 to
              // stop hammering the dead endpoint; disabling the switch
              // in the UI too prevents users from pointlessly re-
              // enabling it. When Google re-opens or an alternative
              // client library comes along, we'll remove this gate
              // and restore the previous _toggle handler.
              Switch(
                value: enabled,
                onChanged: null,
                activeColor: AppColors.primary,
              ),
            ],
          ),
          Text(
            'Retired by Google on 30 Jun 2026. Use Health Connect '
            '(the app up top) as your step source instead.',
            style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant, height: 1.4),
          ),
          if (wasAutoDisabled) ...[
            const SizedBox(height: 10),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.amber.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: AppColors.amber.withValues(alpha: 0.35)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline,
                      size: 16, color: AppColors.amber),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "We turned this off automatically because Google "
                      "Fit's API stopped responding (403). Health "
                      "Connect (up top) is now the recommended source.",
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.onSurface,
                        height: 1.4,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () async {
                      await ref
                          .read(googleFitServiceProvider)
                          .acknowledgeDeprecationBanner();
                      if (mounted) setState(() {});
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        'Got it',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (enabled) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                    fitSteps == null
                        ? '—'
                        : _fmtInt(fitSteps),
                    style: theme.textTheme.headlineSmall?.copyWith(
                        color: isWinner
                            ? AppColors.primary
                            : AppColors.onSurface,
                        fontWeight: FontWeight.w900)),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('steps',
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.onSurfaceVariant)),
                ),
                const Spacer(),
                Text('${reading.googleFitLatency.inMilliseconds}ms',
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.onSurfaceVariant)),
              ],
            ),
            if (reading.googleFitError != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: AppColors.error.withValues(alpha: 0.2)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline,
                        size: 14, color: AppColors.error),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(reading.googleFitError!,
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: AppColors.error)),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  static String _fmtInt(int n) {
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
// Internal state of the native tracker (for support / debugging reboot bugs)
// =============================================================================
class _NativeInternals extends StatelessWidget {
  final Map<String, Object?> snapshot;
  const _NativeInternals({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = snapshot.entries.toList();
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.onSurface.withValues(alpha: 0.04)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Native tracker internals',
              style: theme.textTheme.labelMedium?.copyWith(
                  color: AppColors.onSurface,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (final e in entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 130,
                    child: Text(e.key,
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: AppColors.onSurfaceVariant,
                            fontFamily: 'monospace')),
                  ),
                  Expanded(
                    child: Text('${e.value ?? "—"}',
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: AppColors.onSurface,
                            fontFamily: 'monospace')),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
