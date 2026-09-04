import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/colors.dart';
import '../../providers/mission_provider.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/mount_stagger.dart';
import '../home/widgets/highlighted_mission_card.dart';

/// Full-page list of every featured mission (`should_show_in_home =
/// true` on the admin side, not-yet-completed for the current user).
///
/// Reached from the Home-tab stacked mission deck — tap the front card
/// or the "+N more →" link. Sort order matches the Home stack
/// (newest / highest displayOrder first, from
/// [homeHighlightedMissionsProvider]) so the mission the user saw on
/// Home is at the top here too.
///
/// 2026-08-31 — converted to [ConsumerStatefulWidget] so we can:
///   • Wrap the mission list in a [RefreshIndicator] so users on a
///     stale realtime subscription have a manual escape hatch
///     (Supabase Realtime does NOT replay missed INSERT events on
///     reconnect — an admin-added mission published while our
///     WebSocket was in reconnect-purgatory would silently disappear
///     until the next cold start without this).
///   • Invalidate the daily + weekly missions providers on
///     [AppLifecycleState.resumed] so admin edits made while the app
///     was backgrounded land the moment the user returns.
class MissionsPage extends ConsumerStatefulWidget {
  const MissionsPage({super.key});

  @override
  ConsumerState<MissionsPage> createState() => _MissionsPageState();
}

class _MissionsPageState extends ConsumerState<MissionsPage>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Mirror the Home tab's resume-invalidation: forcing a fresh
    // snapshot of the missions catalog on foreground catches admin
    // edits made while we were away (Realtime doesn't replay missed
    // events on reconnect). Cheap when nothing changed.
    if (state == AppLifecycleState.resumed) {
      ref.invalidate(dailyMissionsProvider);
      ref.invalidate(weeklyMissionsProvider);
    }
  }

  Future<void> _handleRefresh() async {
    ref.invalidate(dailyMissionsProvider);
    ref.invalidate(weeklyMissionsProvider);
    // Small yield so RefreshIndicator's spinner has time to paint —
    // otherwise iOS's cupertino-refresh cancels itself when the future
    // resolves in the same frame.
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(homeHighlightedMissionsProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: const Text('Featured Missions'),
      ),
      backgroundColor: AppColors.background,
      body: RefreshIndicator(
        onRefresh: _handleRefresh,
        // Empty state also needs to be scrollable inside the
        // RefreshIndicator, otherwise a user with zero missions
        // (which is the exact case where they'd want to check for new
        // admin content) has nowhere to pull. LayoutBuilder makes the
        // empty state fill the viewport height so the gesture works.
        child: entries.isEmpty
            ? LayoutBuilder(
                builder: (_, constraints) => SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: constraints.maxHeight,
                    ),
                    child: EmptyState(
                      icon: Icons.flag_outlined,
                      title: 'No featured missions',
                      subtitle:
                          'Admin-featured missions land here. Nothing active right now — check back soon.',
                    ),
                  ),
                ),
              )
            : ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                // Preinflate a bit past the viewport so scrolling a
                // long mission list (~10+) doesn't hitch on the first
                // flick.
                cacheExtent: 600,
                itemCount: entries.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  // First 6 rows fade+slide in with 70ms stagger; rest
                  // paint instantly. See StaggerIndex docs re: recycle.
                  child: HighlightedMissionCard(entry: entries[i]).staggerAt(i),
                ),
              ),
      ),
    );
  }
}
