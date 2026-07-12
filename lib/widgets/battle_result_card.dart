import 'package:flutter/material.dart';

import '../config/colors.dart';
import '../models/battle_model.dart';

/// The outcome tag shown at the top of a [BattleResultCard]. Rendered
/// as either the two-line **winner badge** (a big `#1` sitting above
/// `LAST ONE STANDING`) or a single-line tag for the other outcomes.
///
/// The strings are the "chicken dinner" copy the user picked:
///   • Winner → `#1` + `LAST ONE STANDING`
///   • Loser  → `OUTFLANKED`
///   • Tie    → `DEAD HEAT`
enum BattleResultTag { winner, loser, tie }

extension BattleResultTagX on BattleResultTag {
  /// The main text of the tag. For the winner variant this is the
  /// tagline only — the `#1` badge is drawn separately by the widget.
  String get title => switch (this) {
        BattleResultTag.winner => 'LAST ONE STANDING',
        BattleResultTag.loser => 'OUTFLANKED',
        BattleResultTag.tie => 'DEAD HEAT',
      };

  /// Colour the tag paints in. Winners get brand-primary purple; losers
  /// get a muted amber (not red — we don't want the loser's share
  /// card to feel like a rejection); ties get neutral onSurface.
  Color color() => switch (this) {
        BattleResultTag.winner => AppColors.primary,
        BattleResultTag.loser => AppColors.amber,
        BattleResultTag.tie => Colors.white,
      };

  /// Convenience picker for a battle + viewer combo.
  static BattleResultTag pick({
    required BattleModel battle,
    required String uid,
  }) {
    final me = battle.participantFor(uid);
    final opponent = battle.opponentFor(uid);
    if (me == null || opponent == null) return BattleResultTag.tie;
    if (me.currentSteps == opponent.currentSteps) return BattleResultTag.tie;
    return battle.winnerId == uid
        ? BattleResultTag.winner
        : BattleResultTag.loser;
  }
}

/// Transparent, self-contained battle-result card used both on the
/// Battle Status page (as a draggable overlay) and inside the share
/// PNG. **No background chrome, no border** — the card reads
/// against whatever the user picked as the background (photo or
/// themed violet gradient).
///
/// Text picks up subtle dark shadows for legibility over busy
/// backgrounds — a small performance cost but the alternative
/// (adding a translucent panel) looked boxy and the user explicitly
/// asked for transparency.
///
/// Layout at 320 dp width (typical):
///
///   ┌──────────────────────────────────────┐
///   │              #1                       │  ← winner-only badge
///   │      LAST ONE STANDING                │  ← tag line
///   │                                        │
///   │   ✕ Prash vs Ravi                     │  ← names
///   │                                        │
///   │   Prash                    Ravi       │  ← two-tone score labels
///   │   8,472                   6,201       │  ← big numbers
///   │   ▓▓▓▓▓▓▓░░░░░░░░░░░░               │  ← progress bar
///   │                                        │
///   │                     +200 XP on win    │  ← footer
///   └──────────────────────────────────────┘
class BattleResultCard extends StatelessWidget {
  /// Battle model — must be completed for the card to look right,
  /// but we don't hard-crash on in-progress data (`currentSteps` is
  /// live).
  final BattleModel battle;

  /// Viewer's user id. Drives "me vs opponent" perspective + tag
  /// win/loss.
  final String uid;

  /// Optional override — when set the widget won't recompute the
  /// tag from the battle. Useful for the share-card render path
  /// where you might want to force a preview.
  final BattleResultTag? tagOverride;

  /// Text scale multiplier — the share-card render at 1080×1920
  /// passes ~3× to make everything crisp. On the Battle Status page
  /// leave at 1.0.
  final double scale;

  /// Enable / disable the drop shadow behind text. On top of a busy
  /// photo background you want it; on the flat themed gradient you
  /// might turn it off to keep the look clean.
  final bool textShadows;

  const BattleResultCard({
    super.key,
    required this.battle,
    required this.uid,
    this.tagOverride,
    this.scale = 1.0,
    this.textShadows = true,
  });

  @override
  Widget build(BuildContext context) {
    final me = battle.participantFor(uid);
    final opponent = battle.opponentFor(uid);
    // If we don't have a "you vs them" comparison there's nothing
    // meaningful to render — bail out.
    if (me == null || opponent == null) return const SizedBox.shrink();

    final tag = tagOverride ??
        BattleResultTagX.pick(battle: battle, uid: uid);
    final myName = me.friendlyName;
    final opName = opponent.friendlyName;
    final myAccent = AppColors.primary;
    final opAccent = AppColors.amber;

    return DefaultTextStyle(
      // Baseline style + shadow applied to every child Text so we
      // don't repeat the shadow spec across each label.
      style: TextStyle(
        color: Colors.white,
        fontFamily: 'Manrope',
        shadows: textShadows
            ? const [
                Shadow(color: Color(0xCC000000), blurRadius: 8),
                Shadow(color: Color(0x99000000), blurRadius: 2),
              ]
            : null,
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 8 * scale,
          vertical: 6 * scale,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Tag(tag: tag, scale: scale),
            SizedBox(height: 16 * scale),
            _NamesLine(myName: myName, opName: opName, scale: scale),
            SizedBox(height: 14 * scale),
            _ScoreLabels(
              myName: myName,
              opName: opName,
              myAccent: myAccent,
              opAccent: opAccent,
              scale: scale,
            ),
            SizedBox(height: 4 * scale),
            _ScoreValues(
              mySteps: me.currentSteps,
              opSteps: opponent.currentSteps,
              myAccent: myAccent,
              opAccent: opAccent,
              scale: scale,
            ),
            SizedBox(height: 10 * scale),
            _ScoreBar(
              mySteps: me.currentSteps,
              opSteps: opponent.currentSteps,
              myColor: myAccent,
              opColor: opAccent,
              scale: scale,
            ),
            SizedBox(height: 12 * scale),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                '+${_fmt(battle.xpReward)} XP on win',
                style: TextStyle(
                  color: opAccent,
                  fontSize: 13 * scale,
                  fontWeight: FontWeight.w800,
                  shadows: textShadows
                      ? const [Shadow(color: Color(0xCC000000), blurRadius: 6)]
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
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

/// The outcome tag — winner variant stacks a giant `#1` above the
/// tagline; loser / tie variants render just the tagline.
class _Tag extends StatelessWidget {
  final BattleResultTag tag;
  final double scale;
  const _Tag({required this.tag, required this.scale});

  @override
  Widget build(BuildContext context) {
    final colour = tag.color();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (tag == BattleResultTag.winner)
          Text(
            '#1',
            style: TextStyle(
              color: colour,
              fontSize: 44 * scale,
              fontWeight: FontWeight.w900,
              fontStyle: FontStyle.italic,
              letterSpacing: -2 * scale,
              height: 1.0,
            ),
          ),
        if (tag == BattleResultTag.winner) SizedBox(height: 4 * scale),
        Text(
          tag.title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: colour,
            fontSize: 22 * scale,
            fontWeight: FontWeight.w900,
            letterSpacing: 2 * scale,
            height: 1.05,
          ),
        ),
      ],
    );
  }
}

class _NamesLine extends StatelessWidget {
  final String myName;
  final String opName;
  final double scale;
  const _NamesLine({
    required this.myName,
    required this.opName,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Flexible(
          child: Text(
            myName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 18 * scale,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 10 * scale),
          child: Icon(
            Icons.close_rounded,
            size: 20 * scale,
            color: Colors.white.withValues(alpha: 0.85),
          ),
        ),
        Flexible(
          child: Text(
            opName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 18 * scale,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}

class _ScoreLabels extends StatelessWidget {
  final String myName;
  final String opName;
  final Color myAccent;
  final Color opAccent;
  final double scale;
  const _ScoreLabels({
    required this.myName,
    required this.opName,
    required this.myAccent,
    required this.opAccent,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            myName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: myAccent,
              fontSize: 12 * scale,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4 * scale,
            ),
          ),
        ),
        Text(
          opName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.right,
          style: TextStyle(
            color: opAccent,
            fontSize: 12 * scale,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.4 * scale,
          ),
        ),
      ],
    );
  }
}

class _ScoreValues extends StatelessWidget {
  final int mySteps;
  final int opSteps;
  final Color myAccent;
  final Color opAccent;
  final double scale;
  const _ScoreValues({
    required this.mySteps,
    required this.opSteps,
    required this.myAccent,
    required this.opAccent,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            BattleResultCard._fmt(mySteps),
            style: TextStyle(
              color: myAccent,
              fontSize: 32 * scale,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5 * scale,
              height: 1.0,
            ),
          ),
        ),
        Text(
          BattleResultCard._fmt(opSteps),
          textAlign: TextAlign.right,
          style: TextStyle(
            color: opAccent,
            fontSize: 32 * scale,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.5 * scale,
            height: 1.0,
          ),
        ),
      ],
    );
  }
}

/// Two-tone progress bar that visualises the step ratio. Falls back
/// to an empty rail if neither side has any steps.
class _ScoreBar extends StatelessWidget {
  final int mySteps;
  final int opSteps;
  final Color myColor;
  final Color opColor;
  final double scale;
  const _ScoreBar({
    required this.mySteps,
    required this.opSteps,
    required this.myColor,
    required this.opColor,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    final total = mySteps + opSteps;
    final myFrac = total == 0 ? 0.0 : mySteps / total;
    final opFrac = total == 0 ? 0.0 : opSteps / total;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 10 * scale,
        color: Colors.white.withValues(alpha: 0.18),
        child: Row(
          children: [
            if (myFrac > 0)
              Expanded(
                flex: (myFrac * 1000).round(),
                child: Container(color: myColor),
              ),
            if (opFrac > 0)
              Expanded(
                flex: (opFrac * 1000).round(),
                child: Container(color: opColor),
              ),
          ],
        ),
      ),
    );
  }
}
