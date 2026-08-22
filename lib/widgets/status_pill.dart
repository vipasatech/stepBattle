import 'package:flutter/material.dart';
import '../config/colors.dart';

enum StatusType { live, ending, pending, won, lost, inProgress, completed, locked, full }

/// Compact status indicator pill used on battle cards, mission rows, etc.
class StatusPill extends StatelessWidget {
  final StatusType type;

  const StatusPill({super.key, required this.type});

  @override
  Widget build(BuildContext context) {
    final (label, bgColor, textColor, showDot) = switch (type) {
      StatusType.live => ('Live', AppColors.success.withValues(alpha: 0.1), AppColors.success, true),
      // 'Ending…' — battle end_time has passed, waiting for the server
      // cron (process_battle_lifecycle → settle_stake_battle) to credit
      // the pot and flip status to completed. Typically resolves within
      // ~60 s. Amber-with-dot so users read it as "in transition, not
      // stuck." Replaces the client-side auto-complete that used to
      // race the cron and lose pot payouts (see battle_service.dart —
      // completeExpiredBattles was removed in 1.1.6+29).
      StatusType.ending => ('Ending…', AppColors.amber.withValues(alpha: 0.1), AppColors.amber, true),
      StatusType.pending => ('Pending', AppColors.amber.withValues(alpha: 0.1), AppColors.amber, false),
      StatusType.won => ('Won', AppColors.success.withValues(alpha: 0.1), AppColors.success, false),
      StatusType.lost => ('Lost', AppColors.error.withValues(alpha: 0.1), AppColors.error, false),
      StatusType.inProgress => ('In Progress', AppColors.secondary.withValues(alpha: 0.1), AppColors.secondary, true),
      StatusType.completed => ('Completed', AppColors.success.withValues(alpha: 0.1), AppColors.success, false),
      StatusType.locked => ('Locked', AppColors.onSurfaceVariant.withValues(alpha: 0.1), AppColors.onSurfaceVariant, false),
      StatusType.full => ('Full', AppColors.errorContainer, AppColors.error, false),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showDot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: textColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Manrope',
              fontSize: 10,
              fontWeight: FontWeight.w900,
              color: textColor,
              letterSpacing: -0.3,
            ),
          ),
        ],
      ),
    );
  }
}
