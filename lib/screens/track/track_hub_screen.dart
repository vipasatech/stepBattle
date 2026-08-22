import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../config/colors.dart';
import '../../models/run_session_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/run_session_provider.dart';
import '../../services/permission_service.dart';
import '../../services/run_tracking_service.dart';
import '../../sheets/background_location_disclosure_dialog.dart';
import '../../sheets/logs_viewer_sheet.dart';
import '../../utils/app_logger.dart';
import '../../utils/friendly_date.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/mount_stagger.dart';
import '../../widgets/premium_card.dart';
import '../../widgets/pressable.dart';
import '../../widgets/shimmer_loader.dart';

/// Landing screen for the Track feature. Big "Start Run" button + recent
/// sessions list. Reached by tapping the floating FAB when no session is
/// active; if one IS active, the FAB jumps straight to TrackLiveScreen.
class TrackHubScreen extends ConsumerStatefulWidget {
  const TrackHubScreen({super.key});

  @override
  ConsumerState<TrackHubScreen> createState() => _TrackHubScreenState();
}

class _TrackHubScreenState extends ConsumerState<TrackHubScreen> {
  bool _starting = false;
  final TextEditingController _nameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Retry any pending session uploads from prior runs that failed to
    // reach Supabase (auth token expired mid-run, no connectivity at
    // end-of-session, etc.). Fire-and-forget — we just want the
    // history list to refresh when something new lands.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final synced = await ref.read(runTrackingServiceProvider).syncPending();
      if (synced > 0 && mounted) {
        ref.invalidate(runSessionHistoryProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              synced == 1
                  ? '1 saved session synced.'
                  : '$synced saved sessions synced.',
            ),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      // Prominent disclosure REQUIRED by Google Play policy before any
      // request for ACCESS_BACKGROUND_LOCATION. This dialog names the
      // feature (Track), states background usage explicitly, and forces
      // an explicit Continue/Cancel choice — without it Google rejects
      // the background-location declaration on release review.
      //
      // Skip the disclosure if the user has already granted background
      // location previously — showing it every Start tap once permission
      // is in place feels like nagging. The disclosure only needs to
      // fire ahead of the actual OS permission prompt; if the OS won't
      // prompt because it's already granted, we've got nothing to
      // disclose.
      final alreadyGranted = await Permission.locationAlways.isGranted;
      if (!mounted) return;
      if (!alreadyGranted) {
        final consented =
            await BackgroundLocationDisclosureDialog.show(context);
        if (!mounted) return;
        if (!consented) {
          setState(() => _starting = false);
          return;
        }
      }

      final permission = await PermissionService().requestRunPermissions();
      if (!mounted) return;
      switch (permission) {
        case RunLocationStatus.granted:
        case RunLocationStatus.foregroundOnly:
          // Foreground-only still lets us start; recording pauses if the
          // screen turns off. Tell the user and start.
          if (permission == RunLocationStatus.foregroundOnly) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                'Background location not granted — recording may pause when the screen is off.',
              ),
            ));
          }
          break;
        case RunLocationStatus.permanentlyDenied:
        case RunLocationStatus.foregroundOnlyPermanent:
          await PermissionService().openAppSettingsPage();
          return;
        case RunLocationStatus.denied:
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Location permission is required to track a run.'),
          ));
          return;
      }

      final uid = ref.read(authStateProvider).valueOrNull?.id;
      if (uid == null) return;
      final name = _nameController.text;
      final ok = await ref
          .read(runTrackingServiceProvider)
          .start(userId: uid, name: name);
      if (!mounted) return;
      if (ok) {
        _nameController.clear();
        context.go('/track/live');
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final historyAsync = ref.watch(runSessionHistoryProvider);
    // Watch the stream so we rebuild when end() emits null; trust the Hive
    // flag for the truth — `activeAsync.valueOrNull` would otherwise stay
    // populated with the last RunSession even after the session ended.
    ref.watch(activeRunSessionProvider);
    final isActive = isTrackActiveFromHive();

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(
          'Track',
          // Uses theme default (white in dark mode, black in light) —
          // consistent with Leaderboard's AppBar so the shell tabs
          // read as one system.
          style: theme.textTheme.headlineSmall?.copyWith(
            color: AppColors.onSurface,
            fontWeight: FontWeight.w700,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          // /track is a root-level route (not pushed on top of the shell), so
          // there's nothing to pop. Send the user back to Home explicitly.
          onPressed: () => context.go('/home'),
        ),
        actions: [
          IconButton(
            tooltip: 'Diagnostics',
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: () =>
                showLogsViewerSheet(context, focus: LogCategory.track),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 120),
        children: [
          // MountStagger reveals hero card + history section with a
          // fade+slide on first mount. Two blocks total; both animate.
          MountStagger(
            animateCount: 2,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 28),
                child: PremiumCard(
                  // Strong intensity — the "Start run" card is the tab's
                  // hero surface. Deeper corner glow + fuller violet
                  // gradient than the session tiles below (which use
                  // `soft`); intensity conveys the hierarchy without
                  // resorting to different visual languages.
                  intensity: PremiumCardIntensity.strong,
                  borderRadius: 24,
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.directions_run,
                              color: AppColors.primary, size: 28),
                          const SizedBox(width: 10),
                          Text('Run / walk session',
                              style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.w700,
                              )),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Track steps, distance, and calories with GPS. Falls back to '
                        'pedometer if GPS is weak.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: AppColors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Optional name. Blank → auto-defaulted to "Run · MMM d, h:mm a"
                      // on save. Hidden while a session is already active (the live
                      // screen does in-run naming).
                      if (!isActive)
                        TextField(
                          controller: _nameController,
                          maxLength: 50,
                          textInputAction: TextInputAction.done,
                          decoration: const InputDecoration(
                            labelText: 'Name this run (optional)',
                            hintText: 'e.g. Morning park loop',
                            counterText: '',
                          ),
                        ),
                      if (!isActive) const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: isActive
                              ? () => context.go('/track/live')
                              : (_starting ? null : _start),
                          icon: Icon(
                              isActive ? Icons.open_in_full : Icons.play_arrow),
                          label: Text(
                              isActive ? 'Open active session' : 'Start run'),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              historyAsync.when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    children: [
                      ShimmerCard(),
                      SizedBox(height: 12),
                      ShimmerCard()
                    ],
                  ),
                ),
                error: (_, __) => const EmptyState(
                  icon: Icons.error_outline,
                  title: 'Could not load history',
                  subtitle: 'Pull down to retry.',
                ),
                data: (sessions) {
                  if (sessions.isEmpty) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _RecentSessionsHeader(
                          onSeeAll: null,
                        ),
                        const SizedBox(height: 10),
                        const EmptyState(
                          icon: Icons.directions_run,
                          title: 'No runs yet',
                          subtitle:
                              'Tap "Start run" above to record your first one.',
                        ),
                      ],
                    );
                  }
                  // Cap the hub at the 5 most-recent sessions; chevron on
                  // the header opens the full-history page when there's
                  // more.
                  final visible = sessions.take(5).toList();
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _RecentSessionsHeader(
                        onSeeAll: sessions.length > 5
                            ? () => context.push('/track/history')
                            : null,
                      ),
                      const SizedBox(height: 10),
                      ...visible.map((s) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: _SessionTile(session: s),
                          )),
                    ],
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Small-caps section header + optional right-arrow chevron for
/// "RECENT SESSIONS". Passing a non-null [onSeeAll] renders the
/// chevron in brand-violet and wires the tap; passing null hides it.
class _RecentSessionsHeader extends StatelessWidget {
  final VoidCallback? onSeeAll;
  const _RecentSessionsHeader({required this.onSeeAll});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            'RECENT SESSIONS',
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppColors.onSurfaceVariant,
              letterSpacing: 2,
            ),
          ),
        ),
        if (onSeeAll != null)
          GestureDetector(
            onTap: onSeeAll,
            behavior: HitTestBehavior.opaque,
            child: Icon(
              Icons.chevron_right,
              size: 22,
              color: AppColors.primary,
            ),
          ),
      ],
    );
  }
}

/// Recent-sessions row on the Track hub.
///
/// Redesigned to a two-band premium card: an upper HEADER band with
/// the run name + a small date pill, then a lower METRICS band with
/// four aligned columns — Distance · Pace · Time · Steps. Left edge
/// carries a violet accent stripe with the running-figure icon so
/// the tile reads as "an activity" at a glance instead of a generic
/// list row. Matches the design reference the tester shared.
///
/// Interaction is unchanged: tap navigates to the detail screen
/// (or fires a retry-sync for pending Hive-only rows).
class _SessionTile extends ConsumerWidget {
  final RunSession session;
  const _SessionTile({required this.session});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final km = (session.distanceMeters / 1000);
    final dur = _formatDurationTime(session.durationSeconds);
    final pace = _formatPace(
      distanceMeters: session.distanceMeters,
      durationSeconds: session.durationSeconds,
    );

    // Card body = PremiumCard(soft) for the deep-violet gradient +
    // dot-mesh + corner glow that matches the rest of the app's
    // premium surfaces (Home overview, Battles cards). `soft` intensity
    // — sessions are past/archived, not the hero surface. Pressable
    // provides the same tactile scale-on-press feel that battle cards
    // use, wrapping (not inside) the tap handler so the card's own
    // GestureDetector fires normally.
    return Pressable(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Pending sessions only live in Hive — the detail screen reads
        // from Supabase, so navigating there would 404. Instead, trigger
        // an immediate retry sync.
        onTap: session.isPending
            ? () => _retrySync(context, ref)
            : () => GoRouter.of(context).go('/track/session/${session.id}'),
        child: PremiumCard(
          intensity: PremiumCardIntensity.soft,
          // Zero PremiumCard padding — each row inside picks its own so
          // the run icon can hug the left edge (10dp inset) while the
          // metric strip below stays at the standard 16dp inset. If we
          // reduced the whole card's left padding uniformly, "Distance"
          // would slide 6dp left too, and the tester wants that anchor
          // to stay put.
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header row — small run icon (no badge/circle, per
              // tester feedback that the earlier circular badge read as
              // a bolted-on decoration), title, trailing pill. Icon
              // uses `AppColors.primary` at 20dp so it reads as a
              // subtle accent, not a chip.
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 14, 16, 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.directions_run,
                      size: 20,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        session.displayName,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                          height: 1.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (session.isPending)
                      _StatusPill(
                        label: 'PENDING SYNC',
                        fg: AppColors.amber,
                        bg: AppColors.amber.withValues(alpha: 0.18),
                        border: AppColors.amber.withValues(alpha: 0.45),
                      )
                    else if (session.source != 'pedometer')
                      _StatusPill(
                        label: session.source.toUpperCase(),
                        fg: AppColors.primary,
                        bg: AppColors.primaryBrand.withValues(alpha: 0.15),
                      )
                    else
                      _DatePill(
                        text: friendlyDateTime(session.startedAt),
                      ),
                  ],
                ),
              ),

              // Metric strip — 4 evenly-spaced columns. Hairline
              // dividers between so the strip reads as one unit,
              // not four cards. IntrinsicHeight sizes the strip to
              // its tallest column so `crossAxisAlignment: stretch`
              // has a bounded height to work with (mandatory — an
              // unwrapped `Row(cross: stretch)` in this SliverList
              // context throws `BoxConstraints forces an infinite
              // height` and cascades to `hasSize` failures across
              // every ancestor decoration).
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Metric(
                        label: 'Distance',
                        value: km.toStringAsFixed(2),
                        unit: 'km',
                      ),
                      _MetricDivider(),
                      _Metric(
                        label: 'Pace',
                        value: pace.$1,
                        unit: pace.$2,
                      ),
                      _MetricDivider(),
                      _Metric(
                        label: 'Time',
                        value: dur,
                        unit: '',
                      ),
                      _MetricDivider(),
                      _Metric(
                        label: 'Steps',
                        value: _formatInt(session.steps),
                        unit: '',
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _retrySync(BuildContext context, WidgetRef ref) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Retrying sync…'),
        duration: Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ),
    );
    final synced = await ref.read(runTrackingServiceProvider).syncPending();
    if (!context.mounted) return;
    ref.invalidate(runSessionHistoryProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          synced > 0
              ? 'Synced $synced session${synced == 1 ? '' : 's'}.'
              : 'Still pending — open Diagnostics (top-right) for the error.',
        ),
        duration: Duration(seconds: synced > 0 ? 3 : 4),
        behavior: SnackBarBehavior.floating,
        action: synced == 0
            ? SnackBarAction(
                label: 'Logs',
                onPressed: () =>
                    showLogsViewerSheet(context, focus: LogCategory.track),
              )
            : null,
      ),
    );
  }

  /// Time-value formatter for the redesigned tile's "Time" column.
  /// Fixed-width `Hh Mm` / `Mm Ss` / `Ss` so the four metric columns
  /// stay visually aligned across rows.
  static String _formatDurationTime(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  /// Pace value formatter — returns `(value, unit)` so the metric cell
  /// can render the number in the display style and the unit in the
  /// muted style, like the reference image.
  ///
  ///   • distance == 0 → returns ('—', '') so a zero-distance session
  ///     doesn't emit `inf min/km`.
  ///   • otherwise → `min:ss` per km with the unit `/km`.
  static (String, String) _formatPace({
    required double distanceMeters,
    required int durationSeconds,
  }) {
    if (distanceMeters <= 0 || durationSeconds <= 0) return ('—', '');
    final km = distanceMeters / 1000;
    final secondsPerKm = durationSeconds / km;
    final m = secondsPerKm ~/ 60;
    final s = (secondsPerKm - m * 60).round();
    // Handle carry: 59.6s rounds to 60 → bump minute.
    final mm = s == 60 ? m + 1 : m;
    final ss = s == 60 ? 0 : s;
    return ('$mm:${ss.toString().padLeft(2, '0')}', '/km');
  }

  static String _formatInt(int n) {
    if (n < 1000) return '$n';
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
// Session-tile helpers — small building blocks used by _SessionTile.
// Kept private to the file since they aren't reused elsewhere.
// =============================================================================

/// One metric column in the redesigned session tile. Two-line stack:
/// small caps label on top, tabular-figure value + unit on the bottom.
/// Numeric column intentionally uses tabular figures so values across
/// consecutive rows stay pixel-aligned.
class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final String unit;

  const _Metric({required this.label, required this.value, this.unit = ''});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppColors.onSurfaceVariant,
              letterSpacing: 1.2,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 3),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  value,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                    color: AppColors.onSurface,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    height: 1,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 2),
                Text(
                  unit,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: AppColors.onSurfaceVariant,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Hairline vertical divider between metric columns. `IntrinsicHeight`
/// on the parent Row makes it match the metric column height without
/// hard-coding a value that could drift as the type scale changes.
class _MetricDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: AppColors.onSurface.withValues(alpha: 0.06),
    );
  }
}

/// Small right-aligned pill on the header row showing the session's
/// relative timestamp (e.g. "Wed · Jul 1"). Uses a hairline border +
/// tinted bg so it reads as chrome, not a call-to-action.
class _DatePill extends StatelessWidget {
  final String text;
  const _DatePill({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerHigh.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppColors.onSurface.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.event_outlined,
            size: 11,
            color: AppColors.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Text(
            text,
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppColors.onSurfaceVariant,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// Generic status pill used when the session is pending-sync OR
/// came from a non-pedometer source (GPS, etc). Colour comes from the
/// caller so a single widget handles both cases.
class _StatusPill extends StatelessWidget {
  final String label;
  final Color fg;
  final Color bg;
  final Color? border;

  const _StatusPill({
    required this.label,
    required this.fg,
    required this.bg,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: border == null ? null : Border.all(color: border!),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: fg,
          fontWeight: FontWeight.w800,
          letterSpacing: 1,
          fontSize: 9.5,
        ),
      ),
    );
  }
}
