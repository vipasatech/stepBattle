import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

class _SetHomeSheetState extends ConsumerState<SetHomeSheet> {
  _Step _step = _Step.picker;
  final _pincodeCtrl = TextEditingController();
  final _countryCtrl = TextEditingController(text: 'IN');
  HomeLocation? _resolved;
  String? _error;

  @override
  void dispose() {
    _pincodeCtrl.dispose();
    _countryCtrl.dispose();
    super.dispose();
  }

  // --- Action handlers ---------------------------------------------------

  Future<void> _useLocation() async {
    setState(() {
      _step = _Step.fetchingGps;
      _error = null;
    });

    final svc = ref.read(geoServiceProvider);
    final pos = await svc.getCurrentLocation();
    if (!mounted) return;
    if (pos == null) {
      setState(() {
        _step = _Step.error;
        _error =
            'Could not get your location. Make sure location is on, or use a postal code.';
      });
      return;
    }

    final home = await svc.reverseGeocode(pos.latitude, pos.longitude);
    if (!mounted) return;
    if (home == null) {
      setState(() {
        _step = _Step.error;
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
    });
  }

  // --- Build -------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !widget.requireChoice,
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
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
              const Icon(Icons.chevron_right,
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
          const CircularProgressIndicator(color: AppColors.primary),
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
  final VoidCallback onRetry;
  const _ErrorStep({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.error_outline, color: AppColors.error),
            const SizedBox(width: 8),
            Text('Something went wrong',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800)),
          ],
        ),
        const SizedBox(height: 8),
        Text(message,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: AppColors.onSurfaceVariant, height: 1.4)),
        const SizedBox(height: 18),
        SizedBox(
          height: 52,
          child: FilledButton(
            onPressed: onRetry,
            child: const Text('Try again'),
          ),
        ),
      ],
    );
  }
}
