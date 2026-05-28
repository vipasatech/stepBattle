import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../config/colors.dart';

/// Empty-state card shown when a feature needs location but the OS-level
/// switch is off (or the user hasn't granted the runtime permission).
///
/// Two flavors driven by [reason]:
///   • [NeedsLocationReason.servicesOff]    — "Turn on Location"
///   • [NeedsLocationReason.permissionDenied] — "Allow Location Access"
///
/// Tapping the CTA opens the right system surface — location settings vs
/// app-permission settings — via [Geolocator]. After the user comes back,
/// [onRetry] runs so the caller can re-check the permission state and
/// hide the card if appropriate.
enum NeedsLocationReason {
  servicesOff,
  permissionDenied,
}

class NeedsLocationCard extends StatelessWidget {
  final NeedsLocationReason reason;
  final String featureName;
  final VoidCallback? onRetry;

  const NeedsLocationCard({
    super.key,
    required this.reason,
    this.featureName = 'this feature',
    this.onRetry,
  });

  bool get _isServicesOff =>
      reason == NeedsLocationReason.servicesOff;

  String get _title => _isServicesOff
      ? 'Location is turned off'
      : 'Location access needed';

  String get _body => _isServicesOff
      ? 'Turn on Location to see who is leading near you.'
      : 'Allow $featureName to use your location to see who is leading near you.';

  String get _ctaLabel =>
      _isServicesOff ? 'Turn on Location' : 'Allow Location Access';

  Future<void> _handleCta() async {
    if (_isServicesOff) {
      await Geolocator.openLocationSettings();
    } else {
      await Geolocator.openAppSettings();
    }
    // Caller refreshes whatever it was waiting on once the user returns.
    onRetry?.call();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.15)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(Icons.location_on_outlined,
                  color: AppColors.primary, size: 32),
            ),
            const SizedBox(height: 16),
            Text(
              _title,
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _body,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: AppColors.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _handleCta,
                icon: const Icon(Icons.location_searching, size: 18),
                label: Text(_ctaLabel),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Resolve current location state into either a [NeedsLocationReason]
/// (caller should render [NeedsLocationCard]) or `null` (location is
/// available — proceed with the geo query).
Future<NeedsLocationReason?> resolveLocationBlock() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    return NeedsLocationReason.servicesOff;
  }
  final permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    return NeedsLocationReason.permissionDenied;
  }
  return null;
}
