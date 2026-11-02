import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/colors.dart';
import '../features/onboarding_tour/tour_controller.dart';
import '../features/onboarding_tour/tour_step.dart';
import '../features/onboarding_tour/tour_target.dart';
import '../providers/subscription_provider.dart';

/// Confirm dialog shown when the creator taps "Team battle" in the New
/// Battle sheet. Explains that a battle-create entry gets consumed and
/// shows how many remain. Return value is `true` if the user tapped
/// "Use entry & open", `false` (or null) otherwise.
///
/// Tour mode (2026-09-22): callers can pass `useRootNavigator: false`
/// + `barrierColor: Colors.transparent` + a named `routeSettings` so
/// the dialog renders UNDER the shell-mounted `OnboardingTourOverlay`
/// (which sits above the shell's non-root navigator). The default
/// non-tour path leaves these at Flutter's `showDialog` defaults —
/// same behaviour as before.
Future<bool> showTeamBattleConfirmDialog(
  BuildContext context, {
  bool useRootNavigator = true,
  Color? barrierColor,
  RouteSettings? routeSettings,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    useRootNavigator: useRootNavigator,
    barrierColor: barrierColor,
    routeSettings: routeSettings,
    builder: (_) => const _TeamBattleConfirmDialog(),
  );
  return result == true;
}

class _TeamBattleConfirmDialog extends ConsumerStatefulWidget {
  const _TeamBattleConfirmDialog();

  @override
  ConsumerState<_TeamBattleConfirmDialog> createState() =>
      _TeamBattleConfirmDialogState();
}

class _TeamBattleConfirmDialogState
    extends ConsumerState<_TeamBattleConfirmDialog> {
  /// Cached notifier for [tourNextInterceptorProvider]. Populated in
  /// [didChangeDependencies] so [dispose] can deregister the
  /// interceptor WITHOUT touching `ref` — Riverpod's ConsumerState
  /// disposes its `ref` before our `dispose` runs, and calling
  /// `ref.read` from here throws "Cannot use \"ref\" after the widget
  /// was disposed." A previous version of this file did exactly that
  /// (2026-09-22 afternoon log evidence), leaving the interceptor
  /// stuck in the provider map and every subsequent
  /// `tour_controller.next()` call re-firing the closure of an
  /// already-disposed dialog.
  StateController<Map<TourTargetId, Future<void> Function()>>?
      _interceptorController;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      final notifier = ref.read(tourNextInterceptorProvider.notifier);
      notifier.state = {
        ...notifier.state,
        TourTargetId.teamConfirmUseEntryButton: _handleTourNextTap,
      };
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _interceptorController ??=
        ref.read(tourNextInterceptorProvider.notifier);
  }

  @override
  void dispose() {
    // Defer the mutation to a microtask, and read the controller from
    // the field (not `ref`, which is already unusable at this point).
    // Same pattern as `TourTarget.dispose`.
    final controller = _interceptorController;
    if (controller != null) {
      Future.microtask(() {
        final current = controller.state;
        if (!current.containsKey(TourTargetId.teamConfirmUseEntryButton)) {
          return;
        }
        controller.state = {...current}
          ..remove(TourTargetId.teamConfirmUseEntryButton);
      });
    }
    super.dispose();
  }

  Future<void> _handleTourNextTap() async {
    if (!mounted) return;
    // Guard: don't pop the dialog with `true` if the user has no
    // entries left — the button itself is disabled in that state, so
    // Next shouldn't sidestep the gating. Fall through to a plain
    // advance (skip past teamConfirmDialog) in the caller instead.
    final sub = ref.read(subscriptionProvider);
    if (sub.remainingCreates <= 0) {
      Navigator.of(context).pop(false);
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sub = ref.watch(subscriptionProvider);
    // `remainingCreates` is null if the user has an unlimited plan; we
    // still confirm (so people don't accidentally start a lobby), but
    // hide the "entries left" counter.
    final entriesLeft = sub.remainingCreates;
    final hasEntries = entriesLeft > 0;

    return AlertDialog(
      backgroundColor: AppColors.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      title: Row(
        children: [
          Icon(Icons.emoji_events, color: AppColors.primary, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Start a team battle?',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "This will use 1 of your battle-create entries. You'll have "
            '10 minutes to fill teams before the lobby closes.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: AppColors.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.confirmation_number_outlined,
                    size: 16, color: AppColors.primary),
                const SizedBox(width: 8),
                Text(
                  'Entries left: $entriesLeft',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          if (!hasEntries) ...[
            const SizedBox(height: 10),
            Text(
              "You're out of battle entries for this billing period.",
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.error,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text('Cancel',
              style: TextStyle(color: AppColors.onSurfaceVariant)),
        ),
        TourTarget(
          id: TourTargetId.teamConfirmUseEntryButton,
          child: FilledButton(
            onPressed: hasEntries
                ? () => Navigator.of(context).pop(true)
                : null,
            child: const Text('Use entry & open'),
          ),
        ),
      ],
    );
  }
}
