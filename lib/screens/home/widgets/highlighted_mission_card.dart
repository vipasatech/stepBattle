import 'package:flutter/material.dart';

import '../../../config/colors.dart';
import '../../../providers/mission_provider.dart';
import '../../../sheets/mission_detail_sheet.dart';
import '../../../widgets/glass_card.dart';
import '../../../widgets/progress_bar.dart';

/// Single featured-mission card — big title, description, XP pill,
/// progress bar, "View mission ›" affordance. Tapping opens the
/// mission-detail bottom sheet.
///
/// Rendered by:
///   • Home tab (stacked when there are multiple; via `HighlightedMissionsSection`)
///   • Missions page (full scroll list; via `MissionsPage`)
class HighlightedMissionCard extends StatelessWidget {
  final HomeMissionEntry entry;

  /// Suppresses the tap → mission-detail sheet. Used by the back
  /// cards in a stacked deck (only the front card should be tappable).
  final bool ignoreTap;

  const HighlightedMissionCard({
    super.key,
    required this.entry,
    this.ignoreTap = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mission = entry.mission;
    final fraction = entry.progress?.progressFraction ?? 0.0;

    Widget card = GlassCard(
      padding: const EdgeInsets.all(16),
      borderRadius: 20,
      border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.flag_rounded,
                    size: 20, color: AppColors.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  mission.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.tertiary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color:
                          AppColors.tertiary.withValues(alpha: 0.45)),
                ),
                child: Text(
                  '+${mission.xpReward} XP',
                  style: TextStyle(
                    color: AppColors.tertiary,
                    fontFamily: 'Manrope',
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ],
          ),
          if (mission.description.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              mission.description,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 14),
          StepProgressBar(progress: fraction, height: 10),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                '${_fmt(entry.currentValue)} / ${_fmt(mission.targetValue)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: AppColors.onSurface,
                ),
              ),
              const Spacer(),
              Text(
                'View mission ›',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ),
    );

    if (ignoreTap) return card;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _openDetail(context),
        child: card,
      ),
    );
  }

  void _openDetail(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => MissionDetailSheet(
        mission: entry.mission,
        progress: entry.progress,
      ),
    );
  }

  static String _fmt(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}
