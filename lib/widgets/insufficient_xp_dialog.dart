import 'package:flutter/material.dart';

import '../config/colors.dart';
import '../sheets/buy_xp_sheet.dart';

/// Modal shown when the user tries to CREATE or ACCEPT a stake battle
/// but their `total_xp` is below the required stake. Two actions:
///
///   • **Buy XP** — dismisses the dialog and opens the existing
///     [BuyXpSheet], pre-focused on packs that would clear the deficit.
///   • **Later**  — dismisses the dialog and returns to the caller
///     without side effects. Caller should NOT proceed with the
///     battle create / accept.
///
/// Returns `true` when the user tapped Buy XP (caller may want to
/// leave its own sheet open until the purchase completes), `false`
/// otherwise. Never throws — dismissing via back-button also returns
/// false.
///
/// Copy explicitly names the deficit so users know how much they
/// need, not just that "it's not enough." Numbers formatted with
/// comma grouping for readability.
Future<bool> showInsufficientXpDialog(
  BuildContext context, {
  required int required,
  required int balance,
  required String action, // "create this battle" / "accept this invite"
}) async {
  final deficit = (required - balance).clamp(0, required);
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      title: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppColors.amber.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.bolt_outlined,
              color: AppColors.amber,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              'Not enough XP',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "You need ${_fmt(required)} XP to $action, but you only have "
            "${_fmt(balance)}.",
            style: TextStyle(
              color: AppColors.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.amber.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.amber.withValues(alpha: 0.35),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.trending_up,
                    color: AppColors.amber, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "Buy ${_fmt(deficit)} XP to unlock this action.",
                    style: TextStyle(
                      color: AppColors.amber,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          style: TextButton.styleFrom(
            foregroundColor: AppColors.onSurfaceVariant,
          ),
          child: const Text('Later'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
          ),
          child: const Text('Buy XP'),
        ),
      ],
    ),
  );
  final tappedBuy = result == true;
  if (tappedBuy && context.mounted) {
    // Open the existing Buy-XP bottom sheet the same way every other
    // caller does — never write a bespoke second entry point.
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const BuyXpSheet(),
    );
  }
  return tappedBuy;
}

String _fmt(int n) {
  if (n < 1000) return '$n';
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}
