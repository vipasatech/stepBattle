import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../../config/colors.dart';
import '../../models/run_session_model.dart';
import '../../providers/run_session_provider.dart';

/// Read-only detail view for a saved Track session. Reached from the tap on
/// a tile in the Hub's "Recent sessions" list. Renders the run's name +
/// stats grid + GPS path map, plus a Rename and Delete action.
class TrackSessionDetailScreen extends ConsumerWidget {
  final String sessionId;

  const TrackSessionDetailScreen({super.key, required this.sessionId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final sessionAsync =
        ref.watch(trackSessionByIdProvider(sessionId));

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Session'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/track'),
        ),
        actions: [
          sessionAsync.when(
            data: (s) => s == null
                ? const SizedBox.shrink()
                : Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: 'Rename',
                        onPressed: () => _rename(context, ref, s),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline,
                            color: AppColors.error),
                        tooltip: 'Delete',
                        onPressed: () => _confirmDelete(context, ref, s),
                      ),
                      const SizedBox(width: 4),
                    ],
                  ),
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
        ],
      ),
      body: sessionAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Could not load this session.\n$e',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            ),
          ),
        ),
        data: (session) {
          if (session == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'This session no longer exists.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: AppColors.onSurfaceVariant,
                  ),
                ),
              ),
            );
          }
          return _SessionDetailBody(session: session);
        },
      ),
    );
  }

  Future<void> _rename(
      BuildContext context, WidgetRef ref, RunSession session) async {
    final controller =
        TextEditingController(text: session.name?.trim() ?? '');
    final result = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename run'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 50,
          decoration: const InputDecoration(
            hintText: 'Leave blank to reset to default',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null) return;
    final ok = await ref.read(runTrackingServiceProvider).renameSession(
          sessionId: session.id,
          newName: result,
          startedAtForFallback: session.startedAt,
        );
    if (!context.mounted) return;
    if (ok) {
      // Force the detail + history list to refetch.
      ref.invalidate(trackSessionByIdProvider(session.id));
      ref.invalidate(runSessionHistoryProvider);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Rename failed. Try again.')),
      );
    }
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, RunSession session) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this run?'),
        content: const Text(
          'This permanently removes the session and its route from your '
          'history. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final done =
        await ref.read(runTrackingServiceProvider).deleteSession(session.id);
    if (!context.mounted) return;
    if (done) {
      ref.invalidate(runSessionHistoryProvider);
      context.go('/track');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Delete failed. Try again.')),
      );
    }
  }
}

class _SessionDetailBody extends StatelessWidget {
  final RunSession session;
  const _SessionDetailBody({required this.session});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final km = session.distanceMeters / 1000;
    final dur = _formatDuration(session.durationSeconds);
    final whenStr =
        DateFormat('EEEE, MMM d • h:mm a').format(session.startedAt.toLocal());
    final pace = session.avgPaceSecPerKm;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
      children: [
        // Title block.
        Text(
          session.displayName,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          whenStr,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: AppColors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 18),

        // Stat grid (2x3).
        _StatGrid(
          tiles: [
            _Stat(label: 'Distance', value: km.toStringAsFixed(2), unit: 'km'),
            _Stat(label: 'Duration', value: dur, unit: ''),
            _Stat(label: 'Steps', value: session.steps.toString(), unit: ''),
            _Stat(
                label: 'Calories',
                value: session.calories.toString(),
                unit: 'kcal'),
            _Stat(
              label: 'Avg pace',
              value: pace == null ? '—' : _formatPace(pace),
              unit: pace == null ? '' : '/km',
            ),
            _Stat(
              label: 'Source',
              value: session.source.toUpperCase(),
              unit: '',
            ),
          ],
        ),

        // Honest disclosure notes — only render when there's something to say.
        // Shake-in-hand without GPS confirmation? Tunnel section? Indoor?
        // Pulled straight from the saved row's split-distance columns.
        if (session.distanceMetersEstimated > 0 || session.unverifiedSteps > 0)
          const SizedBox(height: 14),
        if (session.distanceMetersEstimated > 0)
          _DisclosureNote(
            icon: Icons.timeline,
            text: session.distanceMetersVerified > 0
                ? '${session.distanceMetersEstimated.round()} m estimated from '
                    'steps during a GPS gap.'
                : 'Indoor session — distance estimated from '
                    '${session.steps} steps.',
          ),
        if (session.unverifiedSteps > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _DisclosureNote(
              icon: Icons.help_outline,
              text:
                  '${session.unverifiedSteps} steps detected in the same place '
                  '— not added to distance.',
            ),
          ),

        const SizedBox(height: 20),

        // Route map (only when we have ≥2 GPS points to draw a line).
        // When there's no route, we deliberately render nothing extra — the
        // disclosure notes above already explain WHY (estimated from steps /
        // unverified in place / etc.), so a second "no route recorded" card
        // would just be noise.
        if (session.path.length >= 2) ...[
          Text('ROUTE',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                letterSpacing: 2,
              )),
          const SizedBox(height: 10),
          SizedBox(
            height: 280,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: _RouteMap(points: session.path),
            ),
          ),
        ],
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

class _StatGrid extends StatelessWidget {
  final List<_Stat> tiles;
  const _StatGrid({required this.tiles});

  @override
  Widget build(BuildContext context) {
    // 3 columns. Wrap pattern with even spacing.
    return LayoutBuilder(builder: (ctx, c) {
      const spacing = 10.0;
      final w = (c.maxWidth - spacing * 2) / 3;
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: tiles
            .map((t) => SizedBox(width: w, child: _StatTile(stat: t)))
            .toList(),
      );
    });
  }
}

class _Stat {
  final String label;
  final String value;
  final String unit;
  const _Stat({required this.label, required this.value, required this.unit});
}

class _StatTile extends StatelessWidget {
  final _Stat stat;
  const _StatTile({required this.stat});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(stat.label.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                letterSpacing: 1.5,
              )),
          const SizedBox(height: 6),
          RichText(
            text: TextSpan(
              style: theme.textTheme.titleMedium?.copyWith(
                color: AppColors.onSurface,
                fontWeight: FontWeight.w700,
              ),
              children: [
                TextSpan(text: stat.value),
                if (stat.unit.isNotEmpty)
                  TextSpan(
                    text: ' ${stat.unit}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RouteMap extends StatelessWidget {
  final List<dynamic> points; // RunPoint
  const _RouteMap({required this.points});

  @override
  Widget build(BuildContext context) {
    final latlngs = points
        .map((p) => LatLng((p.lat as double), (p.lng as double)))
        .toList(growable: false);
    // Centre around the midpoint so the whole route is visible from the start.
    final centre = latlngs[(latlngs.length / 2).floor()];
    return FlutterMap(
      options: MapOptions(
        initialCenter: centre,
        initialZoom: 15,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
        ),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.stepbattle.stepbattle',
        ),
        PolylineLayer(
          polylines: [
            Polyline(
              points: latlngs,
              strokeWidth: 5,
              color: AppColors.primary,
            ),
          ],
        ),
        MarkerLayer(
          markers: [
            Marker(
              point: latlngs.first,
              width: 16,
              height: 16,
              child: const _RoutePin(color: AppColors.success),
            ),
            Marker(
              point: latlngs.last,
              width: 16,
              height: 16,
              child: const _RoutePin(color: AppColors.error),
            ),
          ],
        ),
      ],
    );
  }
}

/// Inline ⓘ-style note for honest-disclosure text under the Distance stat.
/// Subtle, not alarming — the goal is "transparency" not "accuracy warning".
class _DisclosureNote extends StatelessWidget {
  final IconData icon;
  final String text;
  const _DisclosureNote({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.amber.withValues(alpha: 0.25),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: AppColors.amber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoutePin extends StatelessWidget {
  final Color color;
  const _RoutePin({required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
      ),
    );
  }
}
