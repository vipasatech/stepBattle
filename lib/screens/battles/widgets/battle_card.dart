import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../config/colors.dart';
import '../../../models/battle_model.dart';
import '../../../widgets/dual_fill_bar.dart';
import '../../../widgets/glass_card.dart';
import '../../../widgets/status_pill.dart';

/// Shared battle card used across active, scheduled, and completed sections.
/// [onStopRecurring] is the callback the parent passes when this battle is
/// the creator's own Daily-series instance; the parent decides whether to
/// show the option (and runs the confirm dialog + service call).
class BattleCard extends StatelessWidget {
  final BattleModel battle;
  final String currentUserId;
  final VoidCallback? onTap;
  final VoidCallback? onStopRecurring;

  /// Creator-only callback shown on pending **team** battles (Q6). Tap →
  /// parent runs the confirm dialog + service.startTeamBattle().
  final VoidCallback? onStartTeamBattle;

  const BattleCard({
    super.key,
    required this.battle,
    required this.currentUserId,
    this.onTap,
    this.onStopRecurring,
    this.onStartTeamBattle,
  });

  @override
  Widget build(BuildContext context) {
    return switch (battle.status) {
      BattleStatus.active => _ActiveCard(
          battle: battle,
          currentUserId: currentUserId,
          onTap: onTap,
          onStopRecurring: onStopRecurring),
      // 'pending' = waiting for accepts; 'scheduled' = all accepted, waiting
      // for start_time. Same card style — the card itself disambiguates the
      // status line.
      BattleStatus.pending || BattleStatus.scheduled => _ScheduledCard(
          battle: battle,
          onTap: onTap,
          onStopRecurring: onStopRecurring,
          onStartTeamBattle: onStartTeamBattle),
      BattleStatus.completed => _CompletedCard(
          battle: battle, currentUserId: currentUserId, onTap: onTap),
      BattleStatus.cancelled => const SizedBox.shrink(),
    };
  }
}

/// Small "DAILY" pill rendered next to the status pill on cards that belong
/// to a recurring series. Purely cosmetic; the stop action lives elsewhere.
class _DailyBadge extends StatelessWidget {
  const _DailyBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.tertiary.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppColors.tertiary.withValues(alpha: 0.5),
        ),
      ),
      child: const Text(
        'DAILY',
        style: TextStyle(
          color: AppColors.tertiary,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
          fontFamily: 'Manrope',
        ),
      ),
    );
  }
}

/// "PUBLIC" pill — used when `battle.visibility == public` so the surface is
/// obvious to anyone glancing at the list (Discover-feed signal).
class _PublicBadge extends StatelessWidget {
  const _PublicBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.success.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppColors.success.withValues(alpha: 0.5),
        ),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.public, size: 10, color: AppColors.success),
          SizedBox(width: 4),
          Text(
            'PUBLIC',
            style: TextStyle(
              color: AppColors.success,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              fontFamily: 'Manrope',
            ),
          ),
        ],
      ),
    );
  }
}

/// "TEAM" pill — flags team-battle cards so the topology is visible at a glance.
class _TeamBadge extends StatelessWidget {
  const _TeamBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.secondary.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppColors.secondary.withValues(alpha: 0.5),
        ),
      ),
      child: const Text(
        'TEAM',
        style: TextStyle(
          color: AppColors.secondary,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.2,
          fontFamily: 'Manrope',
        ),
      ),
    );
  }
}

/// Tap-to-copy shareable join code. Surfaces on pending battle cards so the
/// creator can grab the code at any time — not just from the post-create
/// dialog (which is easy to dismiss and lose).
class _JoinCodeChip extends StatelessWidget {
  final String code;
  const _JoinCodeChip({required this.code});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: code));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Code $code copied'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.secondary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: AppColors.secondary.withValues(alpha: 0.35),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.key, size: 12, color: AppColors.secondary),
            const SizedBox(width: 6),
            Text(
              code,
              style: const TextStyle(
                color: AppColors.secondary,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
                fontSize: 12,
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.content_copy,
                size: 11, color: AppColors.secondary),
          ],
        ),
      ),
    );
  }
}

/// Stacked per-team summary used inside active/scheduled/completed cards
/// for team battles. Shows each team name + its step total + member count;
/// the leading team is tinted brighter.
class _TeamSummary extends StatelessWidget {
  final BattleModel battle;
  const _TeamSummary({required this.battle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labels = battle.teamLabels;
    if (labels.isEmpty) return const SizedBox.shrink();

    final scores = {for (final l in labels) l: battle.teamSteps(l)};
    final leader = scores.entries
        .reduce((a, b) => a.value >= b.value ? a : b)
        .key;

    Color accent(String l) {
      switch (l) {
        case 'A':
          return AppColors.primary;
        case 'B':
          return AppColors.secondary;
        case 'C':
          return AppColors.amber;
        default:
          return AppColors.error;
      }
    }

    return Column(
      children: [
        for (final l in labels)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Container(
                  width: 20,
                  height: 20,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: accent(l),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(l,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                      )),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    battle.teamDisplayName(l),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight:
                          l == leader ? FontWeight.w800 : FontWeight.w600,
                      color: l == leader
                          ? AppColors.onSurface
                          : AppColors.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  _fmt(scores[l] ?? 0),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: accent(l),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Inline "Stop recurring" link rendered on the creator's Daily-series cards.
/// Tap → parent's `onStopRecurring` runs the confirm dialog + API call.
class _StopRecurringButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _StopRecurringButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.cancel_schedule_send,
          size: 16, color: AppColors.error),
      label: const Text(
        'Stop recurring',
        style: TextStyle(
          color: AppColors.error,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

// =============================================================================
// Active battle card
// =============================================================================
class _ActiveCard extends StatelessWidget {
  final BattleModel battle;
  final String currentUserId;
  final VoidCallback? onTap;
  final VoidCallback? onStopRecurring;

  const _ActiveCard({
    required this.battle,
    required this.currentUserId,
    this.onTap,
    this.onStopRecurring,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final me = battle.participantFor(currentUserId);
    final opponent = battle.opponentFor(currentUserId);
    final isTeam = battle.type == BattleType.team;

    return GestureDetector(
      onTap: onTap,
      child: GlassCard(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: ID + title on the left, badges + Live pill on the right.
            // Badges live in a Wrap so they reflow onto the next line on
            // narrow phones / when many badges (team + public + daily) stack
            // up together. Title gets Expanded so the right column can grow.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'BATTLE ID ${battle.shortId}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isTeam
                            ? '🏳️ ${battle.teamCount ?? battle.teamLabels.length}-team battle'
                            : '⚔️ You vs ${_shortName(opponent?.displayName)}',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    alignment: WrapAlignment.end,
                    children: [
                      if (isTeam) const _TeamBadge(),
                      if (battle.visibility == BattleVisibility.public)
                        const _PublicBadge(),
                      if (battle.seriesId != null) const _DailyBadge(),
                      const StatusPill(type: StatusType.live),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            if (isTeam)
              _TeamSummary(battle: battle)
            else ...[
              // Step counts side by side (1v1 / group)
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('You',
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: AppColors.onSurfaceVariant)),
                        Text(
                          _fmt(me?.currentSteps ?? 0),
                          style: theme.textTheme.headlineMedium?.copyWith(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(_shortName(opponent?.displayName),
                            style: theme.textTheme.labelSmall?.copyWith(
                                color: AppColors.onSurfaceVariant),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        Text(
                          _fmt(opponent?.currentSteps ?? 0),
                          style: theme.textTheme.headlineMedium?.copyWith(
                            color: AppColors.amber,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              DualFillBar(
                yourSteps: me?.currentSteps ?? 0,
                opponentSteps: opponent?.currentSteps ?? 0,
              ),
            ],
            const SizedBox(height: 16),

            // Footer: time + XP
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.schedule,
                        size: 14, color: AppColors.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(battle.timeRemainingLabel,
                        style: theme.textTheme.bodySmall),
                  ],
                ),
                Text(
                  '+${battle.xpReward} XP on win',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: AppColors.tertiary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            // Creator-only Stop-recurring control. Current instance keeps
            // running; only future spawns get suppressed.
            if (onStopRecurring != null) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: _StopRecurringButton(onPressed: onStopRecurring!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Scheduled (pending) battle card
// =============================================================================
class _ScheduledCard extends StatelessWidget {
  final BattleModel battle;
  final VoidCallback? onTap;
  final VoidCallback? onStopRecurring;
  final VoidCallback? onStartTeamBattle;

  const _ScheduledCard({
    required this.battle,
    this.onTap,
    this.onStopRecurring,
    this.onStartTeamBattle,
  });

  /// Status line text: depends on whether the battle is still waiting on
  /// invite acceptance (`pending`) or all-accepted-but-not-yet-active
  /// (`scheduled`).
  String _statusLine() {
    if (battle.status == BattleStatus.scheduled) {
      final r = battle.startTime.difference(DateTime.now());
      if (r.isNegative) return 'Starting now…';
      if (r.inDays > 0) {
        return 'Starts in ${r.inDays}d ${r.inHours % 24}h';
      }
      if (r.inHours > 0) {
        return 'Starts in ${r.inHours}h ${r.inMinutes % 60}m';
      }
      return 'Starts in ${r.inMinutes}m';
    }
    return 'Starts when accepted';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final opponent = battle.participants.length > 1
        ? battle.participants[1]
        : null;
    final isTeam = battle.type == BattleType.team;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: const Border(
            left: BorderSide(
                color: Color(0x80F59E0B), width: 4), // amber left accent
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isTeam
                        ? '🏳️ ${battle.teamCount ?? battle.teamLabels.length}-team battle'
                        : '⚔️ You vs ${opponent == null ? "Waiting..." : _shortName(opponent.displayName)}',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (isTeam) ...[
                    const SizedBox(height: 10),
                    _TeamSummary(battle: battle),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.calendar_today,
                          size: 14, color: AppColors.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Text(
                        isTeam
                            ? 'Lobby — creator starts when ready'
                            : _statusLine(),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '+${battle.xpReward} XP on win',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.tertiary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (battle.joinCode != null) ...[
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _JoinCodeChip(code: battle.joinCode!),
                    ),
                  ],
                  if (onStartTeamBattle != null) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        onPressed: onStartTeamBattle,
                        icon: const Icon(Icons.play_arrow, size: 16),
                        label: const Text('Start now'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 6),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ),
                  ],
                  if (onStopRecurring != null) ...[
                    const SizedBox(height: 2),
                    Align(
                      alignment: Alignment.centerLeft,
                      child:
                          _StopRecurringButton(onPressed: onStopRecurring!),
                    ),
                  ],
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const StatusPill(type: StatusType.pending),
                if (isTeam) ...[
                  const SizedBox(height: 6),
                  const _TeamBadge(),
                ],
                if (battle.visibility == BattleVisibility.public) ...[
                  const SizedBox(height: 6),
                  const _PublicBadge(),
                ],
                if (battle.seriesId != null) ...[
                  const SizedBox(height: 6),
                  const _DailyBadge(),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Completed battle card
// =============================================================================
class _CompletedCard extends StatelessWidget {
  final BattleModel battle;
  final String currentUserId;
  final VoidCallback? onTap;

  const _CompletedCard({
    required this.battle,
    required this.currentUserId,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final me = battle.participantFor(currentUserId);
    final opponent = battle.opponentFor(currentUserId);
    final isTeam = battle.type == BattleType.team;
    // Team battles store the per-team winners on each participant
    // (is_winner = true for everyone on the winning team). For 1v1 / group
    // we keep using winner_id for the "Won" pill.
    final won = isTeam ? (me?.isWinner ?? false) : battle.winnerId == currentUserId;

    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: 0.8,
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerLow.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isTeam
                              ? '🏳️ ${battle.teamCount ?? battle.teamLabels.length}-team battle'
                              : '⚔️ You vs ${_shortName(opponent?.displayName)}',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        if (!isTeam)
                          Text(
                            'You: ${_fmt(me?.currentSteps ?? 0)} · ${_shortName(opponent?.displayName, maxLen: 10)}: ${_fmt(opponent?.currentSteps ?? 0)}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: AppColors.primary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 140),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      alignment: WrapAlignment.end,
                      children: [
                        if (isTeam) const _TeamBadge(),
                        if (battle.visibility == BattleVisibility.public)
                          const _PublicBadge(),
                        if (battle.seriesId != null) const _DailyBadge(),
                        StatusPill(
                            type: won ? StatusType.won : StatusType.lost),
                      ],
                    ),
                  ),
                ],
              ),
              if (isTeam) ...[
                const SizedBox(height: 10),
                _TeamSummary(battle: battle),
              ],
              const SizedBox(height: 12),

              // Frozen progress bar
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: 1.0,
                  backgroundColor: AppColors.surfaceContainerHighest,
                  color: AppColors.primary.withValues(alpha: 0.4),
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 12),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Completed',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.onSurfaceVariant,
                      letterSpacing: 2,
                    ),
                  ),
                  Text(
                    won ? '+${battle.xpReward} XP EARNED' : '+0 XP',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: won ? AppColors.success : AppColors.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// First word of a display name — used in battle card titles and stat
/// subtitles where the full name (e.g. "Mogulagani Prashanth") overflows
/// the card. If the first word itself is too long (single-word names),
/// it's truncated with an ellipsis as a safety net.
String _shortName(String? full, {int maxLen = 14}) {
  if (full == null || full.trim().isEmpty) return 'Opponent';
  final firstWord = full.trim().split(RegExp(r'\s+')).first;
  if (firstWord.length > maxLen) {
    return '${firstWord.substring(0, maxLen - 1)}…';
  }
  return firstWord;
}

String _fmt(int n) {
  if (n == 0) return '0';
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}
