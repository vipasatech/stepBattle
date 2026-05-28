import 'package:flutter/material.dart';

import '../config/colors.dart';
import 'bottom_sheet_handle.dart';

/// Bottom sheet shown when an action fails because the device can't reach
/// the backend (no Wi-Fi/mobile data, blocked DNS, captive portal, etc.).
///
/// Shown via [showNoNetworkSheet] from any catch block — see
/// `isNetworkError` in `lib/utils/network_errors.dart`. Returning `true`
/// from the sheet means the user tapped "Try again" and the caller should
/// retry; `false` (or null) means they dismissed.
class NoNetworkSheet extends StatelessWidget {
  /// Optional secondary message — e.g., the action they were attempting
  /// ("Couldn't sign in with Google").
  final String? subtitle;

  const NoNetworkSheet({super.key, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BottomSheetHandle(),
            const SizedBox(height: 8),
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(Icons.wifi_off_rounded,
                  color: AppColors.primary, size: 32),
            ),
            const SizedBox(height: 16),
            Text(
              'No internet connection',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                subtitle ??
                    'Connect to Wi-Fi or mobile data and try again.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppColors.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      style: OutlinedButton.styleFrom(
                        padding:
                            const EdgeInsets.symmetric(vertical: 14),
                        side: BorderSide(
                            color: AppColors.outlineVariant),
                      ),
                      child: const Text('Dismiss'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => Navigator.of(context).pop(true),
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Try again'),
                      style: FilledButton.styleFrom(
                        padding:
                            const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

/// Convenience helper: opens the sheet and returns whether the user
/// chose "Try again". Use this from a catch block:
///
///   if (isNetworkError(e)) {
///     final retry = await showNoNetworkSheet(context, subtitle: '...');
///     if (retry == true) _signIn();
///     return;
///   }
Future<bool?> showNoNetworkSheet(
  BuildContext context, {
  String? subtitle,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => NoNetworkSheet(subtitle: subtitle),
  );
}
