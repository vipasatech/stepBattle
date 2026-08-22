import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/colors.dart';
import '../providers/user_provider.dart';
import '../services/geo_service.dart';
import '../widgets/bottom_sheet_handle.dart';

final geoServiceProvider = Provider<GeoService>((ref) => GeoService());

/// Lets the user set their home district via either:
///   • Device location (one-time COARSE_LOCATION fix + reverse-geocode)
///   • Postal code (api.postalpincode.in for IN, Zippopotam.us elsewhere)
///   • Skip ("Set later")
///
/// Used during onboarding and from Profile when changing district.
class SetHomeSheet extends ConsumerStatefulWidget {
  /// When true, the sheet is non-dismissible until the user picks a path
  /// or explicitly skips (used inline during onboarding).
  final bool requireChoice;

  const SetHomeSheet({super.key, this.requireChoice = false});

  @override
  ConsumerState<SetHomeSheet> createState() => _SetHomeSheetState();
}

enum _Step { picker, fetchingGps, pincodeInput, resolvingPin, success, error }

class _SetHomeSheetState extends ConsumerState<SetHomeSheet>
    with WidgetsBindingObserver {
  _Step _step = _Step.picker;
  final _pincodeCtrl = TextEditingController();
  final _countryCtrl = TextEditingController(text: 'IN');
  HomeLocation? _resolved;
  String? _error;
  // Non-null when the error was a location-permission / services failure —
  // tells the error step to show the right recovery CTA (grant / open
  // settings / turn on location) instead of a bare "Try again".
  LocationFailureReason? _locationFailure;
  // Set when we launched the user out to system settings (location
  // toggle or app permissions page). On resume we auto-retry so the
  // sheet reflects the new state without the user having to tap
  // anything.
  bool _awaitingSettingsReturn = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pincodeCtrl.dispose();
    _countryCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The user is coming back from the OS settings page they were
    // deep-linked into via "Turn on location" / "Open app settings".
    // Re-run the fetch so the sheet reflects the new state rather than
    // stubbornly showing the pre-toggle error.
    if (state == AppLifecycleState.resumed && _awaitingSettingsReturn) {
      _awaitingSettingsReturn = false;
      if (mounted && _step == _Step.error) {
        _useLocation();
      }
    }
  }

  // --- Action handlers ---------------------------------------------------

  Future<void> _useLocation() async {
    setState(() {
      _step = _Step.fetchingGps;
      _error = null;
      _locationFailure = null;
    });

    final svc = ref.read(geoServiceProvider);
    final result = await svc.getCurrentLocation();
    if (!mounted) return;
    if (result.position == null) {
      final reason = result.failure ?? LocationFailureReason.timeout;
      setState(() {
        _step = _Step.error;
        _locationFailure = reason;
        _error = switch (reason) {
          LocationFailureReason.servicesOff =>
            'Location is turned off for this device. Turn it on in system settings, or use a postal code instead.',
          LocationFailureReason.permissionDenied =>
            'StepBattle needs location permission to detect your district. Grant permission to continue, or use a postal code instead.',
          LocationFailureReason.permissionDeniedForever =>
            'Location permission is blocked in Settings. Open app settings to allow it, or use a postal code instead.',
          LocationFailureReason.timeout =>
            'Couldn\'t get a location fix — signal may be weak. Try again or use a postal code.',
        };
      });
      return;
    }

    final pos = result.position!;
    final home = await svc.reverseGeocode(pos.latitude, pos.longitude);
    if (!mounted) return;
    if (home == null) {
      setState(() {
        _step = _Step.error;
        _locationFailure = null;
        _error =
            'Got your location but could not resolve a district. Try a postal code.';
      });
      return;
    }

    setState(() {
      _resolved = home;
      _step = _Step.success;
    });
  }

  /// Open OS-level location services page. User returns via back button.
  /// Set the "awaiting return" flag so [didChangeAppLifecycleState] auto-
  /// retries the location fetch once the app resumes.
  Future<void> _openLocationSettings() async {
    _awaitingSettingsReturn = true;
    await Geolocator.openLocationSettings();
  }

  /// Open the app's OS settings page so the user can flip the location
  /// permission back on after having selected "Don't allow again". Same
  /// auto-retry-on-resume pattern as [_openLocationSettings].
  Future<void> _openAppSettings() async {
    _awaitingSettingsReturn = true;
    await Geolocator.openAppSettings();
  }

  /// Switch straight into the postal-code entry step — offered as an
  /// escape hatch on every error variant.
  void _switchToPincode() {
    setState(() {
      _step = _Step.pincodeInput;
      _error = null;
      _locationFailure = null;
    });
  }

  Future<void> _resolvePincode() async {
    final raw = _pincodeCtrl.text.trim();
    if (raw.isEmpty) return;

    setState(() {
      _step = _Step.resolvingPin;
      _error = null;
    });

    final svc = ref.read(geoServiceProvider);
    final cc = _countryCtrl.text.trim().toUpperCase();
    final home = await svc.resolvePincode(
      raw,
      countryCode: cc.isEmpty ? null : cc,
    );

    if (!mounted) return;
    if (home == null) {
      setState(() {
        _step = _Step.error;
        _error =
            'Could not find that postal code. Check the country and try again.';
      });
      return;
    }

    setState(() {
      _resolved = home;
      _step = _Step.success;
    });
  }

  Future<void> _save() async {
    final home = _resolved;
    final me = Supabase.instance.client.auth.currentUser;
    if (home == null || me == null) return;

    try {
      await ref.read(geoServiceProvider).saveHomeForUser(
            userId: me.id,
            home: home,
          );
      ref.invalidate(userProfileProvider);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      // Surface as the in-flow error step rather than an unhandled exception.
      // Most common cause: Firestore rules haven't been updated to allow
      // writing the new geo fields — see firestore.rules for the policy.
      setState(() {
        _step = _Step.error;
        _error = e.toString().contains('permission-denied') ||
                e.toString().contains('PERMISSION_DENIED')
            ? 'Could not save your home — your account might need a Firebase '
                'rules update. Try again, or contact support if it keeps failing.'
            : 'Could not save your home: $e';
      });
    }
  }

  void _retry() {
    setState(() {
      _step = _Step.picker;
      _error = null;
      _locationFailure = null;
    });
  }

  // --- Build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Combine keyboard inset (viewInsets) with the gesture / nav-bar inset
    // (viewPadding.bottom) so the primary action never slips behind the
    // system UI on gesture-nav phones or when the keyboard is open.
    final mq = MediaQuery.of(context);
    final bottomInset = mq.viewInsets.bottom + mq.viewPadding.bottom;
    return PopScope(
      canPop: !widget.requireChoice,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const BottomSheetHandle(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: switch (_step) {
                    _Step.picker => _PickerStep(
                        onLocation: _useLocation,
                        onPincode: () =>
                            setState(() => _step = _Step.pincodeInput),
                        onSkip:
                            widget.requireChoice ? null : () => Navigator.pop(context),
                      ),
                    _Step.fetchingGps => const _LoadingStep(
                        title: 'Finding your location…',
                        subtitle: 'Allow location when prompted.',
                      ),
                    _Step.pincodeInput => _PincodeStep(
                        pincodeCtrl: _pincodeCtrl,
                        countryCtrl: _countryCtrl,
                        onResolve: _resolvePincode,
                        onBack: () => setState(() => _step = _Step.picker),
                      ),
                    _Step.resolvingPin => const _LoadingStep(
                        title: 'Looking up that postal code…',
                      ),
                    _Step.success => _SuccessStep(
                        home: _resolved!,
                        onConfirm: _save,
                        onRedo: _retry,
                      ),
                    _Step.error => _ErrorStep(
                        message: _error ?? 'Something went wrong',
                        locationFailure: _locationFailure,
                        onGrantPermission: _useLocation,
                        onOpenLocationSettings: _openLocationSettings,
                        onOpenAppSettings: _openAppSettings,
                        onUsePincode: _switchToPincode,
                        onRetry: _retry,
                      ),
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Step widgets
// =============================================================================

class _PickerStep extends StatelessWidget {
  final VoidCallback onLocation;
  final VoidCallback onPincode;
  final VoidCallback? onSkip;

  const _PickerStep({
    required this.onLocation,
    required this.onPincode,
    this.onSkip,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Set your home',
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(
          'Used for local leaderboards (your district, state, country) — no continuous tracking.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: AppColors.onSurfaceVariant, height: 1.4),
        ),
        const SizedBox(height: 24),
        _OptionTile(
          icon: Icons.my_location,
          title: 'Use my location',
          subtitle: 'One-time location check — fastest way',
          accent: AppColors.primary,
          onTap: onLocation,
        ),
        const SizedBox(height: 10),
        _OptionTile(
          icon: Icons.markunread_mailbox_outlined,
          title: 'Enter a postal code',
          subtitle: 'PIN code (India) or ZIP / postcode',
          accent: AppColors.tertiary,
          onTap: onPincode,
        ),
        if (onSkip != null) ...[
          const SizedBox(height: 8),
          TextButton(
            onPressed: onSkip,
            child: const Text('Set later'),
          ),
        ],
      ],
    );
  }
}

class _OptionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;
  final VoidCallback onTap;

  const _OptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: accent.withValues(alpha: 0.2)),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: accent),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: theme.textTheme.labelSmall?.copyWith(
                            color: AppColors.onSurfaceVariant, height: 1.4)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right,
                  color: AppColors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _PincodeStep extends StatelessWidget {
  final TextEditingController pincodeCtrl;
  final TextEditingController countryCtrl;
  final VoidCallback onResolve;
  final VoidCallback onBack;

  const _PincodeStep({
    required this.pincodeCtrl,
    required this.countryCtrl,
    required this.onResolve,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              icon: const Icon(Icons.arrow_back, size: 20),
              onPressed: onBack,
            ),
            const SizedBox(width: 8),
            Text('Postal code',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800)),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            SizedBox(
              width: 90,
              child: TextField(
                controller: countryCtrl,
                textCapitalization: TextCapitalization.characters,
                maxLength: 2,
                decoration: const InputDecoration(
                  labelText: 'Country',
                  hintText: 'IN',
                  counterText: '',
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: pincodeCtrl,
                keyboardType: TextInputType.text,
                onSubmitted: (_) => onResolve(),
                decoration: const InputDecoration(
                  labelText: 'Postal code',
                  hintText: '500032',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Country code is ISO-2 (e.g., IN, US, GB). India PINs are 6 digits.',
          style: theme.textTheme.labelSmall
              ?.copyWith(color: AppColors.onSurfaceVariant),
        ),
        const SizedBox(height: 18),
        SizedBox(
          height: 52,
          child: FilledButton(
            onPressed: onResolve,
            child: const Text('Look up'),
          ),
        ),
      ],
    );
  }
}

class _LoadingStep extends StatelessWidget {
  final String title;
  final String? subtitle;
  const _LoadingStep({required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          CircularProgressIndicator(color: AppColors.primary),
          const SizedBox(height: 18),
          Text(title,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w800)),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: AppColors.onSurfaceVariant)),
          ],
        ],
      ),
    );
  }
}

class _SuccessStep extends StatelessWidget {
  final HomeLocation home;
  final VoidCallback onConfirm;
  final VoidCallback onRedo;

  const _SuccessStep({
    required this.home,
    required this.onConfirm,
    required this.onRedo,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.check_circle, color: AppColors.success),
            const SizedBox(width: 8),
            Text('Got it!',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800)),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: AppColors.primary.withValues(alpha: 0.2)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(home.summary,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(home.countryName,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.onSurfaceVariant)),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: onRedo,
                child: const Text('Try again'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: onConfirm,
                child: const Text('Confirm'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ErrorStep extends StatelessWidget {
  final String message;
  final LocationFailureReason? locationFailure;
  final VoidCallback onGrantPermission;
  final VoidCallback onOpenLocationSettings;
  final VoidCallback onOpenAppSettings;
  final VoidCallback onUsePincode;
  final VoidCallback onRetry;

  const _ErrorStep({
    required this.message,
    required this.locationFailure,
    required this.onGrantPermission,
    required this.onOpenLocationSettings,
    required this.onOpenAppSettings,
    required this.onUsePincode,
    required this.onRetry,
  });

  ({String label, IconData icon, VoidCallback onPressed}) get _primary {
    switch (locationFailure) {
      case LocationFailureReason.servicesOff:
        return (
          label: 'Turn on location',
          icon: Icons.location_on_outlined,
          onPressed: onOpenLocationSettings,
        );
      case LocationFailureReason.permissionDenied:
        return (
          label: 'Grant permission',
          icon: Icons.location_on_outlined,
          onPressed: onGrantPermission,
        );
      case LocationFailureReason.permissionDeniedForever:
        return (
          label: 'Open app settings',
          icon: Icons.settings_outlined,
          onPressed: onOpenAppSettings,
        );
      case LocationFailureReason.timeout:
      case null:
        return (
          label: 'Try again',
          icon: Icons.refresh,
          onPressed: onRetry,
        );
    }
  }

  String get _title => locationFailure == null
      ? 'Something went wrong'
      : switch (locationFailure!) {
          LocationFailureReason.servicesOff => 'Location is off',
          LocationFailureReason.permissionDenied => 'Location permission needed',
          LocationFailureReason.permissionDeniedForever =>
            'Permission blocked',
          LocationFailureReason.timeout => 'Couldn\'t get a fix',
        };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final action = _primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.error_outline, color: AppColors.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _title,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(message,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: AppColors.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: 18),
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed: action.onPressed,
            icon: Icon(action.icon, size: 20),
            label: Text(action.label),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: onUsePincode,
          child: const Text('Use a postal code instead'),
        ),
      ],
    );
  }
}
