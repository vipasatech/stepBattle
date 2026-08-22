import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../config/colors.dart';
import '../../models/run_session_model.dart';
import '../../providers/run_session_provider.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/shimmer_loader.dart';

/// Full history of the user's saved Track sessions.
///
/// The Track hub caps its "RECENT SESSIONS" list at 5 and shows a
/// chevron on the section header — that chevron routes here so the
/// user can scroll the entire history without the hub becoming a
/// scroll marathon. Data source is the same [runSessionHistoryProvider]
/// the hub uses, so the two stay in sync automatically.
class AllTrackSessionsScreen extends ConsumerWidget {
  const AllTrackSessionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(runSessionHistoryProvider);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('All sessions'),
      ),
      backgroundColor: AppColors.background,
      body: historyAsync.when(
        loading: () => ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: const [
            ShimmerCard(),
            SizedBox(height: 12),
            ShimmerCard(),
            SizedBox(height: 12),
            ShimmerCard(),
            SizedBox(height: 12),
            ShimmerCard(),
          ],
        ),
        error: (_, __) => const EmptyState(
          icon: Icons.error_outline,
          title: 'Could not load history',
          subtitle: 'Try again in a moment.',
        ),
        data: (sessions) {
          if (sessions.isEmpty) {
            return const EmptyState(
              icon: Icons.directions_run,
              title: 'No runs yet',
              subtitle: 'Start a run from the Track hub to build history.',
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            itemCount: sessions.length,
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _SessionTile(session: sessions[i]),
            ),
          );
        },
      ),
    );
  }
}

/// Trimmed-down copy of the hub's `_SessionTile` — the hub keeps its
/// own version for the compact peek; this screen renders the same
/// visual so the two views feel continuous.
class _SessionTile extends StatelessWidget {
  final RunSession session;
  const _SessionTile({required this.session});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final km = (session.distanceMeters / 1000);
    return Material(
      color: AppColors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => context.push('/track/session/${session.id}'),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.displayName,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      DateFormat('EEE, MMM d • h:mm a')
                          .format(session.startedAt.toLocal()),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${km.toStringAsFixed(2)} km',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w900),
                  ),
                  Text(
                    '${session.steps} steps',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: AppColors.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
