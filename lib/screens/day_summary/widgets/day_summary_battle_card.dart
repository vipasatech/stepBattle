import 'package:flutter/material.dart';

import '../../../config/colors.dart';
import '../../../models/battle_model.dart';

/// Rich per-day battle card used inside `DaySummaryScreen`.
///
/// Layout (per the reference image the user shared):
///   ┌────────────────────────────────────────────┐
///   │ BATTLE #XXXX              [DAILY] [•Live]  │
///   │                                              │
///   │  ⚔ You vs {opponentFriendlyName}            │
///   │                                              │
///   │  You                    {opponentFriendly}  │
///   │  1,803                             3,493    │
///   │  ▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░   │
///   │                                              │
///   │  8h 15m left                +200 XP on win  │
///   └────────────────────────────────────────────┘
///
/// Read-only — no tap handler. Designed for 1v1 battles (`oneVsOne`
/// type). Group / team battles fall back to the compact `_BattleTile`
/// in `DaySummaryScreen` because "You vs X" and single-opponent step
/// deltas don't map cleanly to them.
class DaySummaryBattleCard extends StatelessWidget {
  final BattleModel battle;
  final String uid;

  const DaySummaryBattleCard({
    super.key,
    required this.battle,
    required this.uid,
  });

  // `final`, not `const` — AppColors.* are theme-aware getters that
  // resolve at runtime.
  static final Color _accentYou = AppColors.primary;
  static final Color _accentOpponent = AppColors.amber;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final me = battle.participantFor(uid);
    final opponent = battle.opponentFor(uid);
    // Defensive fallback — the sheet only routes 1v1 battles here, but
    // a group battle rendered by accident should still show something.
    if (me == null || opponent == null) {
      return const SizedBox.shrink();
    }

    final isLive = battle.status == BattleStatus.active;
    final isCompleted = battle.status == BattleStatus.completed;
    final iWon = isCompleted && battle.winnerId == uid;
    final youSteps = me.currentSteps;
    final opponentSteps = opponent.currentSteps;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: AppColors.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ---- Header ------------------------------------------------
          Row(
            children: [
              Expanded(
                child: Text(
                  'BATTLE ID ${battle.shortId}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: AppColors.onSurfaceVariant,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              // "DAILY" recurrence tag when this battle is one instance
              // of a repeating daily series.
              if (battle.seriesId != null) ...[
                _OutlinedPill(
                  label: 'DAILY',
                  color: theme.colorScheme.onSurface,
                ),
                const SizedBox(width: 8),
              ],
              _StatusPill(
                isLive: isLive,
                isCompleted: isCompleted,
                iWon: iWon,
              ),
            ],
          ),

          const SizedBox(height: 12),

          // ---- Title -------------------------------------------------
          Row(
            children: [
              Icon(Icons.close_rounded,
                  size: 22,
                  color: AppColors.onSurfaceVariant.withValues(alpha: 0.8)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'You vs ${opponent.friendlyName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),

          // ---- Score labels ------------------------------------------
          Row(
            children: [
              Expanded(
                child: Text(
                  'You',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: _accentYou,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              Text(
                opponent.friendlyName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: _accentOpponent,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),

          // ---- Score values ------------------------------------------
          Row(
            children: [
              Expanded(
                child: Text(
                  _fmt(youSteps),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: _accentYou,
                    fontWeight: FontWeight.w900,
                    fontFamily: 'Manrope',
                    height: 1.0,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
              Text(
                _fmt(opponentSteps),
                textAlign: TextAlign.right,
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: _accentOpponent,
                  fontWeight: FontWeight.w900,
                  fontFamily: 'Manrope',
                  height: 1.0,
                  letterSpacing: -0.5,
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),

          // ---- Progress bar ------------------------------------------
          _ScoreBar(
            youSteps: youSteps,
            opponentSteps: opponentSteps,
            youColor: _accentYou,
            opponentColor: _accentOpponent,
          ),

          const SizedBox(height: 12),

          // ---- Footer ------------------------------------------------
          Row(
            children: [
              Expanded(
                child: Text(
                  _footerLeft(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '+${battle.xpReward} XP on win',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _accentOpponent,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Left-side footer text depending on battle state:
  ///   • live         → "8h 15m left" (from `timeRemainingLabel`)
  ///   • completed    → "Ended {date}"
  ///   • other        → the raw remaining-time label
  String _footerLeft() {
    if (battle.status == BattleStatus.completed) {
      // Compact end-date: "Ended Jul 1"
      final end = battle.endTime.toLocal();
      const months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ];
      return 'Ended ${months[end.month - 1]} ${end.day}';
    }
    return battle.timeRemainingLabel;
  }

  static String _fmt(int n) {
    if (n == 0) return '0';
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}

/// Right-side status pill on the header row:
///   • Live battle       → green "•Live"
///   • Won   (completed) → green "Won"
///   • Lost  (completed) → red "Lost"
///   • Anything else     → nothing
class _StatusPill extends StatelessWidget {
  final bool isLive;
  final bool isCompleted;
  final bool iWon;
  const _StatusPill({
    required this.isLive,
    required this.isCompleted,
    required this.iWon,
  });

  @override
  Widget build(BuildContext context) {
    if (isLive) {
      return _FilledPill(
        label: 'Live',
        color: AppColors.success,
        showDot: true,
      );
    }
    if (isCompleted) {
      return _FilledPill(
        label: iWon ? 'Won' : 'Lost',
        color: iWon ? AppColors.success : AppColors.error,
      );
    }
    return const SizedBox.shrink();
  }
}

class _FilledPill extends StatelessWidget {
  final String label;
  final Color color;
  final bool showDot;

  const _FilledPill({
    required this.label,
    required this.color,
    this.showDot = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showDot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontFamily: 'Manrope',
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _OutlinedPill extends StatelessWidget {
  final String label;
  final Color color;
  const _OutlinedPill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.55), width: 1.2),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontFamily: 'Manrope',
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

/// Two-tone progress bar showing the step share between the user and
/// their opponent. Zero-vs-zero renders an empty rail.
class _ScoreBar extends StatelessWidget {
  final int youSteps;
  final int opponentSteps;
  final Color youColor;
  final Color opponentColor;

  const _ScoreBar({
    required this.youSteps,
    required this.opponentSteps,
    required this.youColor,
    required this.opponentColor,
  });

  @override
  Widget build(BuildContext context) {
    final total = youSteps + opponentSteps;
    // Fall back to 50/50 emptiness when neither side has stepped yet
    // so the bar doesn't render as a solid single-colour rail.
    final youFrac = total == 0 ? 0.0 : youSteps / total;
    final opponentFrac = total == 0 ? 0.0 : opponentSteps / total;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 10,
        color: AppColors.onSurface.withValues(alpha: 0.08),
        child: Row(
          children: [
            if (youFrac > 0)
              Expanded(
                flex: (youFrac * 1000).round(),
                child: Container(color: youColor),
              ),
            if (opponentFrac > 0)
              Expanded(
                flex: (opponentFrac * 1000).round(),
                child: Container(color: opponentColor),
              ),
          ],
        ),
      ),
    );
  }
}
