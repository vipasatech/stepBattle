import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/colors.dart';
import '../../models/run_session_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/run_session_provider.dart';
import '../../services/permission_service.dart';
import '../../services/run_tracking_service.dart';
import '../../sheets/logs_viewer_sheet.dart';
import '../../utils/app_logger.dart';
import '../../widgets/empty_state.dart';

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
      final synced =
          await ref.read(runTrackingServiceProvider).syncPending();
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
        title: const Text('Track'),
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
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  AppColors.primaryBrand.withValues(alpha: 0.20),
                  AppColors.primaryBrand.withValues(alpha: 0.06),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: AppColors.primaryBrand.withValues(alpha: 0.30),
              ),
            ),
            child: Column(
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
                    icon: Icon(isActive ? Icons.open_in_full : Icons.play_arrow),
                    label: Text(isActive ? 'Open active session' : 'Start run'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 28),
          historyAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
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

class _SessionTile extends ConsumerWidget {
  final RunSession session;
  const _SessionTile({required this.session});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final km = (session.distanceMeters / 1000);
    final dur = _formatDuration(session.durationSeconds);
    return Material(
      color: AppColors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        // Pending sessions only live in Hive — the detail screen reads
        // from Supabase, so navigating there would 404. Instead, trigger
        // an immediate retry sync.
        onTap: session.isPending
            ? () => _retrySync(context, ref)
            : () => GoRouter.of(context).go('/track/session/${session.id}'),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.primaryBrand.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.directions_run,
                    color: AppColors.primary, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Row title — user-set name OR auto-default ("Run · MMM d, h:mm a")
                    Text(
                      session.displayName,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${km.toStringAsFixed(2)} km · $dur · '
                      '${session.steps} steps · ${session.calories} kcal',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              // Pending-sync pill takes priority over the source pill —
              // a pending session hasn't been confirmed by the server
              // yet, which is more important for the user to know than
              // whether the distance came from GPS or pedometer.
              if (session.isPending)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.amber.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: AppColors.amber.withValues(alpha: 0.45)),
                  ),
                  child: Text(
                    'PENDING SYNC',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.amber,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                      fontSize: 9.5,
                    ),
                  ),
                )
              else if (session.source != 'pedometer')
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.primaryBrand.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    session.source.toUpperCase(),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right,
                  size: 18, color: AppColors.onSurfaceVariant),
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
    final synced =
        await ref.read(runTrackingServiceProvider).syncPending();
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

  static String _formatDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }
}
