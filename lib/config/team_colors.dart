import 'package:flutter/material.dart';

/// Team-color palette for team battles.
///
/// Four teams max (A / B / C / D). Colors are picked to have strong
/// hue separation so the lobby, the arena, and post-battle result cards
/// read at a glance without depending on the team letter label.
///
/// Called from every widget that renders per-team UI:
///   • BattleTeamSetupSheet — column headers + player chips
///   • BattleGroundScreen — team stripe under runners
///   • BattleCard + LiveBattleCard — team badges
///   • BattleResultCard — winner banner
///
/// Colors are theme-agnostic on purpose (a "Team B" runner should be
/// blue in light AND dark mode). They're chosen from the semantic
/// palette in colors.dart rather than raw hex so we can keep visual
/// coherence across theme swaps.
class TeamColors {
  TeamColors._();

  static const _amber   = Color(0xFFF59E0B); // Team A — warm anchor
  static const _blue    = Color(0xFF3B82F6); // Team B — cool complement
  static const _emerald = Color(0xFF10B981); // Team C — nature accent
  static const _purple  = Color(0xFF8B5CF6); // Team D — brand-adjacent

  /// Solid color for [label] (`A` / `B` / `C` / `D`). Falls back to the
  /// on-surface neutral if a battle somehow produces a label outside
  /// the expected set (defensive — the create sheet caps at D).
  static Color forLabel(String? label) {
    switch (label) {
      case 'A':
        return _amber;
      case 'B':
        return _blue;
      case 'C':
        return _emerald;
      case 'D':
        return _purple;
      default:
        return const Color(0xFF9CA3AF); // slate — clearly a fallback
    }
  }

  /// Tinted background variant of the team color — use for chip fills,
  /// column headers, and any area that needs the hue but not the full
  /// contrast. Alpha keeps it readable on both light and dark surfaces.
  static Color tintFor(String? label) =>
      forLabel(label).withValues(alpha: 0.18);

  /// Text/icon color that reads on top of [forLabel]. All four team
  /// colors have enough saturation that white sits well on them.
  static Color onColor(String? label) => Colors.white;

  /// Ordered list of team labels for a given team count (creator-picked
  /// at battle creation; capped at 4 by [BattleTeamSetupSheet]).
  static List<String> labelsFor(int teamCount) {
    const all = ['A', 'B', 'C', 'D'];
    return all.take(teamCount.clamp(2, 4)).toList();
  }
}
