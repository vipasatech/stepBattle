import 'package:flutter/material.dart';
import '../config/colors.dart';
import '../models/mission_model.dart';
import '../models/user_mission_progress_model.dart';
import '../widgets/bottom_sheet_handle.dart';
import '../widgets/fire_particles.dart';
import '../widgets/glass_card.dart';
import '../widgets/progress_bar.dart';

/// Full mission detail sheet — triggered by tapping any mission card.
class MissionDetailSheet extends StatelessWidget {
  final MissionModel mission;
  final UserMissionProgress? progress;

  const MissionDetailSheet({
    super.key,
    required this.mission,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = progress?.progressFraction ?? 0.0;
    final isComplete = progress?.isCompleted ?? false;

    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
          children: [
            const BottomSheetHandle(),

            // Hero — for streak-category missions (the daily_streak
            // "Keep Streak Alive" one users land on from the profile
            // → streak sheet → daily-mission link), render the exact
            // same bare-flame + FireParticles hero the streak sheet
            // uses so the two surfaces read as one continuous flow.
            // Other mission categories keep the tinted-disc + category
            // icon look — that fits their content.
            Center(
              child: mission.category == MissionCategory.streak
                  ? _StreakFlameHero()
                  : Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.2),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color:
                                AppColors.primary.withValues(alpha: 0.3)),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primary.withValues(alpha: 0.4),
                            blurRadius: 25,
                          ),
                        ],
                      ),
                      child: Icon(
                        _categoryIcon(mission.category),
                        color: AppColors.primary,
                        size: 30,
                      ),
                    ),
            ),
            const SizedBox(height: 16),
            Center(
              child: Text(
                mission.title,
                style: theme.textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: isComplete
                      ? AppColors.success.withValues(alpha: 0.1)
                      : AppColors.amber.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isComplete
                        ? AppColors.success.withValues(alpha: 0.2)
                        : AppColors.amber.withValues(alpha: 0.2),
                  ),
                ),
                child: Text(
                  isComplete ? 'COMPLETED \u2713' : 'IN PROGRESS',
                  style: TextStyle(
                    fontFamily: 'Manrope',
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: isComplete ? AppColors.success : AppColors.amber,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 28),

            // Progress card
            GlassCard(
              padding: const EdgeInsets.all(18),
              borderRadius: 20,
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('CURRENT PROGRESS',
                              style: theme.textTheme.labelSmall?.copyWith(
                                  color: AppColors.onSurfaceVariant,
                                  letterSpacing: 1.5)),
                          const SizedBox(height: 4),
                          Text(
                            progress?.progressLabel ??
                                '0 / ${mission.targetValue}',
                            style: theme.textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                      Text(
                        progress?.percentLabel ?? '0%',
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  StepProgressBar(
                    progress: fraction,
                    height: 10,
                    showSpark: !isComplete,
                    startColor: isComplete ? AppColors.success : null,
                    endColor: isComplete ? AppColors.success : null,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // Detail row — XP reward + Resets In. Category and
            // Difficulty were previously in a second row here but
            // added noise without informational value (2026-08-31
            // user feedback). Reset time is now computed from the
            // actual local clock instead of the pre-existing
            // "4h 22m" / "Sunday" hardcoded string.
            Row(
              children: [
                Expanded(
                  child: _DetailItem(
                    label: 'XP Reward',
                    icon: Icons.military_tech,
                    iconColor: AppColors.success,
                    value: '+${mission.xpReward} XP',
                    valueColor: AppColors.success,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _DetailItem(
                    label: 'Resets In',
                    icon: Icons.schedule,
                    iconColor: AppColors.amber,
                    value: _resetInLabel(mission.type),
                    valueColor: AppColors.amber,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 28),

            // How it works
            Text('How it works',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainerHigh.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                'StepBattle automatically tracks your movement using your device\'s '
                'pedometer. You can also sync data from Apple Health or Google Fit '
                'to ensure every step in your daily routine contributes to your '
                'competitive standing.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.onSurfaceVariant,
                  height: 1.6,
                ),
              ),
            ),

            const SizedBox(height: 28),

            // CTA button
            SizedBox(
              width: double.infinity,
              height: 56,
              child: isComplete
                  ? FilledButton.icon(
                      onPressed: null,
                      icon: const Icon(Icons.check, size: 20),
                      label:
                          Text('Completed \u2713 · +${mission.xpReward} XP Earned'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.success,
                        disabledBackgroundColor:
                            AppColors.success.withValues(alpha: 0.6),
                        disabledForegroundColor: Colors.white,
                      ),
                    )
                  : FilledButton.icon(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.directions_walk, size: 20),
                      label: const Text('Go Walk Now'),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _categoryIcon(MissionCategory cat) => switch (cat) {
        MissionCategory.steps => Icons.directions_walk,
        MissionCategory.battle => Icons.bolt,
        MissionCategory.streak => Icons.local_fire_department,
        MissionCategory.calories => Icons.whatshot,
      };

  // `_difficultyLabel` was used by the removed Difficulty detail row.
  // Kept commented for reference; delete when the sheet is confirmed
  // stable in production.
  // String _difficultyLabel(String d) => switch (d) { ... };

  /// Live label for the "Resets In" detail. Daily missions reset at
  /// the user's LOCAL midnight, weekly missions at the upcoming
  /// Sunday's local midnight. Previously hardcoded to "4h 22m" / the
  /// literal string "Sunday", which was wrong for every user and
  /// every clock reading. 2026-08-31 fix.
  String _resetInLabel(MissionType type) {
    final now = DateTime.now();
    // Local midnight = the start of the NEXT calendar day at 00:00.
    final tomorrow = DateTime(now.year, now.month, now.day)
        .add(const Duration(days: 1));
    Duration until;
    if (type == MissionType.daily) {
      until = tomorrow.difference(now);
    } else {
      // Weekly missions reset at the next Sunday midnight.
      // DateTime.weekday: Mon=1..Sun=7.
      final daysToSunday = (7 - now.weekday) % 7;
      final nextSunday = DateTime(now.year, now.month, now.day)
          .add(Duration(days: daysToSunday == 0 ? 7 : daysToSunday));
      until = nextSunday.difference(now);
    }
    final hours = until.inHours;
    final minutes = until.inMinutes.remainder(60);
    if (until.inDays >= 1) {
      final days = until.inDays;
      final remHours = until.inHours.remainder(24);
      return remHours > 0 ? '${days}d ${remHours}h' : '${days}d';
    }
    if (hours > 0) return '${hours}h ${minutes}m';
    return '${minutes}m';
  }
}

/// Flame hero for streak-category missions \u2014 matches the Home streak
/// strip + streak-history sheet's hero exactly (bare flame icon +
/// FireParticles rising, no circular glow disc). Colour tracks the
/// streak's active/dormant state; here it's always the celebratory
/// orange because the mission's "resets in" affordance means the
/// user is actively viewing it.
class _StreakFlameHero extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 96,
      height: 96,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: -28,
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: FireParticles(
                colour: AppColors.streakActive.withValues(alpha: 0.9),
              ),
            ),
          ),
          Icon(
            Icons.local_fire_department,
            color: AppColors.streakActive,
            size: 56,
          ),
        ],
      ),
    );
  }
}

class _DetailItem extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color iconColor;
  final String value;
  final Color? valueColor;

  const _DetailItem({
    required this.label,
    required this.icon,
    required this.iconColor,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant, letterSpacing: 1.5)),
        const SizedBox(height: 6),
        Row(
          children: [
            Icon(icon, size: 18, color: iconColor),
            const SizedBox(width: 6),
            Text(value,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: valueColor ?? AppColors.onSurface,
                  fontWeight: FontWeight.w700,
                )),
          ],
        ),
      ],
    );
  }
}
