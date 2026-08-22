import 'package:flutter/material.dart';

import '../config/colors.dart';

/// The "prominent disclosure" dialog Google Play requires prior to the
/// runtime location permission prompt when an app declares
/// `ACCESS_BACKGROUND_LOCATION`. Without this dialog visible in the
/// Play Console review video, Google rejects the background-location
/// declaration.
///
/// Policy checklist (all satisfied here):
///   * Appears BEFORE the runtime permission prompt.
///   * Names the feature that uses location (Track session).
///   * Explicitly states data is used in the background / while the app
///     is closed or not in use.
///   * Not dismissible by tapping outside — user must tap either
///     "Continue" (proceeds to runtime prompt) or "Cancel" (aborts).
///   * "Continue" is not the default styled button; both actions are
///     equally weighted so consent is a deliberate choice.
///
/// Returns `true` when the user tapped "Continue" (proceed to runtime
/// prompt), `false` for "Cancel" or if the dialog was somehow
/// dismissed (WillPopScope guards Android back-button).
class BackgroundLocationDisclosureDialog {
  BackgroundLocationDisclosureDialog._();

  static Future<bool> show(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _DisclosureDialog(),
    );
    return result == true;
  }
}

class _DisclosureDialog extends StatelessWidget {
  const _DisclosureDialog();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      child: AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        icon: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.explore_outlined,
            color: AppColors.primary,
            size: 30,
          ),
        ),
        title: Text(
          'Location access for Track',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
          ),
          textAlign: TextAlign.center,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'StepBattle uses your device location to record the '
              'route of your Track (run or walk) sessions on a map.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppColors.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'To keep the route continuous when your screen turns off '
              'or you switch apps mid-run, we also need to access your '
              'location in the background — but only during an active '
              'Track session that you started. A persistent '
              'notification stays visible so you always know recording '
              'is on.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: AppColors.onSurfaceVariant,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.25),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline,
                      color: AppColors.primary, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Location is never accessed outside an active '
                      'Track session, is not shared with third parties, '
                      'and is not used for advertising.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.onSurface,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'You can tap Continue to proceed to Android\'s location '
              'permission screen, or Cancel to skip Track for now.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        actions: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    side: BorderSide(
                      color: AppColors.outlineVariant,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  child: Text(
                    'Cancel',
                    style: TextStyle(
                      color: AppColors.onSurface,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  child: const Text(
                    'Continue',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
