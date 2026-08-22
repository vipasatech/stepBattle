import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/colors.dart';
import '../providers/subscription_provider.dart';

/// Confirm dialog shown when the creator taps "Team battle" in the New
/// Battle sheet. Explains that a battle-create entry gets consumed and
/// shows how many remain. Return value is `true` if the user tapped
/// "Use entry & open", `false` (or null) otherwise.
Future<bool> showTeamBattleConfirmDialog(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (_) => const _TeamBattleConfirmDialog(),
  );
  return result == true;
}

class _TeamBattleConfirmDialog extends ConsumerWidget {
  const _TeamBattleConfirmDialog();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        FilledButton(
          onPressed: hasEntries
              ? () => Navigator.of(context).pop(true)
              : null,
          child: const Text('Use entry & open'),
        ),
      ],
    );
  }
}
