import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../models/run_session_model.dart';
import '../../../providers/run_session_provider.dart';
import '../../track/track_session_detail_screen.dart';

/// Home-tab peek at TODAY's most-recent track session, rendered with
/// the same [SessionDetailBody] widget the full detail screen uses so
/// the visual matches "lift and place from the session page".
///
/// Hidden entirely when there's no qualifying session — the widget
/// resolves to `SizedBox.shrink()` so it takes no vertical space on
/// days the user hasn't run.
///
/// Show criteria (all must hold):
///   • Session's `startedAt` local date == today's local date
///   • Session's `steps > 50`
///   • Session's `durationSeconds > 300` (5 minutes)
///
/// Tapping the card opens the full detail screen (`/track/session/:id`).
class TodaysSessionCard extends ConsumerWidget {
  const TodaysSessionCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Lean single-row fetch — was pulling the full ~20-row history
    // via `runSessionHistoryProvider` and client-side picking today's
    // row, which pinned the history provider open for the whole
    // session (further pinned by `last28DaysMetricsProvider` watching
    // its future). The lean autoDispose version releases as soon as
    // the Home tab is off screen.
    final session = ref.watch(todaysRunSessionProvider).valueOrNull;
    if (session == null || !_qualifiesForHome(session)) {
      return const SizedBox.shrink();
    }

    // Pull surface colour from Theme so this widget registers a
    // dependency on the InheritedTheme — without that dependency, the
    // card kept rendering the dark `AppColors.surfaceContainerLow`
    // value after a light-mode toggle because Riverpod's watched
    // providers hadn't changed and the widget never rebuilt.
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 32),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => context.push('/track/session/${session.id}'),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
            // Compact 2×2 stats grid + kcal pulled into the grid's
            // left column as a third row (home is narrower than the
            // detail screen, and the user asked to drop the MIXED
            // source chip). Both the source chip and the disclosure
            // notes remain visible on the full detail screen that
            // opens on tap.
            child: SessionDetailBody(
              session: session,
              compactStats: true,
              showDisclosures: false,
              showMetaChips: false,
            ),
          ),
        ),
      ),
    );
  }

  /// Whether the fetched session is meaningful enough to surface as
  /// the Home peek card. `todaysRunSessionProvider` already scoped to
  /// today's date server-side; this predicate carries the "not too
  /// short / not too few steps" gate the old client-side picker
  /// enforced.
  static bool _qualifiesForHome(RunSession s) {
    if (s.steps <= 50) return false;
    if (s.durationSeconds <= 300) return false;
    return true;
  }
}
