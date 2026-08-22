import 'package:flutter/material.dart';

import '../config/colors.dart';
import '../config/team_colors.dart';
import '../models/battle_model.dart';

/// Shared visual language for group + team battle boards. Same
/// widgets render on the Battles-tab cards, the Discover feed, the
/// Day Summary screen, and the arena leaderboard pill so users read a
/// consistent rail + drop-down everywhere a multi-participant battle
/// surfaces.

// ---------------------------------------------------------------------------
// Palette
// ---------------------------------------------------------------------------

/// 10-slot color palette assigned by participant-join order in group
/// battles. Stable across renders because Supabase returns rows in
/// insertion order, so a given player wears the same color everywhere
/// their steps show up.
const List<Color> kPlayerPalette = <Color>[
  Color(0xFFF59E0B), // amber
  Color(0xFF3B82F6), // blue
  Color(0xFF10B981), // emerald
  Color(0xFF8B5CF6), // purple
  Color(0xFFEC4899), // pink
  Color(0xFF06B6D4), // cyan
  Color(0xFFF97316), // orange
  Color(0xFFEAB308), // yellow
  Color(0xFFF43F5E), // rose
  Color(0xFF14B8A6), // teal
];

Color playerColorForIndex(int index) =>
    kPlayerPalette[index % kPlayerPalette.length];

// ---------------------------------------------------------------------------
// Data models
// ---------------------------------------------------------------------------

/// One row in the board / one slice on the bar. `rank` is 1-indexed
/// with 1 = leader. `teamLabel` is non-null in team battles.
class PlayerRow {
  final String userId;
  final String name;
  final int steps;
  final Color color;
  final int rank;
  final bool isYou;
  final String? teamLabel;

  const PlayerRow({
    required this.userId,
    required this.name,
    required this.steps,
    required this.color,
    required this.rank,
    required this.isYou,
    this.teamLabel,
  });
}

/// A team + its members, used by team-battle dropdowns. `members` is
/// sorted by individual step contribution desc so the biggest player
/// on the team surfaces first.
class TeamGroup {
  final String teamLabel;
  final String teamName;
  final Color color;
  final int totalSteps;
  final int rank;
  final List<PlayerRow> members;

  const TeamGroup({
    required this.teamLabel,
    required this.teamName,
    required this.color,
    required this.totalSteps,
    required this.rank,
    required this.members,
  });
}

/// Builds rank-ordered [PlayerRow] list for a group battle. Accepted
/// participants only. Colors assigned by join order (stable), rows
/// sorted by step count desc.
List<PlayerRow> buildPlayerRows(BattleModel battle, String currentUserId) {
  final accepted = battle.participants
      .where((p) => p.inviteStatus == ParticipantInviteStatus.accepted)
      .toList();
  final base = <PlayerRow>[];
  for (var i = 0; i < accepted.length; i++) {
    final p = accepted[i];
    base.add(PlayerRow(
      userId: p.userId,
      name: p.friendlyName,
      steps: p.currentSteps,
      color: playerColorForIndex(i),
      rank: 0,
      isYou: p.userId == currentUserId,
      teamLabel: p.teamLabel,
    ));
  }
  base.sort((a, b) => b.steps.compareTo(a.steps));
  return [
    for (var i = 0; i < base.length; i++)
      PlayerRow(
        userId: base[i].userId,
        name: base[i].name,
        steps: base[i].steps,
        color: base[i].color,
        rank: i + 1,
        isYou: base[i].isYou,
        teamLabel: base[i].teamLabel,
      ),
  ];
}

/// Builds rank-ordered [TeamGroup] list for a team battle. Teams
/// ordered by aggregate step count desc; each team's members ordered
/// by individual steps desc. Team colors come from the shared
/// [TeamColors] palette (A=Amber, B=Blue, C=Emerald, D=Purple).
List<TeamGroup> buildTeamGroups(BattleModel battle, String currentUserId) {
  final accepted = battle.participants
      .where((p) => p.inviteStatus == ParticipantInviteStatus.accepted)
      .toList();
  final byTeam = <String, List<BattleParticipant>>{};
  for (final p in accepted) {
    final label = p.teamLabel;
    if (label == null) continue;
    byTeam.putIfAbsent(label, () => []).add(p);
  }
  final teamsSorted = byTeam.entries.toList()
    ..sort((a, b) {
      final sumA = a.value.fold<int>(0, (s, p) => s + p.currentSteps);
      final sumB = b.value.fold<int>(0, (s, p) => s + p.currentSteps);
      final byTotal = sumB.compareTo(sumA);
      if (byTotal != 0) return byTotal;
      return a.key.compareTo(b.key); // tiebreak on label
    });
  return [
    for (var i = 0; i < teamsSorted.length; i++)
      _teamGroupFrom(
        entry: teamsSorted[i],
        rank: i + 1,
        teamName: battle.teamDisplayName(teamsSorted[i].key),
        currentUserId: currentUserId,
      ),
  ];
}

TeamGroup _teamGroupFrom({
  required MapEntry<String, List<BattleParticipant>> entry,
  required int rank,
  required String teamName,
  required String currentUserId,
}) {
  final members = [...entry.value]
    ..sort((a, b) => b.currentSteps.compareTo(a.currentSteps));
  final teamColor = TeamColors.forLabel(entry.key);
  final total =
      members.fold<int>(0, (s, p) => s + p.currentSteps);
  return TeamGroup(
    teamLabel: entry.key,
    teamName: teamName,
    color: teamColor,
    totalSteps: total,
    rank: rank,
    members: [
      for (var i = 0; i < members.length; i++)
        PlayerRow(
          userId: members[i].userId,
          name: members[i].friendlyName,
          steps: members[i].currentSteps,
          color: teamColor,
          rank: i + 1, // rank within the team (1 = biggest contributor)
          isYou: members[i].userId == currentUserId,
          teamLabel: entry.key,
        ),
    ],
  );
}

// ---------------------------------------------------------------------------
// Stacked colored bar
// ---------------------------------------------------------------------------

/// One slice on the stacked bar. Callers build these from `PlayerRow`
/// for group battles and from `TeamGroup` for team battles.
class BarSegment {
  final Color color;
  final int value;
  const BarSegment({required this.color, required this.value});
}

/// Stacked-proportional colored bar. Slice widths track the caller-
/// provided values. Order left→right = ascending value (last on
/// left, leader on right). Guaranteed minimum slice width so zero-
/// value entries stay visible.
class MultiplayerStackedBar extends StatelessWidget {
  /// Segments in rank-descending order (leader first). Widget flips
  /// internally so last-value ends up on the left of the bar.
  final List<BarSegment> segments;
  final double height;

  static const double _minSlicePx = 6;

  const MultiplayerStackedBar({
    super.key,
    required this.segments,
    this.height = 14,
  });

  @override
  Widget build(BuildContext context) {
    final radius = height / 2;
    if (segments.isEmpty) {
      return SizedBox(
        height: height,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(radius),
          ),
        ),
      );
    }
    return LayoutBuilder(builder: (context, constraints) {
      final barWidth = constraints.maxWidth;
      final total = segments.fold<int>(
          0, (sum, s) => sum + s.value.clamp(0, 1 << 31));
      final laidOut = segments.reversed.toList();
      final widths = <double>[];
      if (total <= 0) {
        final each = barWidth / laidOut.length;
        widths.addAll(List.filled(laidOut.length, each));
      } else {
        final reserved = _minSlicePx * laidOut.length;
        final flex = (barWidth - reserved).clamp(0, barWidth);
        for (final s in laidOut) {
          widths.add(_minSlicePx + (s.value / total) * flex);
        }
      }
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: SizedBox(
          height: height,
          child: Row(
            children: [
              for (var i = 0; i < laidOut.length; i++)
                SizedBox(
                  width: widths[i],
                  height: height,
                  child: ColoredBox(color: laidOut[i].color),
                ),
            ],
          ),
        ),
      );
    });
  }
}

// ---------------------------------------------------------------------------
// Group board dropdown — flat rank-ordered list
// ---------------------------------------------------------------------------

/// Expandable board for group battles. Collapsed = header strip; open
/// reveals a color-keyed rank list. Own row carries a ★ You tag.
class GroupBoardDropdown extends StatefulWidget {
  /// Rank-ascending list (leader first at index 0).
  final List<PlayerRow> rows;
  /// When true, the widget is a headerless list — used inside contexts
  /// that already provide their own header (e.g. arena pill).
  final bool headerless;

  const GroupBoardDropdown({
    super.key,
    required this.rows,
    this.headerless = false,
  });

  @override
  State<GroupBoardDropdown> createState() => _GroupBoardDropdownState();
}

class _GroupBoardDropdownState extends State<GroupBoardDropdown> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.headerless) {
      return Column(
        children: [
          for (final r in widget.rows) _PlayerRowLine(row: r),
        ],
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.leaderboard,
                      size: 16, color: AppColors.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Battle board',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppColors.onSurface,
                      ),
                    ),
                  ),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 18,
                    color: AppColors.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(
              height: 1,
              color: AppColors.outlineVariant.withValues(alpha: 0.4),
            ),
            for (final r in widget.rows) _PlayerRowLine(row: r),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Team board dropdown — grouped by team header + indented members
// ---------------------------------------------------------------------------

class TeamBoardDropdown extends StatefulWidget {
  /// Rank-ascending list (winning team first at index 0).
  final List<TeamGroup> teams;
  final bool headerless;

  const TeamBoardDropdown({
    super.key,
    required this.teams,
    this.headerless = false,
  });

  @override
  State<TeamBoardDropdown> createState() => _TeamBoardDropdownState();
}

class _TeamBoardDropdownState extends State<TeamBoardDropdown> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.headerless) {
      return Column(
        children: [
          for (final t in widget.teams) _TeamGroupBlock(group: t),
        ],
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.leaderboard,
                      size: 16, color: AppColors.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Team board',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppColors.onSurface,
                      ),
                    ),
                  ),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 18,
                    color: AppColors.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(
              height: 1,
              color: AppColors.outlineVariant.withValues(alpha: 0.4),
            ),
            for (final t in widget.teams) _TeamGroupBlock(group: t),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared row / group primitives
// ---------------------------------------------------------------------------

class _PlayerRowLine extends StatelessWidget {
  final PlayerRow row;
  final bool indented;
  const _PlayerRowLine({required this.row, this.indented = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(indented ? 28 : 12, 8, 12, 8),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: row.color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          if (!indented) ...[
            SizedBox(
              width: 26,
              child: Text(
                '#${row.rank}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.onSurfaceVariant,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
          // Name + inline "★ You" badge for the current user.
          // Prior placement was AFTER the step count (right edge). Moved
          // 1.1.6+27: reads better as "identifier attached to the row's
          // owner" rather than "detached label next to a number."
          Expanded(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    row.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: AppColors.onSurface,
                    ),
                  ),
                ),
                if (row.isYou) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '★ You',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Text(
            _fmtSteps(row.steps),
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppColors.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _TeamGroupBlock extends StatelessWidget {
  final TeamGroup group;
  const _TeamGroupBlock({required this.group});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration:
                    BoxDecoration(color: group.color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'TEAM ${group.teamLabel} · #${group.rank}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: AppColors.onSurface,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
              Text(
                _fmtSteps(group.totalSteps),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppColors.onSurface,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        for (final m in group.members) _PlayerRowLine(row: m, indented: true),
        const SizedBox(height: 4),
      ],
    );
  }
}

String _fmtSteps(int n) {
  if (n == 0) return '0';
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}
