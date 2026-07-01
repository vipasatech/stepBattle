import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../../config/colors.dart';
import '../../models/run_session_model.dart';
import '../../providers/run_session_provider.dart';
import '../../sheets/track_share_sheet.dart';

/// Read-only detail view for a saved Track session.
///
/// Reached from a row in the Track hub's "Recent sessions" list.
///
/// Layout (top → bottom):
///   • Header — title + date.
///   • Stats row — Distance, Pace, Time, Steps (4 across).
///     Achievements were the original 4th stat per the Strava reference,
///     but PRs aren't a v1 surface yet, so this slot was reclaimed for
///     Steps per the user's explicit ask.
///   • Description block (if the user wrote one at save time).
///   • Disclosure notes (estimated / unverified caveats), if any.
///   • Media carousel — swipeable `PageView` whose first slide is the
///     GPS route map (when ≥2 fixes exist) and subsequent slides are the
///     user-attached photos. Page dots beneath. Manual swipe/tap only
///     (no auto-advance, per spec).
///
/// Rename + Delete actions live on the AppBar as before.
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
                        icon: const Icon(Icons.ios_share),
                        tooltip: 'Share',
                        onPressed: () =>
                            showTrackShareSheet(context, session: s),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        tooltip: 'Edit',
                        onPressed: () => context.push(
                            '/track/session/${s.id}/edit'),
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
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
            children: [
              SessionDetailBody(session: session),
            ],
          );
        },
      ),
    );
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

// =============================================================================
// Body
// =============================================================================

/// Reusable session-detail block: title + stats + meta chips +
/// optional description + disclosure notes + media carousel. Rendered
/// on the Session detail screen and also lifted onto the Home tab
/// (via `TodaysSessionCard`) so the "today's session" peek shows the
/// same content the user would see if they opened the detail screen.
///
/// Uses a `Column` (not `ListView`) so the parent can decide how to
/// scroll — the detail screen wraps in a ListView; the home tab drops
/// this straight into its own ListView.
///
/// Three knobs let the home-tab peek trim itself:
///   • [compactStats] — when true, stats render as a 2×2 grid
///     (Distance / Pace above, Time / Steps below) instead of a
///     single 4-across row. Home cards are narrower than the detail
///     screen, so 4-across truncates values like "20m 15s" → "20m 1…".
///     When [showMetaChips] is also false, the compact grid grows a
///     third left-column row for Calories so kcal isn't lost.
///   • [showDisclosures] — when true (default), the "estimated from
///     GPS gap" / "steps detected in the same place" notes render
///     beneath the meta chips. Home passes false — the peek should
///     stay clean, and the full notes remain visible on the detail
///     screen a tap away.
///   • [showMetaChips] — when true (default), the kcal + source
///     chips render below the stat grid. Home passes false to drop
///     the MIXED (source) chip; the kcal value gets pulled up into
///     the compact stat grid instead.
class SessionDetailBody extends StatelessWidget {
  final RunSession session;
  final bool compactStats;
  final bool showDisclosures;
  final bool showMetaChips;

  const SessionDetailBody({
    super.key,
    required this.session,
    this.compactStats = false,
    this.showDisclosures = true,
    this.showMetaChips = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final km = session.distanceMeters / 1000;
    final whenStr = DateFormat('EEEE, MMM d • h:mm a')
        .format(session.startedAt.toLocal());
    final pace = session.avgPaceSecPerKm;
    final descTrimmed = session.description?.trim();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Title block.
        Text(
          session.displayName,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          whenStr,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: AppColors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 22),

        // Stats: 4-across on the detail screen, 2×2 on the home peek.
        // When the home peek hides the meta chips, we pull kcal into
        // the grid as a third-row left-column stat so the calorie
        // number doesn't disappear from the peek.
        _TopStatsRow(
          distanceKm: km,
          paceSecPerKm: pace,
          durationSeconds: session.durationSeconds,
          steps: session.steps,
          compact: compactStats,
          calories:
              (!showMetaChips && compactStats) ? session.calories : null,
        ),

        // Secondary stats (calories + source) — chip row, detail-only
        // when the caller opts out via [showMetaChips].
        if (showMetaChips) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              _MetaChip(
                icon: Icons.bolt,
                tint: AppColors.amber,
                label: '${session.calories} kcal',
              ),
              const SizedBox(width: 8),
              _MetaChip(
                icon: Icons.sensors,
                tint: AppColors.primary,
                label: session.source.toUpperCase(),
              ),
            ],
          ),
        ],

        // User-written caption from the Save Activity page.
        if (descTrimmed != null && descTrimmed.isNotEmpty) ...[
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            decoration: BoxDecoration(
              color: AppColors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: AppColors.outlineVariant.withValues(alpha: 0.3),
              ),
            ),
            child: Text(
              descTrimmed,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
            ),
          ),
        ],

        // Honest disclosure notes (estimated / unverified) — kept on
        // the full detail screen because the data-integrity story
        // matters there, hidden on the home peek to keep it clean.
        if (showDisclosures && session.distanceMetersEstimated > 0)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: _DisclosureNote(
              icon: Icons.timeline,
              text: session.distanceMetersVerified > 0
                  ? '${session.distanceMetersEstimated.round()} m estimated '
                      'from steps during a GPS gap.'
                  : 'Indoor session — distance estimated from '
                      '${session.steps} steps.',
            ),
          ),
        if (showDisclosures && session.unverifiedSteps > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _DisclosureNote(
              icon: Icons.help_outline,
              text:
                  '${session.unverifiedSteps} steps detected in the same place '
                  '— not added to distance.',
            ),
          ),

        const SizedBox(height: 22),

        // Media carousel — map first slide, photos after. Renders a
        // graceful placeholder when neither is available.
        _MediaCarousel(session: session),
      ],
    );
  }
}

// =============================================================================
// Top stats row — 4 across
// =============================================================================

class _TopStatsRow extends StatelessWidget {
  final double distanceKm;
  final double? paceSecPerKm;
  final int durationSeconds;
  final int steps;

  /// When true, arrange the four stats as a 2×2 grid instead of a
  /// single 4-across row. Used by the home-tab peek where the
  /// container is narrower and 4-across truncates "20m 15s" values.
  final bool compact;

  /// Optional third-row Calories stat, rendered in the left column
  /// beneath Time when [compact] is also true. The home peek passes
  /// this to keep kcal visible after dropping the chip row; the
  /// detail screen leaves it null and renders kcal as a chip below.
  final int? calories;

  const _TopStatsRow({
    required this.distanceKm,
    required this.paceSecPerKm,
    required this.durationSeconds,
    required this.steps,
    this.compact = false,
    this.calories,
  });

  @override
  Widget build(BuildContext context) {
    final distance = _TopStat(
      label: 'Distance',
      value: distanceKm.toStringAsFixed(2),
      unit: 'km',
    );
    final pace = _TopStat(
      label: 'Pace',
      value: _fmtPace(paceSecPerKm),
      unit: paceSecPerKm == null ? '' : '/km',
    );
    final time = _TopStat(
      label: 'Time',
      value: _fmtDuration(durationSeconds),
      unit: '',
    );
    final stepsStat = _TopStat(
      label: 'Steps',
      value: '$steps',
      unit: '',
    );

    if (compact) {
      // 2×2 grid: Distance / Pace on top, Time / Steps below. Each
      // stat gets ~half the container width — plenty of room for
      // "20m 15s" and "2,671" without truncation. When calories is
      // provided, a third row surfaces it in the left column beneath
      // Time (right column intentionally empty so kcal sits directly
      // under Distance + Time, per the user's ask).
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: distance),
              Expanded(child: pace),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(child: time),
              Expanded(child: stepsStat),
            ],
          ),
          if (calories != null) ...[
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: _TopStat(
                    label: 'Calories',
                    value: '$calories',
                    unit: 'kcal',
                  ),
                ),
                const Expanded(child: SizedBox.shrink()),
              ],
            ),
          ],
        ],
      );
    }

    return Row(
      children: [
        Expanded(child: distance),
        Expanded(child: pace),
        Expanded(child: time),
        Expanded(child: stepsStat),
      ],
    );
  }

  static String _fmtPace(double? secPerKm) {
    if (secPerKm == null || secPerKm.isNaN || !secPerKm.isFinite) {
      return '--';
    }
    final mins = secPerKm ~/ 60;
    final secs = (secPerKm % 60).round();
    return '$mins:${secs.toString().padLeft(2, '0')}';
  }

  static String _fmtDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }
}

class _TopStat extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  const _TopStat({
    required this.label,
    required this.value,
    required this.unit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Center-aligned column content — same treatment as the share
    // cards' 4-column stats row. The parent Row + Expanded already
    // gives equal widths; centering the label + value pair inside
    // each column then makes the visual gap between adjacent
    // columns look equal regardless of value string length.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          label,
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall?.copyWith(
            color: AppColors.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  fontSize: 22,
                ),
              ),
            ),
            if (unit.isNotEmpty) ...[
              const SizedBox(width: 3),
              Text(
                unit,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.onSurfaceVariant,
                  fontSize: 11,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final Color tint;
  final String label;
  const _MetaChip(
      {required this.icon, required this.tint, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tint.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: tint, size: 14),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: tint,
              fontWeight: FontWeight.w800,
              fontSize: 11,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Media carousel — PageView of map + photo slides
// =============================================================================

class _MediaCarousel extends StatefulWidget {
  final RunSession session;
  const _MediaCarousel({required this.session});

  @override
  State<_MediaCarousel> createState() => _MediaCarouselState();
}

class _MediaCarouselState extends State<_MediaCarousel> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Build the ordered slide list. First slide is the GPS map when the
  /// session has ≥2 path points; subsequent slides are user-attached
  /// photos in their original order.
  List<_Slide> _buildSlides() {
    final slides = <_Slide>[];
    if (widget.session.path.length >= 2) {
      slides.add(const _Slide.map());
    }
    for (final url in widget.session.mediaUrls) {
      slides.add(_Slide.photo(url));
    }
    return slides;
  }

  @override
  Widget build(BuildContext context) {
    final slides = _buildSlides();
    if (slides.isEmpty) {
      return const _NoMediaPlaceholder();
    }

    return Column(
      children: [
        SizedBox(
          height: 280,
          child: PageView.builder(
            controller: _controller,
            itemCount: slides.length,
            physics: const BouncingScrollPhysics(),
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (_, i) {
              final slide = slides[i];
              return ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: slide.map
                    ? _RouteMap(points: widget.session.path)
                    : _PhotoSlide(url: slide.url!),
              );
            },
          ),
        ),
        if (slides.length > 1) ...[
          const SizedBox(height: 12),
          _PageDots(count: slides.length, active: _page),
        ],
      ],
    );
  }
}

/// One slide entry — either the GPS route map (`map == true`) or a
/// remote photo URL.
class _Slide {
  final bool map;
  final String? url;

  const _Slide.map()
      : map = true,
        url = null;
  const _Slide.photo(this.url) : map = false;
}

class _PhotoSlide extends StatelessWidget {
  final String url;
  const _PhotoSlide({required this.url});

  @override
  Widget build(BuildContext context) {
    return Image.network(
      url,
      fit: BoxFit.cover,
      loadingBuilder: (_, child, progress) {
        if (progress == null) return child;
        return Container(
          color: AppColors.surfaceContainerLow,
          alignment: Alignment.center,
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: AppColors.primary,
              value: progress.expectedTotalBytes == null
                  ? null
                  : progress.cumulativeBytesLoaded /
                      progress.expectedTotalBytes!,
            ),
          ),
        );
      },
      errorBuilder: (_, __, ___) {
        return Container(
          color: AppColors.surfaceContainerLow,
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.broken_image_outlined,
                  color: AppColors.onSurfaceVariant, size: 32),
              const SizedBox(height: 8),
              Text(
                'Photo unavailable',
                style: TextStyle(
                  color: AppColors.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _NoMediaPlaceholder extends StatelessWidget {
  const _NoMediaPlaceholder();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 160,
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppColors.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.image_outlined,
              color: AppColors.onSurfaceVariant, size: 32),
          const SizedBox(height: 8),
          Text(
            'No route or photos for this session',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppColors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _PageDots extends StatelessWidget {
  final int count;
  final int active;
  const _PageDots({required this.count, required this.active});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (int i = 0; i < count; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: i == active ? 16 : 7,
              height: 7,
              decoration: BoxDecoration(
                color: i == active
                    ? AppColors.primary
                    : AppColors.outlineVariant.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
      ],
    );
  }
}

// =============================================================================
// Route map (kept from previous design)
// =============================================================================

class _RouteMap extends StatelessWidget {
  final List<dynamic> points; // RunPoint
  const _RouteMap({required this.points});

  @override
  Widget build(BuildContext context) {
    final latlngs = points
        .map((p) => LatLng((p.lat as double), (p.lng as double)))
        .toList(growable: false);
    return FlutterMap(
      options: MapOptions(
        // Auto-fit so both the start marker and the end marker are
        // visible on load — before this the map centred on the mid-
        // point at zoom 15, which cropped the endpoints on longer
        // routes. Padding gives the polyline breathing room from the
        // card edges.
        initialCameraFit: CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(latlngs),
          padding: const EdgeInsets.all(28),
        ),
        // Pan/zoom are DISABLED so horizontal drags on the card slide
        // through to the parent PageView (session detail carousel).
        // Without this the map ate the drag and the carousel felt
        // stuck on the map page.
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.none,
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
