import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/mission_model.dart';
import '../providers/mission_provider.dart';
import '../services/mission_poster_service.dart';
import 'mission_poster_overlay.dart';

/// Wraps the app (or the authenticated shell) with the mission-poster
/// popup logic. Fires the poster overlay when:
///
///   1. The host mounts (cold start / auth completes).
///   2. The app returns to the foreground (`AppLifecycleState.resumed`).
///
/// Picks the winning mission from
/// [missionPosterCandidatesProvider] (highest [displayOrder]), then
/// checks [MissionPosterService.isDismissed] before showing. Only ONE
/// poster per open — subsequent qualifying missions wait for the
/// next foreground event.
class MissionPosterHost extends ConsumerStatefulWidget {
  final Widget child;
  const MissionPosterHost({super.key, required this.child});

  @override
  ConsumerState<MissionPosterHost> createState() =>
      _MissionPosterHostState();
}

class _MissionPosterHostState extends ConsumerState<MissionPosterHost>
    with WidgetsBindingObserver {
  MissionModel? _currentPoster;
  bool _checkPending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // First check runs after the initial frame so mission providers
    // have had a chance to settle their AsyncValue (avoid firing on
    // empty catalogs during the auth flash).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeShowNext();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _maybeShowNext();
    }
  }

  Future<void> _maybeShowNext() async {
    if (!mounted) return;
    // Only one candidate check in flight at a time — the provider
    // fires several times while data streams settle.
    if (_checkPending) return;
    if (_currentPoster != null) return;
    _checkPending = true;

    try {
      final candidates = ref.read(missionPosterCandidatesProvider);
      for (final m in candidates) {
        final dismissed =
            await MissionPosterService.isDismissed(m.missionId);
        if (dismissed) continue;
        if (!mounted) return;
        setState(() => _currentPoster = m);
        return;
      }
    } finally {
      _checkPending = false;
    }
  }

  void _onDismissed() {
    if (!mounted) return;
    setState(() => _currentPoster = null);
  }

  @override
  Widget build(BuildContext context) {
    // Re-check whenever mission data resolves. `listen` fires on
    // provider value changes without triggering a rebuild loop.
    ref.listen(missionPosterCandidatesProvider, (_, __) {
      _maybeShowNext();
    });
    final poster = _currentPoster;
    return Stack(
      children: [
        widget.child,
        if (poster != null)
          MissionPosterOverlay(
            key: ValueKey('poster-${poster.missionId}'),
            mission: poster,
            onDismissed: _onDismissed,
          ),
      ],
    );
  }
}
