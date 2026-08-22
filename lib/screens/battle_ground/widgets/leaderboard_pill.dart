import 'package:flutter/material.dart';

import '../../../config/colors.dart';
import '../../../models/battle_model.dart';
import '../../../widgets/multiplayer_battle_visuals.dart';

/// Arena leaderboard pill — sits above the road at the bottom of the
/// battle ground. Shares its visual language with the Battles-tab
/// battle-card boards via `MultiplayerStackedBar`, `GroupBoardDropdown`,
/// and `TeamBoardDropdown` from
/// [lib/widgets/multiplayer_battle_visuals.dart]. Players wear the same
/// colors here as on the card so users cross-reference bar slice → row
/// on either surface without confusion.
///
/// Layout:
///   • Always visible: `📊 BATTLE BOARD · N players/teams · ▼/▲` header
///     row, plus the colored stacked rail below it.
///   • Tap to expand: the full ranked list (grouped by team on team
///     battles). Grows tall — no cap on rows since the user asked to
///     see every participant during a live battle.
class LeaderboardPill extends StatefulWidget {
  final BattleModel battle;
  final String currentUserId;

  const LeaderboardPill({
    super.key,
    required this.battle,
    required this.currentUserId,
  });

  @override
  State<LeaderboardPill> createState() => _LeaderboardPillState();
}

class _LeaderboardPillState extends State<LeaderboardPill> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isTeam = widget.battle.type == BattleType.team;

    // Data + segments derived on every build — cheap (list operations
    // over ≤10 participants) and always in sync with the realtime
    // stream that drives `widget.battle`.
    final List<BarSegment> segments;
    final Widget expandedBody;
    final String countLabel;
    if (isTeam) {
      final teams = buildTeamGroups(widget.battle, widget.currentUserId);
      segments = [
        for (final t in teams)
          BarSegment(color: t.color, value: t.totalSteps),
      ];
      expandedBody = TeamBoardDropdown(teams: teams, headerless: true);
      countLabel = '${teams.length} ${teams.length == 1 ? "team" : "teams"}';
    } else {
      final rows = buildPlayerRows(widget.battle, widget.currentUserId);
      segments = [
        for (final r in rows)
          BarSegment(color: r.color, value: r.steps),
      ];
      expandedBody = GroupBoardDropdown(rows: rows, headerless: true);
      countLabel =
          '${rows.length} ${rows.length == 1 ? "player" : "players"}';
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: AppColors.onSurface.withValues(alpha: 0.08),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 12, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(Icons.leaderboard,
                          size: 14, color: AppColors.primary),
                      const SizedBox(width: 6),
                      Text(
                        'BATTLE BOARD',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.9),
                          letterSpacing: 1.6,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        countLabel,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.65),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      Icon(
                        _expanded
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_up,
                        size: 18,
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Rail — always visible so the user sees live standings
                  // at a glance without needing to expand the pill.
                  MultiplayerStackedBar(
                    segments: segments,
                    height: 10,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(
              height: 1,
              color: Colors.white.withValues(alpha: 0.1),
            ),
            // Expanded body grows tall — no cap. User asked for the full
            // list to be visible during a live battle.
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: expandedBody,
            ),
          ],
        ],
      ),
    );
  }
}
