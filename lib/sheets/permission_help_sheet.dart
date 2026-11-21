import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../config/colors.dart';
import '../services/capability_service.dart';

/// Explains what to switch on before dropping the user into Settings.
///
/// The OS gives us exactly one move once it has stopped prompting:
/// `openAppSettings()`. That lands the user on a page of toggles with no
/// indication of which one we wanted or why. Tapping "Start run" and
/// arriving in Settings with no explanation is the version of this that
/// shipped in 1.1.7+46, and it reads as the app malfunctioning.
///
/// So: say what is blocked, name the exact toggle, then offer the trip.
/// Returns true if the user chose to go.
Future<bool> showPermissionHelpSheet(
  BuildContext context,
  AppCapability capability,
) async {
  final copy = _copyFor(capability);
  final result = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useRootNavigator: true,
    builder: (ctx) => _PermissionHelpSheet(copy: copy),
  );
  return result ?? false;
}

class _HelpCopy {
  const _HelpCopy({
    required this.title,
    required this.reason,
    required this.steps,
  });

  final String title;
  final String reason;
  final List<String> steps;
}

/// Step text names the real toggle on each platform. `openAppSettings()`
/// lands directly on StepBattle's own page, so these start from there
/// rather than from the top of Settings.
_HelpCopy _copyFor(AppCapability capability) {
  final ios = Platform.isIOS;
  switch (capability) {
    case AppCapability.steps:
      return _HelpCopy(
        title: ios ? 'Turn on Motion & Fitness' : 'Turn on Physical activity',
        reason:
            'StepBattle reads your step counter to score battles, keep your '
            'streak alive and track missions. Without it there is nothing '
            'to count.',
        steps: ios
            ? const [
                'Tap Motion & Fitness.',
                'Turn the switch on.',
                'Come back — your steps appear straight away.',
              ]
            : const [
                'Tap Permissions.',
                'Tap Physical activity, then choose Allow.',
                'Come back — your steps appear straight away.',
              ],
      );
    case AppCapability.location:
      return _HelpCopy(
        title: ios ? 'Allow location while using the app' : 'Allow location',
        reason:
            'Track draws the route of your walk or run on a map. Location is '
            'only read while a Track session is actually recording.',
        steps: ios
            ? const [
                'Tap Location.',
                'Choose "While Using the App".',
                'Come back and tap Start run again.',
              ]
            : const [
                'Tap Permissions, then Location.',
                'Choose "Allow only while using the app".',
                'Come back and tap Start run again.',
              ],
      );
    case AppCapability.notifications:
      return _HelpCopy(
        title: 'Turn on notifications',
        reason:
            'This is how you hear that someone challenged you, that you are '
            'about to be overtaken, or that your streak ends tonight.',
        steps: ios
            ? const [
                'Tap Notifications.',
                'Turn on "Allow Notifications".',
                'Come back — nothing else to do.',
              ]
            : const [
                'Tap Notifications.',
                'Turn on "All StepBattle notifications".',
                'Come back — nothing else to do.',
              ],
      );
  }
}

class _PermissionHelpSheet extends StatelessWidget {
  const _PermissionHelpSheet({required this.copy});

  final _HelpCopy copy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF14141A),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              copy.title,
              style: theme.textTheme.titleMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              copy.reason,
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.7),
                height: 1.5,
              ),
            ),
            const SizedBox(height: 18),
            // Numbered because the user is about to leave the app and has
            // to carry these in their head.
            ...copy.steps.asMap().entries.map(
                  (e) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 22,
                          height: 22,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.18),
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            '${e.key + 1}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: AppColors.primary,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            e.value,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Colors.white.withValues(alpha: 0.9),
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.2),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('Not now'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('Open Settings'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
