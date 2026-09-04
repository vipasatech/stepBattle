import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/colors.dart';
import '../providers/auth_provider.dart';
import '../providers/step_provider.dart';
import '../providers/user_provider.dart';
import '../services/goal_formula.dart';
import '../widgets/bottom_sheet_handle.dart';
import '../widgets/fire_particles.dart';
import 'streak_share_sheet.dart';
import 'todays_mission_sheet.dart';

/// Streak history sheet — current streak, best streak, streak-mechanic
/// explanation, and a one-tap route to today's daily mission (the only
/// input that actually grows the streak; see
/// `MissionService.advanceDailyProgress` + migration 0045).
///
/// 2026-08-30 rewrite:
///   • **Hero** — the flame now uses the same `FireParticles` overlay
///     as the Home streak strip so both surfaces read as one system.
///   • **Copy** — "How Streaks Work" rewritten to describe the actual
///     server-side rule ("hit your daily step goal → +1 streak") plus
///     the 2-day recovery window. The prior copy suggested "log any
///     step" and "you don't need to hit your goal", both of which
///     directly contradict `advance_daily_progress`.
///   • **Inline nav** — the phrase "daily mission" in the first bullet
///     is a tappable violet link that closes this sheet and opens the
///     daily-mission `MissionDetailSheet`, since the streak advances
///     when THAT mission completes.
///   • **Primary CTA** — a big violet "Open Today's Mission" button at
///     the bottom mirrors the inline link for users who scan past the
///     copy. Copy shifts to "View Today's Mission — Complete ✓" when
///     already done.
///   • **Recovery banner** — an amber card appears only when
///     `isInStreakRecovery == true`; picks up the copy the tooltip
///     used to carry via `StreakGreyTooltip.messageFor`.
///   • **Milestone chip** — corrected from `7 - (n % 7)` to
///     `25 - (n % 25)`; the actual server bonus fires every 25th day.
class StreakHistorySheet extends ConsumerWidget {
  const StreakHistorySheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final current = profile?.currentStreak ?? 0;
    final best = profile?.bestStreak ?? 0;
    // Same signal as Home / Profile: grey when in recovery, orange
    // otherwise. Single source of truth via AppColors.streak*.
    final inRecovery = profile?.isInStreakRecovery ?? false;
    final flameColor =
        inRecovery ? AppColors.streakGrey : AppColors.streakActive;

    // Detect today's mission completion via the SAME data sources the
    // Home DailyTargetCard uses — steps vs. dailyStepGoal — instead of
    // reading the `daily_streak` catalog mission's boolean progress
    // row. Rationale: opening the mission detail sheet used to render
    // "0/1" progress (catalog target is 1 = "complete once") which
    // confused users staring at their actual 2,113/2,500 step count on
    // Home. We now open [TodaysMissionSheet] which mirrors the Home
    // card content byte-for-byte — steps, goal, km, progress bar. This
    // completion flag is used only for CTA copy ("Open" vs "View …
    // Complete ✓"), not for the sheet body.
    final goal = ref.watch(currentUserProvider.select((async) =>
                async.valueOrNull?.dailyStepGoal)) ??
            GoalFormula.fallback.target;
    final todaySteps = ref.watch(localTodayStepsProvider).valueOrNull ?? 0;
    final missionIsComplete = todaySteps >= goal;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      // Wrap in SafeArea + SingleChildScrollView so the content can
      // scroll when the sheet is too tall to fit the viewport (small
      // phones, large text scales, on-screen keyboard, etc.).
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const BottomSheetHandle(),

              // Hero — animated flame with rising particles, matching
              // the Home streak strip's signature look. FireParticles
              // is self-animating (owns its own ticker) so the sheet
              // doesn't need a stateful wrapper.
              _AnimatedFlameHero(colour: flameColor),
              const SizedBox(height: 16),

              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Streak',
                      style: theme.textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  // Share the current streak as a Story-sized card.
                  IconButton(
                    icon: Icon(Icons.ios_share, color: AppColors.primary),
                    tooltip: 'Share streak',
                    onPressed: () => showStreakShareSheet(
                      context,
                      currentStreak: current,
                      bestStreak: best,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Current streak
              _StreakRow(
                label: 'Current Streak',
                value: '$current days',
                icon: Icons.local_fire_department,
                iconColor: current > 0 ? flameColor : AppColors.onSurfaceVariant,
              ),
              const SizedBox(height: 14),

              // Best streak
              _StreakRow(
                label: 'Best Streak',
                value: '$best days',
                icon: Icons.emoji_events,
                iconColor: AppColors.amber,
              ),
              const SizedBox(height: 20),

              // Recovery-mode banner — only shown when the flame is
              // grey because the user missed yesterday. Absorbs the
              // tooltip content the pre-rewrite tap-on-flame surface
              // used to display, now that the tooltip also opens this
              // sheet on any tap of its body.
              if (inRecovery) ...[
                _RecoveryBanner(theme: theme),
                const SizedBox(height: 20),
              ],

              // Info card — correct copy per `advance_daily_progress`
              // (migration 0045). The phrase "daily mission" in the
              // first bullet is a tappable violet link that opens the
              // Today's Mission sheet (same as the primary CTA below).
              _HowStreaksWorkCard(
                theme: theme,
                canOpenMission: true,
                onOpenMission: () => _openDailyMission(context),
              ),

              const SizedBox(height: 20),

              // Next milestone chip — server credits +100 XP every 25
              // consecutive days (streak_milestone reason). Prior copy
              // said "every 7th day", which was wrong.
              if (current > 0) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 12),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                        color: AppColors.primary.withValues(alpha: 0.2)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.military_tech,
                          color: AppColors.primary, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Next +100 XP milestone in '
                          '${25 - (current % 25)} days',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],

              // Primary CTA — one-tap route to the Today's Mission
              // sheet (which mirrors the Home DailyTargetCard content
              // — real step count vs goal, km derivation, progress
              // bar). Copy shifts on completion so a user who already
              // hit today's goal doesn't wonder why they're being asked
              // to "open" an already-done task.
              _OpenTodaysMissionButton(
                theme: theme,
                complete: missionIsComplete,
                onOpen: () => _openDailyMission(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Closes the streak sheet, then opens [TodaysMissionSheet]. Two-step
  /// (pop then push via microtask) so the mission sheet animates from
  /// a clean state rather than stacking over the tail of the
  /// streak-sheet dismissal.
  static void _openDailyMission(BuildContext context) {
    final navigator = Navigator.of(context);
    navigator.pop();
    // Root-navigator lookup so the mission sheet mounts from the
    // shell's context, not the (about-to-be-disposed) sheet's.
    final rootContext = navigator.context;
    Future.microtask(() {
      if (!rootContext.mounted) return;
      TodaysMissionSheet.show(rootContext);
    });
  }
}

// =============================================================================
// Animated flame hero — matches home strip so both surfaces read as one
// system. FireParticles is self-animating; no ticker needed here.
// =============================================================================

class _AnimatedFlameHero extends StatelessWidget {
  final Color colour;
  const _AnimatedFlameHero({required this.colour});

  @override
  Widget build(BuildContext context) {
    // Matches the Home streak-strip flame exactly — bare `Icon` +
    // `FireParticles` overlay, no circular glow disc behind it. User
    // feedback (2026-08-31): the previous soft violet disc felt like
    // an extra widget-inside-a-widget, whereas Home's flame just sits
    // in the strip with rising embers. Same treatment here so the two
    // surfaces read as one system.
    return SizedBox(
      width: 96,
      height: 96,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          // Rising particles — paint extends above the SizedBox via
          // Positioned + clipBehavior:none so particles have visible
          // "sky" to travel through.
          Positioned(
            top: -28,
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: FireParticles(
                colour: colour.withValues(alpha: 0.9),
              ),
            ),
          ),
          Icon(
            Icons.local_fire_department,
            color: colour,
            size: 56,
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Recovery-mode banner — shown only when the flame is grey because the
// user missed yesterday. Reads sensibly whether today's mission is done
// or not (mirrors StreakGreyTooltip.messageFor branches).
// =============================================================================

class _RecoveryBanner extends ConsumerWidget {
  final ThemeData theme;
  const _RecoveryBanner({required this.theme});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final dailyGoal = profile?.dailyStepGoal ?? 8000;
    // We compute todayMissionDone from steps rather than reading the
    // per-mission progress row, since the recovery message is really
    // about "did the daily goal cross yet?" — one number, one signal.
    final todaySteps = ref.watch(todayStepsProvider);
    final todayMissionDone = todaySteps >= dailyGoal;

    final message = todayMissionDone
        ? "You missed yesterday. Keep the momentum tomorrow to save the streak."
        : "You missed yesterday, and today's mission isn't done yet. "
            "Hit your step goal to save the streak.";

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.amber.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.amber.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.access_time_filled_rounded,
              color: AppColors.amber, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Recovery Mode',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: AppColors.amber,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.onSurface,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// "How Streaks Work" card — corrected copy + inline tappable
// "daily mission" link in the first bullet.
// =============================================================================

class _HowStreaksWorkCard extends StatelessWidget {
  final ThemeData theme;
  final bool canOpenMission;
  final VoidCallback? onOpenMission;
  const _HowStreaksWorkCard({
    required this.theme,
    required this.canOpenMission,
    required this.onOpenMission,
  });

  @override
  Widget build(BuildContext context) {
    final baseStyle = theme.textTheme.bodySmall?.copyWith(
      color: AppColors.onSurfaceVariant,
      height: 1.7,
    );
    // Link styling: no underline (looks cluttered inside a bullet line).
    // Discoverability comes from the violet colour + bolder weight + the
    // inline `›` chevron appended right after the phrase. 2026-08-31
    // per user feedback — the underline read as "web link", not "app
    // affordance".
    final linkStyle = baseStyle?.copyWith(
      color: AppColors.primary,
      fontWeight: FontWeight.w800,
    );

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('How Streaks Work',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          // Bullet 1 — RichText so the phrase "daily mission" is the
          // only tap target (not the whole line).
          RichText(
            text: TextSpan(
              style: baseStyle,
              children: [
                const TextSpan(text: '• Hit your daily step goal in your '),
                if (canOpenMission && onOpenMission != null) ...[
                  TextSpan(
                    text: 'daily mission',
                    style: linkStyle,
                    recognizer: TapGestureRecognizer()..onTap = onOpenMission,
                  ),
                  TextSpan(text: ' ›', style: linkStyle),
                ] else
                  const TextSpan(text: 'daily mission'),
              ],
            ),
          ),
          const SizedBox(height: 6),
          // Rest of the bullets — plain text, matches server behaviour.
          Text(
            '• Complete it every day to grow your streak by 1\n'
            '• Miss a day? You have a 2-day recovery window to save it\n'
            '• Miss recovery too? Streak resets to 0\n'
            '• +100 XP each day you complete your daily mission\n'
            '• +100 XP milestone bonus every 25 days (25, 50, 75…)',
            style: baseStyle,
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Primary CTA — big violet button at the bottom. Copy branches on
// mission completion; taps close this sheet and open the mission sheet
// via the shared helper on StreakHistorySheet._openDailyMission.
// =============================================================================

class _OpenTodaysMissionButton extends StatelessWidget {
  final ThemeData theme;
  final bool complete;
  final VoidCallback? onOpen;
  const _OpenTodaysMissionButton({
    required this.theme,
    required this.complete,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    // No loading state — the Today's Mission sheet reads steps + goal
    // directly from local providers (both zero-lag), so we can always
    // offer to open it. Copy still swaps based on completion so the
    // CTA never asks the user to "open" a mission they've already
    // finished.
    final label = complete
        ? 'View Today\'s Mission — Complete ✓'
        : "Open Today's Mission";
    final enabled = onOpen != null;

    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor:
              AppColors.primary.withValues(alpha: 0.35),
          disabledForegroundColor:
              Colors.white.withValues(alpha: 0.75),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
          padding: const EdgeInsets.symmetric(vertical: 16),
          minimumSize: const Size.fromHeight(56),
        ),
        onPressed: enabled ? onOpen : null,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
            if (!complete) ...[
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right, size: 22, color: Colors.white),
            ],
          ],
        ),
      ),
    );
  }
}

class _StreakRow extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color iconColor;

  const _StreakRow({
    required this.label,
    required this.value,
    required this.icon,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.onSurface.withValues(alpha: 0.05)),
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 24),
          const SizedBox(width: 14),
          Expanded(
            child: Text(label,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: AppColors.onSurfaceVariant)),
          ),
          Text(value,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              )),
        ],
      ),
    );
  }
}
