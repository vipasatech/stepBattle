import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:hive/hive.dart';
import '../config/colors.dart';
import '../providers/step_provider.dart';
import '../screens/onboarding/health_setup_screen.dart';
import '../services/native_step_service.dart';
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

  /// Hive key: unix-ms timestamp after which we may prompt again for
  /// permissions. Set when the user dismisses the dialog via "Later"
  /// so we don't spam them on every foreground return. Cleared when
  /// permissions actually get granted so the next unrelated miss can
  /// still surface immediately.
  static const String _cooldownKey = 'permission_prompt_cooldown_until';

  /// 24 hours between "Later" dismissals and the next prompt. Long
  /// enough to stop the every-foreground nag; short enough that a user
  /// who denied by accident sees it again the next day.
  static const Duration _cooldown = Duration(hours: 24);

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
      // Respect the "Later" cooldown so the dialog doesn't re-fire on
      // every foreground return. If the user grants elsewhere (Settings
      // → app permissions), the next tick's checkAll() will see
      // `allGranted` and clear the cooldown.
      final box = Hive.box(NativeStepService.boxName);
      final untilMs = box.get(_cooldownKey) as int?;
      if (untilMs != null &&
          DateTime.now().millisecondsSinceEpoch < untilMs) {
        return;
      }
      _dialogShown = true;
      await _showPermissionDialog(status);
      _dialogShown = false;
      return;
    }

    // All permissions granted — clear any lingering cooldown so a
    // future genuine miss (permission revoked in system settings)
    // prompts immediately.
    final box = Hive.box(NativeStepService.boxName);
    await box.delete(_cooldownKey);

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

  /// Called by the dialog's "Later" button — writes the cooldown
  /// timestamp so we skip re-prompting for 24h.
  static Future<void> markLater() async {
    final box = Hive.box(NativeStepService.boxName);
    final until =
        DateTime.now().add(_cooldown).millisecondsSinceEpoch;
    await box.put(_cooldownKey, until);
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
    try {
      final service = ref.read(permissionServiceProvider);
      // Cap the whole request chain — Health Connect can hang forever
      // when the user backs out of the Health Connect app without
      // making a choice, or when Health Connect isn't installed on
      // the device. Without a timeout the spinner stays spinning and
      // the "Later" button also stays disabled, so the only escape
      // is a force-kill (what users were hitting on production).
      await service.requestAll().timeout(const Duration(seconds: 45));
      // ACTIVITY_RECOGNITION may have just been granted — re-arm the
      // native pedometer subscription so steps start flowing without
      // an app restart.
      await ref.read(restartNativeStepServiceProvider)();
    } catch (_) {
      // Swallow — the dialog will close and the gate re-checks on
      // resume, so partial grants still stick.
    } finally {
      if (mounted) {
        setState(() => _requesting = false);
        Navigator.of(context).pop();
      }
    }
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
          // Health Connect row is HIDDEN when the device doesn't have
          // HC installable at all (older MIUI/HyperOS, some tablets).
          // Showing an ungrantable "unchecked" row is confusing and
          // suggested the user was missing something they couldn't fix.
          // Hardware pedometer covers the step-tracking need without HC.
          if (s.healthConnectAvailable) ...[
            const SizedBox(height: 10),
            _PermRow(
              icon: Icons.favorite,
              label: 'Health Connect',
              subtitle: 'Sync steps and calories',
              granted: s.health,
            ),
          ],
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
        // "Later" is a plain cancel — never gate it on `_requesting`.
        // If Grant hangs (e.g. Health Connect unresponsive), the user
        // MUST be able to bail out; disabling this here is what forced
        // people to force-kill the app on v1.0.2+9.
        //
        // Tapping "Later" also writes a 24h cooldown so the dialog
        // doesn't reappear on every foreground return — testers were
        // seeing it re-fire every time they came back to the app.
        TextButton(
          onPressed: () async {
            await _PermissionGateState.markLater();
            if (context.mounted) Navigator.of(context).pop();
          },
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
