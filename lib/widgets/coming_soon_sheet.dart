import 'package:flutter/material.dart';

import '../config/colors.dart';

/// Bottom-sheet replacement for the old fade-out "Coming Soon" toast.
///
/// Fully transparent sheet — no filled card. The system scrim dims
/// the app behind, which gives the two lines of text enough contrast
/// to read on any background. Title sits top-left so the user knows
/// which feature they tapped; "Coming soon" is centered.
Future<void> showComingSoonSheet(
  BuildContext context, {
  required String title,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    useRootNavigator: true,
    // isScrollControlled = the sheet's height is honored exactly as
    // the builder returns; without it Flutter caps at ~half viewport
    // and can silently clip our explicit `height` on some devices.
    isScrollControlled: true,
    builder: (_) => _ComingSoonSheet(title: title),
  );
}

class _ComingSoonSheet extends StatelessWidget {
  final String title;
  const _ComingSoonSheet({required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Container(
        // ~35% of the viewport — plenty for the two lines, still
        // feels like a bottom sheet rather than a fullscreen takeover.
        height: MediaQuery.of(context).size.height * 0.35,
        decoration: BoxDecoration(
          // Same base as the QR share sheet — dark glass, thin
          // primary-tinted top edge, nothing else. Kept consistent
          // across all system bottom sheets in the app.
          color: const Color(0xFF14141A).withValues(alpha: 0.72),
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(24),
          ),
          border: Border(
            top: BorderSide(
              color: AppColors.primary.withValues(alpha: 0.5),
              width: 1.5,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Stack(
            children: [
              // Drag handle — pins the sheet as a modal in the
              // user's mental model; without it the transparent
              // background reads as a floating text.
              Align(
                alignment: Alignment.topCenter,
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Section title, top-left (below the drag handle).
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ),
              // Rocket + "Coming soon" — centered.
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.rocket_launch,
                      color: AppColors.primary,
                      size: 22,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Coming soon',
                      style: const TextStyle(
                        color: Colors.white,
                        fontFamily: 'Space Grotesk',
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
