import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../config/colors.dart';
import '../providers/capability_provider.dart';
import '../sheets/permission_help_sheet.dart';
import '../services/capability_service.dart';

/// Shows [child] when every capability in [requires] is available, and a
/// tappable padlock in its place when any is missing.
///
/// This replaces blocking the user. The old model asked for permissions up
/// front during onboarding and, failing that, held Home behind an
/// unescapable dialog — which meant someone who declined could not reach
/// Settings, could not sign out, and could not delete their account. Now
/// they get the whole app, with the specific numbers they haven't unlocked
/// shown as padlocks they can tap when they care.
///
/// [requires] accumulates. The battles surface asks for notifications AND
/// steps, so a user who skipped the step prompt on Home is asked for both
/// the first time they open a battle. Each tap resolves only what is
/// actually still missing, in order.
///
/// On Android this widget is a pass-through — see [CapabilityLocks].
class MetricLock extends ConsumerStatefulWidget {
  const MetricLock({
    super.key,
    required this.requires,
    required this.child,
    this.iconSize = 20,
    this.semanticLabel,
    this.lockedBuilder,
  });

  /// Everything that must be available before [child] is shown.
  final List<AppCapability> requires;

  /// The real content — a step count, a streak, a chart.
  final Widget child;

  /// Sized to roughly match the glyph height of the value being replaced,
  /// so the surrounding layout doesn't jump when it unlocks.
  final double iconSize;

  final String? semanticLabel;

  /// Custom locked presentation, given a callback that runs the same
  /// resolution flow as tapping the default padlock.
  ///
  /// The default — a small padlock glyph — is right for a number inside a
  /// line of text. It is wrong for a whole card: swapping the streak strip
  /// or the Track tab for a 20px icon leaves a hole in the layout. Those
  /// surfaces pass their own locked state here, keeping their shape and
  /// explaining what tapping will do.
  final Widget Function(BuildContext context, VoidCallback resolve)?
      lockedBuilder;

  @override
  ConsumerState<MetricLock> createState() => _MetricLockState();
}

class _MetricLockState extends ConsumerState<MetricLock> {
  bool _busy = false;

  Future<void> _onTap() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final service = ref.read(capabilityServiceProvider);
      for (final capability in widget.requires) {
        if (await service.isUnlocked(capability)) continue;

        final outcome = await service.resolve(capability);
        if (outcome == LockOutcome.sentToSettings) {
          // The OS is done prompting for this one, so Settings is the only
          // route left. Explain which toggle first: dropping someone onto
          // a page of switches with no idea which one we wanted reads as
          // the app malfunctioning, not as a task.
          if (!mounted) break;
          final go = await showPermissionHelpSheet(context, capability);
          if (!go) break;
          await openAppSettings();
          // Stop here either way. Queueing another system alert behind an
          // app switch produces a prompt the user meets on return with no
          // memory of what asked for it.
          break;
        }
        if (outcome == LockOutcome.refused) break;
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        // Re-probe every lock on screen, not just this one. Granting
        // Motion from the Home lock also unlocks the streak and battles.
        ref.read(capabilityRefreshProvider.notifier).state++;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!CapabilityLocks.enabled) return widget.child;

    // A capability still loading counts as unlocked: a metric that flashes
    // a padlock on every cold start before settling on a number reads as a
    // bug. Being briefly right is better than being briefly wrong.
    final locked = widget.requires.any((c) =>
        ref.watch(capabilityUnlockedProvider(c)).valueOrNull == false);

    if (!locked) return widget.child;

    final custom = widget.lockedBuilder;
    if (custom != null) return custom(context, () => _onTap());

    return Semantics(
      button: true,
      label: widget.semanticLabel ?? 'Locked. Tap to allow access.',
      child: InkWell(
        onTap: _busy ? null : _onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: _busy
              ? SizedBox(
                  width: widget.iconSize,
                  height: widget.iconSize,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(AppColors.primary),
                  ),
                )
              : Icon(
                  Icons.lock_outline_rounded,
                  size: widget.iconSize,
                  color: AppColors.primary.withValues(alpha: 0.75),
                ),
        ),
      ),
    );
  }
}


/// Card-sized locked state: keeps the surface's footprint, says what is
/// behind it, and resolves on tap.
///
/// Used by surfaces where a bare padlock would leave a hole — the streak
/// strip, the battles tab, the Track tab. Deliberately plain: this is not
/// an upsell, it is a thing the user can have for one tap, so it gets a
/// neutral card rather than anything that reads as a promotion.
class LockedCardBody extends StatelessWidget {
  const LockedCardBody({
    super.key,
    required this.title,
    required this.body,
    required this.onTap,
    this.actionLabel = 'Allow access',
  });

  final String title;
  final String body;
  final VoidCallback onTap;
  final String actionLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Ink(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.4),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.lock_outline_rounded,
                    size: 18,
                    color: AppColors.primary.withValues(alpha: 0.8),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: AppColors.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                body,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                actionLabel,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
