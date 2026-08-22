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
class MissionsPage extends ConsumerWidget {
  const MissionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
      body: entries.isEmpty
          ? EmptyState(
              icon: Icons.flag_outlined,
              title: 'No featured missions',
              subtitle:
                  'Admin-featured missions land here. Nothing active right now — check back soon.',
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              // Preinflate a bit past the viewport so scrolling a long
              // mission list (~10+) doesn't hitch on the first flick.
              cacheExtent: 600,
              itemCount: entries.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                // First 6 rows fade+slide in with 70ms stagger; rest
                // paint instantly. See StaggerIndex docs re: recycle.
                child: HighlightedMissionCard(entry: entries[i]).staggerAt(i),
              ),
            ),
    );
  }
}
