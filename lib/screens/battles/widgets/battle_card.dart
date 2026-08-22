import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../config/colors.dart';
import '../../../models/battle_model.dart';
import '../../../utils/friendly_date.dart';
import '../../../widgets/dual_fill_bar.dart';
import '../../../widgets/premium_card.dart';
import '../../../widgets/multiplayer_battle_visuals.dart';
import '../../../widgets/pressable.dart';
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

  /// Non-creator "Leave lobby" callback for pending team battles. Tap
  /// → confirm dialog + service.leaveTeamBattle() (refunds stake).
  /// Null for creators (they use the sheet's Cancel button instead) and
  /// for non-team battles.
  final VoidCallback? onLeaveLobby;

  const BattleCard({
    super.key,
    required this.battle,
    required this.currentUserId,
    this.onTap,
    this.onStopRecurring,
    this.onStartTeamBattle,
    this.onLeaveLobby,
  });

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary isolates each card's paint tree so a scroll-driven
    // repaint of one row (e.g. progress-bar animation ticking) doesn't
    // invalidate the entire scroll viewport. Cards are the atomic paint
    // unit — cheap to keep separate raster layers per row when the list
    // has 10+ items, and the compositor handles the merge for free.
    final content = switch (battle.status) {
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
          currentUserId: currentUserId,
          onTap: onTap,
          onStopRecurring: onStopRecurring,
          onStartTeamBattle: onStartTeamBattle,
          onLeaveLobby: onLeaveLobby),
      BattleStatus.completed => _CompletedCard(
          battle: battle, currentUserId: currentUserId, onTap: onTap),
      BattleStatus.cancelled => const SizedBox.shrink(),
    };
    // Pressable wraps only when the card is tappable — otherwise the
    // scale-on-press effect would fire on a non-interactive row.
    // Pressable uses `Listener` (not GestureDetector) so the inner
    // card's own onTap plumbing keeps firing normally.
    return RepaintBoundary(
      child: onTap == null ? content : Pressable(child: content),
    );
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
      child: Text(
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
      child: Text(
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
            Icon(Icons.key, size: 12, color: AppColors.secondary),
            const SizedBox(width: 6),
            Text(
              code,
              style: TextStyle(
                color: AppColors.secondary,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
                fontSize: 12,
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.content_copy,
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
    final isGroup = battle.type == BattleType.group;

    // Header title varies by battle type; Battle ID always renders on
    // the SECOND line below the title (per Batch A r3 spec — all three
    // types share this pattern).
    final headerTitle = isTeam
        ? 'Team battle'
        : isGroup
            ? 'Multi battle'
            : 'You vs ${_shortName(opponent?.friendlyName)}';

    return GestureDetector(
      onTap: onTap,
      child: PremiumCard(
        // Active battle = hero surface; strong intensity so it reads
        // as the most alive card in the list.
        intensity: PremiumCardIntensity.strong,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: title on line 1 (with status pill + badges right-
            // aligned), Battle ID on line 2 in muted caption.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        headerTitle,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'BATTLE ID · ${battle.shortId}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                          letterSpacing: 2,
                        ),
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
                      if (battle.visibility == BattleVisibility.public)
                        const _PublicBadge(),
                      if (battle.seriesId != null) const _DailyBadge(),
                      // 'Live' vs 'Ending…' — flip once end_time has
                      // passed so users see the settlement window
                      // instead of thinking the card is stuck. The
                      // server cron flips status active→completed
                      // typically within 60 s; until then this pill
                      // sits on the still-active card. Replaces the
                      // client-side auto-complete that used to write
                      // status directly and race the cron's pot
                      // payout (see battle_service.dart 1.1.6+29).
                      StatusPill(
                        type: DateTime.now().isBefore(battle.endTime)
                            ? StatusType.live
                            : StatusType.ending,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            if (isTeam)
              _TeamBattleBody(
                battle: battle,
                currentUserId: currentUserId,
              )
            else if (isGroup) ...[
              _GroupBattleBody(
                battle: battle,
                currentUserId: currentUserId,
              ),
            ] else ...[
              // 1v1: unchanged existing render — You / opponent slots +
              // DualFillBar.
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
                        Text(_shortName(opponent?.friendlyName),
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
                  '+${battle.stakeXp} XP on win',
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
  final String currentUserId;
  final VoidCallback? onTap;
  final VoidCallback? onStopRecurring;
  final VoidCallback? onStartTeamBattle;
  final VoidCallback? onLeaveLobby;

  const _ScheduledCard({
    required this.battle,
    required this.currentUserId,
    this.onTap,
    this.onStopRecurring,
    this.onStartTeamBattle,
    this.onLeaveLobby,
  });

  /// Status line text: shows a countdown for `scheduled` battles (window
  /// locked, waiting for start_time) and either an expiry countdown or a
  /// "waiting on invites" note for `pending` battles. Migration 0040's
  /// `pending_expires_at` is the source of truth for the pending deadline:
  /// immediate mode = created_at + 24h; scheduled mode = start_time.
  String _statusLine() {
    if (battle.status == BattleStatus.scheduled) {
      return _fmtStartsIn(battle.startTime);
    }
    // status == pending
    final expiry = battle.pendingExpiresAt;
    if (expiry == null) {
      // Pre-Migration-0040 row — no deadline stamped.
      return 'Starts when accepted';
    }
    final now = DateTime.now();
    if (expiry.isBefore(now)) return 'Expiring…';
    if (battle.isScheduled) {
      // Scheduled mode — the "deadline" IS the start moment. Same phrasing
      // as an already-scheduled battle so the wait feels consistent.
      return _fmtStartsIn(expiry);
    }
    // Immediate mode — 24h fuse.
    return _fmtExpiresIn(expiry.difference(now));
  }

  static String _fmtStartsIn(DateTime t) {
    final r = t.difference(DateTime.now());
    if (r.isNegative) return 'Starting now…';
    if (r.inDays > 0) return 'Starts in ${r.inDays}d ${r.inHours % 24}h';
    if (r.inHours > 0) return 'Starts in ${r.inHours}h ${r.inMinutes % 60}m';
    return 'Starts in ${r.inMinutes}m';
  }

  static String _fmtExpiresIn(Duration r) {
    if (r.inHours > 0) return 'Expires in ${r.inHours}h ${r.inMinutes % 60}m';
    if (r.inMinutes > 0) return 'Expires in ${r.inMinutes}m';
    return 'Expires in <1m';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Use opponentFor(currentUserId) — the OLD code did
    // `battle.participants[1]` which is a hardcoded index. The nested-
    // select PostgREST payload (`battles select *, battle_participants(*)`)
    // has no ORDER BY on the participants, so which row lands at index
    // 0 vs 1 is planner-dependent and unstable between emissions. If
    // the current user's row happened to land at index 1, the "opponent
    // slot" resolved to the current user themselves and the header
    // rendered as `⚔️ You vs [own first name]`. Confirmed root cause
    // for the "You vs You" bug reported 2026-08-17.
    // opponentFor(currentUserId) picks the FIRST participant whose
    // userId != mine, which is deterministic for 1v1 (there's only one
    // other participant) and safe for the empty-uid auth-hydration
    // race (guarded inside BattleModel.opponentFor).
    final opponent = battle.opponentFor(currentUserId);
    final isTeam = battle.type == BattleType.team;

    return GestureDetector(
      onTap: onTap,
      child: Stack(
        children: [
          // PremiumCard body — same gradient look as the other card
          // variants for visual consistency.
          PremiumCard(
            intensity: PremiumCardIntensity.standard,
            padding: const EdgeInsets.all(20),
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
                        : '⚔️ You vs ${opponent == null ? "Waiting..." : _shortName(opponent.friendlyName)}',
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
                      // Rebuilds once a minute so the countdown ticks
                      // visibly. Stream emits a tick counter that we
                      // don't read — it's a rebuild signal. Cheap;
                      // the subtree is one Text node.
                      Expanded(
                        child: StreamBuilder<int>(
                          stream: Stream.periodic(
                              const Duration(minutes: 1), (i) => i),
                          builder: (context, _) => Text(
                            _statusLine(),
                            style: theme.textTheme.bodySmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '+${battle.stakeXp} XP on win',
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
                  if (onLeaveLobby != null) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: onLeaveLobby,
                        icon: Icon(Icons.logout,
                            size: 16, color: AppColors.error),
                        label: Text(
                          'Leave lobby',
                          style: TextStyle(color: AppColors.error),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(
                            color: AppColors.error.withValues(alpha: 0.5),
                          ),
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
          // Amber left-edge accent — "waiting for opponent" signal.
          // Overlaid on top of the PremiumCard body so we keep the
          // gradient background but preserve the pending-state cue.
          Positioned(
            left: 0,
            top: 12,
            bottom: 12,
            child: IgnorePointer(
              child: Container(
                width: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFF59E0B),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ],
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

    // "Faded" look for completed cards used to be a global
    // `Opacity(0.8, ...)` wrapper around the whole tile. That forces
    // Flutter to allocate an OFFSCREEN BUFFER per card on every
    // scroll frame (`saveLayer` under the hood) — the single biggest
    // source of scroll jank on the Battles tab and the full-history
    // screen, since /battles/completed can hold dozens of these.
    //
    // The visual is now baked into the individual colours below
    // (background alpha unchanged, text tokens use `onSurfaceVariant`
    // already, primary accent gets a `.withValues(alpha: 0.85)`) so
    // the card still reads as "past" without paying for the
    // compositor detour. Difference is imperceptible next to the
    // original 0.8-alpha treatment.
    return GestureDetector(
      onTap: onTap,
      child: PremiumCard(
        // Completed = past, so `soft` intensity — the card should read
        // as "done and archived" not "still alive". Reduces glow +
        // corner halo strength vs. active/scheduled cards.
        intensity: PremiumCardIntensity.soft,
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
              // Header: same pattern as _ActiveCard (title on line 1,
              // Battle ID on line 2) — Batch A r3 spec.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isTeam
                              ? 'Team battle'
                              : battle.type == BattleType.group
                                  ? 'Multi battle'
                                  : 'You vs ${_shortName(opponent?.friendlyName)}',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'BATTLE ID · ${battle.shortId}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: AppColors.onSurfaceVariant,
                            letterSpacing: 2,
                          ),
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
              const SizedBox(height: 14),
              if (isTeam) ...[
                _TeamBattleBody(
                  battle: battle,
                  currentUserId: currentUserId,
                ),
                const SizedBox(height: 12),
              ] else if (battle.type == BattleType.group) ...[
                _GroupBattleBody(
                  battle: battle,
                  currentUserId: currentUserId,
                ),
                const SizedBox(height: 12),
              ] else ...[
                // 1v1 completed: keep the compact "You: X · Opponent:
                // Y" summary line + the frozen "filled" progress bar
                // (visual sugar rather than a data-driven fill).
                Text(
                  'You: ${_fmt(me?.currentSteps ?? 0)} · ${_shortName(opponent?.friendlyName, maxLen: 10)}: ${_fmt(opponent?.currentSteps ?? 0)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.primary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 12),
                Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 12),
              ],

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Completion timestamp replaces the old "Completed"
                  // label — the Won / Lost pill above already carries
                  // the state, so this slot is used for time context.
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.event_outlined,
                        size: 12,
                        color: AppColors.onSurfaceVariant,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        friendlyDateTime(battle.endTime).toUpperCase(),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                          letterSpacing: 1.2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  Builder(builder: (_) {
                    // Show the honest net XP delta from the stake pot.
                    // Free-play battles (stakeXp = 0) get the muted
                    // "+0 XP" fallback that mirrors pre-stake behaviour.
                    final net = battle.netStakeXpFor(currentUserId);
                    if (battle.stakeXp == 0) {
                      return Text('+0 XP',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: AppColors.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1,
                          ));
                    }
                    if (net > 0) {
                      return Text('+$net XP WON',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: AppColors.success,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1,
                          ));
                    }
                    if (net < 0) {
                      // net is already negative — direct interpolation
                      // renders "-100 XP LOST".
                      return Text('$net XP LOST',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: AppColors.error,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1,
                          ));
                    }
                    // net == 0 on a stake battle = TIE (server refunded
                    // everyone via `battle_refund`, see netStakeXpFor
                    // docs). Show a distinct neutral label so users
                    // don't read "+0 XP" as "nothing happened" — their
                    // stake was actually deducted then refunded.
                    return Text('TIE · REFUNDED',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1,
                        ));
                  }),
                ],
              ),
            ],
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

/// Group battle card body — used by both active and completed cards.
/// Renders the last/top slots (name + step count), the stacked colored
/// rail, and the expandable Battle board dropdown. Middle players are
/// only surfaced by color on the rail — their names live in the
/// dropdown per the design spec.
class _GroupBattleBody extends StatelessWidget {
  final BattleModel battle;
  final String currentUserId;

  const _GroupBattleBody({
    required this.battle,
    required this.currentUserId,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = buildPlayerRows(battle, currentUserId);
    if (rows.isEmpty) {
      // Defensive — a group battle with no accepted participants is a
      // schema anomaly, but bail gracefully.
      return const SizedBox.shrink();
    }
    final top = rows.first;
    final last = rows.last;
    final segments = [
      for (final r in rows) BarSegment(color: r.color, value: r.steps),
    ];

    // Left slot label: if the current user is the LAST player, we show
    // "You" so they can find themselves at a glance. Same on the right
    // slot for the leader. Middle-rank current user gets their name in
    // both slots (as normal) and a star on their row in the dropdown.
    final leftName = last.isYou ? 'You' : _shortName(last.name);
    final rightName = top.isYou ? 'You' : _shortName(top.name);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(leftName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.onSurfaceVariant)),
                  Text(
                    _fmt(last.steps),
                    style: theme.textTheme.headlineMedium?.copyWith(
                      color: last.color,
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
                  Text(rightName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.onSurfaceVariant)),
                  Text(
                    _fmt(top.steps),
                    style: theme.textTheme.headlineMedium?.copyWith(
                      color: top.color,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        MultiplayerStackedBar(segments: segments),
        const SizedBox(height: 12),
        GroupBoardDropdown(rows: rows),
      ],
    );
  }
}

/// Team battle card body — mirrors `_GroupBattleBody` but slices the
/// bar by team and expands into a team-grouped board. Used by both
/// active and completed team-battle card variants.
class _TeamBattleBody extends StatelessWidget {
  final BattleModel battle;
  final String currentUserId;

  const _TeamBattleBody({
    required this.battle,
    required this.currentUserId,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final teams = buildTeamGroups(battle, currentUserId);
    if (teams.isEmpty) return const SizedBox.shrink();
    final top = teams.first;
    final last = teams.last;
    final segments = [
      for (final t in teams) BarSegment(color: t.color, value: t.totalSteps),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Team ${last.teamLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.onSurfaceVariant)),
                  Text(
                    _fmt(last.totalSteps),
                    style: theme.textTheme.headlineMedium?.copyWith(
                      color: last.color,
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
                  Text('Team ${top.teamLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.onSurfaceVariant)),
                  Text(
                    _fmt(top.totalSteps),
                    style: theme.textTheme.headlineMedium?.copyWith(
                      color: top.color,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        MultiplayerStackedBar(segments: segments),
        const SizedBox(height: 12),
        TeamBoardDropdown(teams: teams),
      ],
    );
  }
}
