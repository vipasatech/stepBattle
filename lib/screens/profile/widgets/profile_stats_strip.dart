import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config/colors.dart';
import '../../../config/motion.dart';
import '../../../models/user_model.dart';
import '../../../providers/battle_provider.dart';
import '../../../providers/leaderboard_provider.dart';
import '../../../providers/step_provider.dart';
import '../../../services/streak_celebration_bus.dart';
import '../../../sheets/buy_xp_sheet.dart';
import '../../../sheets/streak_history_sheet.dart';
import '../../../widgets/streak_grey_tooltip.dart';

/// Five plain-text stats across the top of Profile, matching the
/// Strava profile pattern exactly: tiny gray LABEL on top, big bold
/// VALUE below, evenly spaced across the row. No boxes, no icons,
/// no pills — just numbers.
///
/// Order (per user spec): Level · B/W · XP · Streak · Rank
///
/// The XP entry is tappable (opens the buy-XP sheet) and gets a
/// primary-colored value tint to hint that it's actionable — the
/// animated sweep pill lives up on the Home AppBar where it's the
/// star of that surface. Streak is also tappable (opens the streak
/// history sheet).
class ProfileStatsStrip extends ConsumerWidget {
  final UserModel user;
  const ProfileStatsStrip({super.key, required this.user});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rankAsync = ref.watch(myRankProvider);
    final rank = rankAsync.valueOrNull?.rank ?? 0;
    final stats = ref.watch(battleWinStatsProvider(user.userId)).valueOrNull;
    final ratio = stats == null ? null : battleWinRatioOf(stats);
    // Today-mission-done drives the tooltip copy so it doesn't say
    // "hit your step goal" once the user already has.
    final todaySteps = ref.watch(todayStepsProvider);
    final todayMissionDone = todaySteps >= user.dailyStepGoal;

    // Matches Strava's left-aligned stats layout: items sit at their
    // natural width with a fixed gap between them. Wrapped in a
    // horizontal scroller so the row never overflows on narrow phones
    // — in the common case (5 stats, ~45 dp each, 32 dp gaps) it
    // fits without needing to scroll.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StatItem(label: 'Level', value: '${user.level}'),
          const _StatGap(),
          _StatItem(
            label: 'B/W',
            value: ratio == null ? '—' : '${(ratio * 100).round()}%',
          ),
          const _StatGap(),
          _StatItem(
            label: 'XP',
            value: _abbreviateXp(user.totalXP),
            valueColor: AppColors.primary,
            onTap: () => _openBuyXp(context),
          ),
          const _StatGap(),
          _StreakStat(
            currentStreak: user.currentStreak,
            inRecovery: user.isInStreakRecovery,
            todayMissionDone: todayMissionDone,
            onTap: () => _openStreakHistory(context),
          ),
          const _StatGap(),
          _StatItem(
            label: 'Rank',
            value: rank > 0 ? '#$rank' : '—',
          ),
        ],
      ),
    );
  }

  /// `9105` → `9.1K`. Keeps the stats row visually balanced when the
  /// XP value gets long. Under 1000 uses raw digits.
  static String _abbreviateXp(int xp) {
    if (xp < 1000) return '$xp';
    if (xp < 10000) {
      final k = xp / 1000;
      return '${k.toStringAsFixed(1)}K';
    }
    if (xp < 1000000) return '${(xp / 1000).round()}K';
    return '${(xp / 1000000).toStringAsFixed(1)}M';
  }

  static void _openBuyXp(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const BuyXpSheet(),
    );
  }

  static void _openStreakHistory(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const StreakHistorySheet(),
    );
  }
}

/// One column: LABEL (small gray, top) + VALUE (big bold, below).
/// An optional [trailingIcon] renders inline to the right of the
/// value — used for the streak flame so the number reads as "6 🔥",
/// keeping the number as the primary visual element.
class _StatItem extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final Widget? trailingIcon;
  final VoidCallback? onTap;

  const _StatItem({
    required this.label,
    required this.value,
    this.valueColor,
    this.trailingIcon,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final valueStyle = theme.textTheme.titleMedium?.copyWith(
      color: valueColor ?? AppColors.onSurface,
      fontWeight: FontWeight.w800,
      fontSize: 18,
      height: 1.1,
    );
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppColors.onSurfaceVariant,
            fontWeight: FontWeight.w500,
            fontSize: 11.5,
          ),
        ),
        const SizedBox(height: 3),
        Row(
          mainAxisSize: MainAxisSize.min,
          // End-alignment lines up the widget boxes' bottom edges.
          // The Text widget's box is ~4 dp taller than the visible
          // glyph (line-height descender space), so we lift the icon
          // 4 dp with a bottom padding — that puts the icon's visible
          // bottom on the same floor line as the number's visible
          // bottom. Adjust the `bottom` value in 1 dp steps if the
          // icon ever reads a touch too high (increase) or too low
          // (decrease) against the digits.
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(value, style: valueStyle),
            if (trailingIcon != null) ...[
              const SizedBox(width: 4),
              // Icon needs to sit slightly BELOW where CrossAxisAlignment
              // .end would place it. Iterate the y offset in 1 dp
              // steps if the icon reads a touch high (bump up) or low
              // (bump down). 1 dp is the current sweet spot.
              Transform.translate(
                offset: const Offset(0, 1),
                child: trailingIcon!,
              ),
            ],
          ],
        ),
      ],
    );
    if (onTap == null) return column;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: column,
    );
  }
}

/// Fixed horizontal gap between stat items. Matches Strava's
/// proportion — roughly 2× the value's font size — so the row reads
/// as one system, not five squashed columns.
class _StatGap extends StatelessWidget {
  const _StatGap();
  @override
  Widget build(BuildContext context) => const SizedBox(width: 34);
}

/// Streak stat — extracted from the generic _StatItem so it can:
///   • Grey the flame + number when the user is in recovery mode
///     (`streak_recovery_started_at` is set — set by the miss path
///     of the cron backstop OR by any future client-side prediction).
///   • Play a scale-bounce + count-up animation when
///     StreakCelebrationBus fires (mirror of the Home streak strip so
///     both surfaces react to the same event in sync).
class _StreakStat extends StatefulWidget {
  final int currentStreak;
  final bool inRecovery;
  final bool todayMissionDone;
  final VoidCallback onTap;

  const _StreakStat({
    required this.currentStreak,
    required this.inRecovery,
    required this.todayMissionDone,
    required this.onTap,
  });

  @override
  State<_StreakStat> createState() => _StreakStatState();
}

class _StreakStatState extends State<_StreakStat>
    with SingleTickerProviderStateMixin {
  late final AnimationController _tickController;
  StreamSubscription<StreakCelebration>? _sub;
  int? _fromStreak;
  int? _toStreak;

  @override
  void initState() {
    super.initState();
    _tickController = AnimationController(
      vsync: this,
      duration: Motion.d.xslow,
    );
    // subscribe() replays a buffered event if the credit RPC returned
    // while this widget was unmounted (e.g. Profile tab opened after
    // the animation would have fired).
    _sub = StreakCelebrationBus.instance.subscribe((event) {
      if (!mounted) return;
      if (event.streakAfter <= event.streakBefore) return;
      setState(() {
        _fromStreak = event.streakBefore;
        _toStreak = event.streakAfter;
      });
      _tickController.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _tickController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.inRecovery ? AppColors.streakGrey : AppColors.streakActive;
    return AnimatedBuilder(
      animation: _tickController,
      builder: (_, __) {
        final t = _tickController.value;
        final bounce = Motion.springBounce(t);
        int displayDays;
        if (_fromStreak != null && _toStreak != null && t < 1.0) {
          final range = _toStreak! - _fromStreak!;
          displayDays = _fromStreak! + (range * t).round();
        } else {
          displayDays = widget.currentStreak;
        }
        // Wrap the whole stat (label + number + flame) in the tooltip
        // so the tap target matches the rest of the strip. Grey path
        // → tooltip; coloured path → history sheet.
        return StreakGreyTooltip(
          enabled: widget.inRecovery,
          inRecovery: widget.inRecovery,
          todayMissionDone: widget.todayMissionDone,
          onTapWhenDisabled: widget.onTap,
          child: _StatItem(
            label: 'Streak',
            value: '$displayDays',
            valueColor: widget.inRecovery ? AppColors.streakGrey : null,
            trailingIcon: Transform.scale(
              scale: bounce,
              child: Icon(
                Icons.local_fire_department,
                color: accent,
                size: 18,
              ),
            ),
            // Tap handled by StreakGreyTooltip wrapper.
          ),
        );
      },
    );
  }
}
