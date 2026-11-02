import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config/colors.dart';
import 'tour_controller.dart';

/// Small "i" icon that re-triggers the tour scoped to a specific range
/// of steps. Meant for placement in a page's AppBar so users can
/// re-learn just that page's components without replaying the whole
/// 13-step tour from Settings.
///
/// **Not** shown while the tour is already running — pressing this
/// mid-tour would be confusing (the controller no-ops on `start*`
/// anyway, but hiding the icon removes the visual noise).
///
/// Usage:
/// ```dart
/// TourReplayIconButton(
///   fromIndex: 0,
///   untilExclusive: 5,  // Home = steps 0-4
///   tooltip: 'Home tour',
/// )
/// ```
class TourReplayIconButton extends ConsumerWidget {
  final int fromIndex;
  final int untilExclusive;
  final String tooltip;

  const TourReplayIconButton({
    super.key,
    required this.fromIndex,
    required this.untilExclusive,
    this.tooltip = 'Replay tour',
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tourActive = ref.watch(tourControllerProvider).active;
    if (tourActive) return const SizedBox.shrink();
    // Compact IconButton (36×36 instead of 48×48). The Home + Battle
    // AppBars are already dense; the default IconButton pushed the
    // actions row 6 dp past the AppBar width and triggered Flutter's
    // overflow warning (2026-09-04 fix).
    return IconButton(
      tooltip: tooltip,
      icon: Icon(
        Icons.info_outline_rounded,
        size: 20,
        color: AppColors.onSurfaceVariant,
      ),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      visualDensity: VisualDensity.compact,
      onPressed: () => ref
          .read(tourControllerProvider.notifier)
          .startFromStep(fromIndex, untilExclusive: untilExclusive),
    );
  }
}
