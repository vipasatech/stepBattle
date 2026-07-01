import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../config/colors.dart';

/// Re-prompt for `Permission.locationWhenInUse` when a feature needs
/// location but the user denied (or never granted) it during onboarding.
///
/// Visual matches the Strava-style "Allow precise location access" sheet
/// the user referenced, but recoloured for our brand purple instead of
/// orange.
///
/// USAGE:
///   final ok = await ensureLocationPermission(
///     context,
///     reason: 'StepBattle uses your location to place you on local '
///             'leaderboards (district / state / country / world).',
///   );
///   if (!ok) return; // user declined or system blocked it
///
/// Behavior matrix:
///   • permission already granted → returns true immediately, no sheet
///   • permission denied but askable → sheet shown, on "Allow" calls
///     Permission.locationWhenInUse.request()
///   • permission permanently denied → sheet shown with "Open Settings"
///     action instead of "Allow" (system will not re-prompt)
Future<bool> ensureLocationPermission(
  BuildContext context, {
  required String reason,
}) async {
  // Fast path — already granted.
  final current = await Permission.locationWhenInUse.status;
  if (current.isGranted || current.isLimited) return true;

  if (!context.mounted) return false;

  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _LocationPermissionSheet(
      reason: reason,
      permanentlyDenied: current.isPermanentlyDenied,
    ),
  );
  return result ?? false;
}

class _LocationPermissionSheet extends StatefulWidget {
  final String reason;
  final bool permanentlyDenied;
  const _LocationPermissionSheet({
    required this.reason,
    required this.permanentlyDenied,
  });

  @override
  State<_LocationPermissionSheet> createState() =>
      _LocationPermissionSheetState();
}

class _LocationPermissionSheetState extends State<_LocationPermissionSheet> {
  bool _processing = false;

  Future<void> _onAllow() async {
    setState(() => _processing = true);
    bool granted = false;
    try {
      if (widget.permanentlyDenied) {
        // System won't re-prompt after a permanent deny — only Settings
        // can flip it. Open the app's settings page; treat the user
        // returning as "they may have flipped it" and re-check.
        await openAppSettings();
        final after = await Permission.locationWhenInUse.status;
        granted = after.isGranted || after.isLimited;
      } else {
        final status = await Permission.locationWhenInUse.request();
        granted = status.isGranted || status.isLimited;
      }
    } finally {
      if (mounted) {
        setState(() => _processing = false);
        Navigator.of(context).pop(granted);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryLabel = widget.permanentlyDenied ? 'Open Settings' : 'Allow';
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 28),
                decoration: BoxDecoration(
                  color: AppColors.onSurface.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Big icon in soft purple circle
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.near_me,
                  color: AppColors.primary,
                  size: 42,
                ),
              ),
              const SizedBox(height: 22),
              Text(
                'Allow precise location access',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                widget.reason,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppColors.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
              if (widget.permanentlyDenied) ...[
                const SizedBox(height: 12),
                Text(
                  'You previously declined this permission. Open Settings to enable it.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: AppColors.error,
                  ),
                ),
              ],
              const SizedBox(height: 28),
              // Allow / Open Settings — primary purple pill
              SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton(
                  onPressed: _processing ? null : _onAllow,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                  ),
                  child: _processing
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          primaryLabel,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.3,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 10),
              // Cancel — outlined purple pill (mirrors the Strava sheet's
              // outlined orange Cancel button, recoloured to brand).
              SizedBox(
                width: double.infinity,
                height: 52,
                child: OutlinedButton(
                  onPressed: _processing
                      ? null
                      : () => Navigator.of(context).pop(false),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(
                      color: AppColors.primary.withValues(alpha: 0.5),
                      width: 1.5,
                    ),
                    foregroundColor: AppColors.primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(26),
                    ),
                  ),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
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
