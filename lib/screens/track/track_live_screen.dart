import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

import '../../config/colors.dart';
import '../../models/run_session_model.dart';
import '../../providers/run_session_provider.dart';
import '../../services/run_tracking_service.dart';

/// Live-recording screen for a Track session.
/// Three progress rings (distance / time / calories vs arbitrary v1 targets),
/// a map of the GPS path, and a big End button. When the session ends we pop
/// back to the Track hub. The session continues running in the background
/// even if the user closes this screen — the FAB reflects that.
class TrackLiveScreen extends ConsumerStatefulWidget {
  const TrackLiveScreen({super.key});

  @override
  ConsumerState<TrackLiveScreen> createState() => _TrackLiveScreenState();
}

class _TrackLiveScreenState extends ConsumerState<TrackLiveScreen> {
  // Arbitrary in-session targets; per-user goals come later.
  static const double _distanceTargetM = 5000;
  static const int _durationTargetSec = 60 * 60; // 1h
  static const int _caloriesTarget = 500;

  final MapController _map = MapController();

  /// Open a small dialog to set/clear the in-flight session name. Blank
  /// trim → resets to "no name set" (will auto-default to "Run · MMM d,
  /// h:mm a" on save).
  Future<void> _editName(String? current) async {
    final controller = TextEditingController(text: current ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Name this run'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 50,
          decoration: const InputDecoration(
            hintText: 'e.g. Morning park loop',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            // Returning the text (even empty) signals "user clicked Save".
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null) return; // user cancelled
    ref.read(runTrackingServiceProvider).setName(result);
  }

  /// "End run" now opens the Save Activity page instead of an inline
  /// confirm dialog. The save page lets the runner caption the session
  /// and attach up to 5 photos before the row hits the server — and
  /// "Resume" there pops them back here with the session still alive.
  void _confirmEnd() {
    context.push('/track/save');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sessionAsync = ref.watch(activeRunSessionProvider);
    final session = sessionAsync.valueOrNull;

    if (session == null && !isTrackActiveFromHive()) {
      // No active session — bounce back to hub.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go('/track');
      });
      return const Scaffold(body: SizedBox.shrink());
    }

    final duration = session?.durationSeconds ?? 0;
    final distance = session?.distanceMeters ?? 0;
    final steps = session?.steps ?? 0;
    final kcal = session?.calories ?? 0;
    final pace = session?.avgPaceSecPerKm;
    // Pill colour + label come from the live trust state, not just source.
    // `state` is `_TrackState.name`, e.g. 'gpsSteady' (camelCase) — the
    // previous switch used snake_case keys and silently fell through to
    // INDOOR for every actual outdoor state, which is why "INDOOR" was
    // showing while the map clearly had a GPS track.
    final state = session?.trackState ?? 'indoor';
    final (pillLabel, pillColor) = switch (state) {
      'gpsSteady' => ('GPS · STEADY', AppColors.success),
      'gpsStationary' => ('GPS · STATIONARY', AppColors.amber),
      'estimated' => ('ESTIMATED', AppColors.amber),
      _ => ('INDOOR', AppColors.onSurfaceVariant),
    };

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Live Track'),
        leading: IconButton(
          icon: const Icon(Icons.expand_more),
          tooltip: 'Hide (session keeps running)',
          onPressed: () => context.go('/home'),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: pillColor.withValues(alpha: 0.20),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  pillLabel,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: pillColor,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 8),
            // Tappable name strip — either the user-set name or a "tap to name"
            // placeholder. Updates the in-flight session in memory; persisted
            // by end() to the DB column.
            InkWell(
              onTap: () => _editName(session?.name),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        (session?.name?.trim().isNotEmpty ?? false)
                            ? session!.name!
                            : 'Untitled run · tap to name',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: (session?.name?.trim().isNotEmpty ?? false)
                              ? AppColors.onSurface
                              : AppColors.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(Icons.edit,
                        size: 14, color: AppColors.onSurfaceVariant),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            // Big timer.
            Text(
              _formatDuration(duration),
              style: theme.textTheme.displayLarge?.copyWith(
                fontSize: 56,
                fontWeight: FontWeight.w700,
                color: AppColors.onSurface,
              ),
            ),
            Text('DURATION',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.onSurfaceVariant,
                  letterSpacing: 3,
                )),
            const SizedBox(height: 18),

            // Three progress rings.
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _RingStat(
                  progress: (distance / _distanceTargetM).clamp(0, 1).toDouble(),
                  value: (distance / 1000).toStringAsFixed(2),
                  unit: 'km',
                  label: 'Distance',
                  color: AppColors.primary,
                ),
                _RingStat(
                  progress:
                      (duration / _durationTargetSec).clamp(0, 1).toDouble(),
                  value: steps.toString(),
                  unit: 'steps',
                  label: 'Steps',
                  color: AppColors.success,
                ),
                _RingStat(
                  progress: (kcal / _caloriesTarget).clamp(0, 1).toDouble(),
                  value: kcal.toString(),
                  unit: 'kcal',
                  label: 'Calories',
                  color: AppColors.amber,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (pace != null)
              Text(
                '${_formatPace(pace)} /km avg',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppColors.onSurfaceVariant,
                ),
              ),

            const SizedBox(height: 12),

            // Map.
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: _buildMap(session),
                ),
              ),
            ),

            // End button.
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _confirmEnd,
                  icon: const Icon(Icons.stop_circle),
                  label: const Text('End run'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.error,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMap(RunSession? session) {
    final points = session?.path ?? const <RunPoint>[];
    final hasAnyFix = points.isNotEmpty;
    final hasPolyline = points.length >= 2;
    final center = hasAnyFix
        ? LatLng(points.last.lat, points.last.lng)
        : const LatLng(0, 0);
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: center,
        initialZoom: hasAnyFix ? 16 : 2,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
        ),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.stepbattle.stepbattle',
        ),
        if (hasPolyline)
          PolylineLayer(
            polylines: [
              Polyline(
                points: points
                    .map((p) => LatLng(p.lat, p.lng))
                    .toList(growable: false),
                strokeWidth: 5,
                color: AppColors.primary,
              ),
            ],
          ),
        // Drop a marker for the latest fix even if it's the only one — gives
        // the user immediate visual confirmation GPS produced something.
        if (hasAnyFix)
          MarkerLayer(
            markers: [
              Marker(
                point: LatLng(points.last.lat, points.last.lng),
                width: 18,
                height: 18,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                  ),
                ),
              ),
            ],
          ),
        if (!hasAnyFix)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Searching for GPS… recording with pedometer in the meantime.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
      ],
    );
  }

  static String _formatDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    if (h > 0) return '${two(h)}:${two(m)}:${two(s)}';
    return '${two(m)}:${two(s)}';
  }

  static String _formatPace(double secPerKm) {
    final m = secPerKm ~/ 60;
    final s = (secPerKm % 60).round();
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

class _RingStat extends StatelessWidget {
  final double progress;
  final String value;
  final String unit;
  final String label;
  final Color color;

  const _RingStat({
    required this.progress,
    required this.value,
    required this.unit,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        SizedBox(
          width: 92,
          height: 92,
          child: CustomPaint(
            painter: _RingPainter(progress: progress, color: color),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(value,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppColors.onSurface,
                      )),
                  Text(unit,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.onSurfaceVariant,
                      )),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppColors.onSurfaceVariant,
              letterSpacing: 1.2,
            )),
      ],
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  final Color color;

  _RingPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = 8.0;
    final rect = Rect.fromLTWH(
      stroke / 2,
      stroke / 2,
      size.width - stroke,
      size.height - stroke,
    );
    final track = Paint()
      ..color = color.withValues(alpha: 0.18)
      ..strokeWidth = stroke
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final fill = Paint()
      ..color = color
      ..strokeWidth = stroke
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    // Background track (full circle).
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2, false, track);
    // Progress arc.
    final sweep = math.pi * 2 * progress.clamp(0.0, 1.0);
    if (sweep > 0) {
      canvas.drawArc(rect, -math.pi / 2, sweep, false, fill);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.color != color;
}
