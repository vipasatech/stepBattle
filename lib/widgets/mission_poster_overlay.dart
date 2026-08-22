import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/colors.dart';
import '../models/mission_model.dart';
import '../providers/mission_provider.dart';
import '../services/mission_poster_service.dart';
import '../sheets/mission_detail_sheet.dart';

/// Full-screen popup for a featured mission's admin-uploaded poster.
///
/// - Backdrop dims to ~65% black; tap dismisses (same as [X]).
/// - Poster image fills most of the screen with a small [X] pinned
///   to its top-right corner.
/// - Tapping the poster body (anywhere except the [X]) opens the
///   [MissionDetailSheet] for the featured mission AND marks the
///   poster dismissed so it doesn't re-show next foreground.
/// - Dismissing via [X] also persists via [MissionPosterService].
class MissionPosterOverlay extends ConsumerStatefulWidget {
  final MissionModel mission;
  final VoidCallback onDismissed;

  const MissionPosterOverlay({
    super.key,
    required this.mission,
    required this.onDismissed,
  });

  @override
  ConsumerState<MissionPosterOverlay> createState() =>
      _MissionPosterOverlayState();
}

class _MissionPosterOverlayState extends ConsumerState<MissionPosterOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _dismiss({bool openDetail = false}) async {
    // Persist dismissal FIRST so a second open before we finish the
    // exit animation still catches the flag.
    await MissionPosterService.markDismissed(widget.mission.missionId);
    if (!mounted) return;
    await _controller.reverse();
    if (!mounted) return;
    // Notify host to remove the overlay entry.
    widget.onDismissed();
    if (openDetail && mounted) {
      final progressList =
          ref.read(dailyProgressProvider).valueOrNull ?? const [];
      final progress =
          findProgress(progressList, widget.mission.missionId);
      // Route via the root navigator so we're not stacked under the
      // overlay we just removed.
      final nav = Navigator.of(context, rootNavigator: true);
      showModalBottomSheet<void>(
        context: nav.context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        useRootNavigator: true,
        builder: (_) => MissionDetailSheet(
          mission: widget.mission,
          progress: progress,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, __) {
        final t = Curves.easeOutCubic.transform(_controller.value);
        final scale = 0.85 + t * 0.15;
        return Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _dismiss(),
            child: Container(
              color: Colors.black.withValues(alpha: 0.65 * t),
              child: Center(
                child: Opacity(
                  opacity: t,
                  child: Transform.scale(
                    scale: scale,
                    child: _PosterCard(
                      mission: widget.mission,
                      onClose: () => _dismiss(),
                      onOpenDetail: () => _dismiss(openDetail: true),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PosterCard extends StatelessWidget {
  final MissionModel mission;
  final VoidCallback onClose;
  final VoidCallback onOpenDetail;

  const _PosterCard({
    required this.mission,
    required this.onClose,
    required this.onOpenDetail,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          // Swallow taps on the card so the backdrop dismiss doesn't fire.
          onTap: onOpenDetail,
          child: Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: AspectRatio(
                  aspectRatio: 3 / 4,
                  child: Container(
                    color: AppColors.surfaceContainerHigh,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: Image.network(
                            mission.posterUrl ?? '',
                            fit: BoxFit.cover,
                            loadingBuilder: (_, child, progress) =>
                                progress == null
                                    ? child
                                    : Center(
                                        child: CircularProgressIndicator(
                                            color: AppColors.primary,
                                            strokeWidth: 2)),
                            errorBuilder: (_, __, ___) => Center(
                              child: Icon(Icons.broken_image_outlined,
                                  color: AppColors.onSurfaceVariant,
                                  size: 48),
                            ),
                          ),
                        ),
                        // Poster footer — mission title + XP so the
                        // popup remains useful even if the image is
                        // decorative (no text baked in).
                        Container(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.75),
                              ],
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                mission.title,
                                style: theme.textTheme.titleMedium
                                    ?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: AppColors.tertiary
                                          .withValues(alpha: 0.85),
                                      borderRadius:
                                          BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      '+${mission.xpReward} XP',
                                      style: const TextStyle(
                                        color: Colors.black,
                                        fontFamily: 'Manrope',
                                        fontSize: 11,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 0.4,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Tap to view mission',
                                    style: theme.textTheme.labelSmall
                                        ?.copyWith(
                                      color: Colors.white
                                          .withValues(alpha: 0.9),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Close [X] pinned to top-right of the poster. Its own
              // GestureDetector wraps the outer card so tap-to-open-
              // detail can't fire from clicking here.
              Positioned(
                top: 8,
                right: 8,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: onClose,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: Colors.white.withValues(alpha: 0.4)),
                      ),
                      child: const Icon(Icons.close,
                          color: Colors.white, size: 20),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
