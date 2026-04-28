import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../config/colors.dart';
import '../providers/step_provider.dart';
import '../screens/onboarding/health_setup_screen.dart';
import '../services/permission_service.dart';

final permissionServiceProvider =
    Provider<PermissionService>((ref) => PermissionService());

/// Wraps a child and checks permissions on mount + app resume.
/// Shows a blocking dialog if any critical permissions are missing.
class PermissionGate extends ConsumerStatefulWidget {
  final Widget child;
  const PermissionGate({super.key, required this.child});

  @override
  ConsumerState<PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends ConsumerState<PermissionGate>
    with WidgetsBindingObserver {
  bool _dialogShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkPermissions());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPermissions();
    }
  }

  Future<void> _checkPermissions() async {
    if (_dialogShown) return;
    final service = ref.read(permissionServiceProvider);
    final status = await service.checkAll();
    if (!mounted) return;

    if (status.anyMissing) {
      _dialogShown = true;
      await _showPermissionDialog(status);
      _dialogShown = false;
      return;
    }

    // All permissions granted — push the OEM-aware setup wizard once,
    // so users (especially on Realme/Motorola) see the per-device toggle
    // they need to flip. Hive flag prevents re-showing.
    if (HealthSetupScreen.shouldShowFirstRunWizard()) {
      if (!mounted) return;
      // Small delay so the wizard doesn't fight an in-flight grant dialog.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      context.push('/profile/health-setup?firstRun=true');
    }
  }

  Future<void> _showPermissionDialog(PermissionSummary status) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _PermissionDialog(status: status),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _PermissionDialog extends ConsumerStatefulWidget {
  final PermissionSummary status;

  const _PermissionDialog({required this.status});

  @override
  ConsumerState<_PermissionDialog> createState() => _PermissionDialogState();
}

class _PermissionDialogState extends ConsumerState<_PermissionDialog> {
  bool _requesting = false;

  Future<void> _grantAll() async {
    setState(() => _requesting = true);
    final service = ref.read(permissionServiceProvider);
    await service.requestAll();
    // ACTIVITY_RECOGNITION may have just been granted — re-arm the native
    // pedometer subscription so steps start flowing without an app restart.
    await ref.read(restartNativeStepServiceProvider)();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = widget.status;

    return AlertDialog(
      backgroundColor: AppColors.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      title: Row(
        children: [
          Icon(Icons.shield, color: AppColors.primary, size: 24),
          const SizedBox(width: 10),
          Text('Almost Ready!',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'StepBattle needs these permissions to track your steps and send notifications:',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          _PermRow(
            icon: Icons.directions_walk,
            label: 'Activity Recognition',
            subtitle: 'Required to count your steps',
            granted: s.activityRecognition,
          ),
          const SizedBox(height: 10),
          _PermRow(
            icon: Icons.favorite,
            label: 'Health Connect',
            subtitle: 'Sync steps and calories',
            granted: s.health,
          ),
          const SizedBox(height: 10),
          _PermRow(
            icon: Icons.notifications,
            label: 'Notifications',
            subtitle: 'Battle invites and reminders',
            granted: s.notifications,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _requesting ? null : () => Navigator.of(context).pop(),
          child: Text('Later',
              style: TextStyle(color: AppColors.onSurfaceVariant)),
        ),
        FilledButton(
          onPressed: _requesting ? null : _grantAll,
          child: _requesting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Text('Grant All'),
        ),
      ],
    );
  }
}

class _PermRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final bool granted;

  const _PermRow({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.granted,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(icon,
            size: 22,
            color: granted ? AppColors.success : AppColors.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
              Text(subtitle,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.onSurfaceVariant)),
            ],
          ),
        ),
        Icon(
          granted ? Icons.check_circle : Icons.radio_button_unchecked,
          color: granted ? AppColors.success : AppColors.outline,
          size: 20,
        ),
      ],
    );
  }
}
