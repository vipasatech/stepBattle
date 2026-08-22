import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../../../config/colors.dart';
import '../../../models/leaderboard_entry_model.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/tab_focus_provider.dart';
import '../../../widgets/avatar_circle.dart';
import '../../../widgets/coronation_ring.dart';

/// Top-of-board hero — the #1 leader spotlighted with a monochrome-gold
/// **coronation ring** pulsing behind the avatar. Two cadences share
/// the same visual language:
///   • Ambient loop — always on, quiet, reinforces "this is the top
///     spot" every time the leaderboard opens.
///   • One-shot pulse — fires when the ranks tab is re-focused, and
///     with a distinct beat when the current user has just become #1
///     (the "coronation moment").
/// A crown icon sits above the avatar; XP + name below.
///
/// Historical note: this used to render a brand-violet sweep arc and
/// the celebration effect was full-screen falling confetti. Both were
/// replaced because they read as "birthday" rather than "champion" —
/// gold monochrome rings frame the crown instead of competing with it.
class LeaderboardHero extends ConsumerStatefulWidget {
  final LeaderboardEntry topEntry;

  /// Scope banner ("YOUR FRIENDS" / "HYDERABAD" + "Top by XP").
  final Widget scopeBanner;

  const LeaderboardHero({
    super.key,
    required this.topEntry,
    required this.scopeBanner,
  });

  @override
  ConsumerState<LeaderboardHero> createState() => _LeaderboardHeroState();
}

/// Warm champion-gold used by the leaderboard hero's crown, avatar
/// border, and coronation rings. Sampled from the Strava KOM/QOM
/// crown — more saturated than [AppColors.amber] so it reads as
/// "medal / trophy" rather than "warning tint".
const Color _kChampionGold = Color(0xFFF0B429);

class _LeaderboardHeroState extends ConsumerState<LeaderboardHero> {
  /// Bump this int to fire a fresh one-shot pulse on the coronation
  /// ring. Handled inside CoronationRing via didUpdateWidget.
  int _pulseTrigger = 0;

  @override
  void initState() {
    super.initState();
    // Re-fire the strong pulse whenever the shell reports the user
    // just landed on Ranks — same signal the old violet sweep used.
    ref.listenManual<int>(ranksTabFocusTickProvider, (prev, next) {
      if (!mounted) return;
      setState(() => _pulseTrigger++);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // If the current user is themselves the #1 entry, bump the trigger
    // once per widget lifetime so the coronation pulse fires as a
    // reward moment. The initial mount pulse already runs inside
    // CoronationRing, so no extra work is needed for the same-open
    // case; this only matters when we later plumb rank transitions.
    final currentUid = ref.watch(authStateProvider).valueOrNull?.id;
    final isCurrentUserTop = currentUid != null &&
        widget.topEntry.userId == currentUid;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
            const SizedBox(height: 8),
            widget.scopeBanner,
            const SizedBox(height: 12),

            // Avatar + coronation rings + crown, stacked. The crown sits
            // ON the avatar's rim (overlapping the top of the ring)
            // rather than floating separately above — reads as "wearing
            // the crown" instead of a detached icon.
            //
            // Ring box is 60 * 2.6 = 156 dp square. Avatar diameter 60
            // is centred; its top edge sits at (156 - 60) / 2 = 48 dp
            // from the top of the ring box. The crown is anchored to
            // that edge (with a small overlap so it looks worn, not
            // balanced on top).
            Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.topCenter,
              children: [
                CoronationRing(
                  avatarSize: 60,
                  ringColor: _kChampionGold,
                  oneShotTrigger:
                      _pulseTrigger + (isCurrentUserTop ? 1000 : 0),
                  child: AvatarCircle(
                    radius: 30,
                    imageUrl: widget.topEntry.avatarURL,
                    initials: _initials(widget.topEntry.friendlyName),
                    // Permanent thin gold border = resting-state
                    // crown-holder mark, legible in screenshots and
                    // under reduced-motion where the pulses don't
                    // render.
                    borderColor: _kChampionGold,
                    borderWidth: 2,
                  ),
                ),
                // Crown: ring box top is y=0; avatar top rim is at
                // y=48. Anchor so the icon-box bottom lands right on
                // the rim — the crown's SVG has ~1-2 dp of intrinsic
                // bottom padding, so it sits literally in the line
                // above the profile circle with no visible gap and
                // no overlap.
                Positioned(
                  top: 20,
                  child: Icon(
                    MdiIcons.crown,
                    size: 28,
                    color: _kChampionGold,
                    shadows: [
                      Shadow(
                        color: _kChampionGold.withValues(alpha: 0.55),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 6),

            // ---- Big XP value + label ----
            Text(
              _fmt(widget.topEntry.totalXP),
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w900,
                fontFamily: 'Manrope',
                letterSpacing: -0.8,
                height: 1.0,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'XP',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                letterSpacing: 1.6,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 6),

            // Name of #1. The trophy icon that used to sit beside
            // this line was removed per user request — the crown
            // above the avatar already signals "top spot".
            Text(
              widget.topEntry.friendlyName,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
      ],
    );
  }

  static String _initials(String name) {
    if (name.isEmpty) return '?';
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name[0].toUpperCase();
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

