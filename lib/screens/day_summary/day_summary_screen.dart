import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/colors.dart';
import '../../models/battle_model.dart';
import '../../models/run_session_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/day_summary_provider.dart';
import '../../widgets/glass_card.dart';
import '../track/track_session_detail_screen.dart';
import 'widgets/day_summary_battle_card.dart';

/// Per-day summary screen.
///
/// Reached by tapping a past day in the home-screen streak strip. The
/// page is parametrised by an ISO date (`yyyy-MM-dd`) and renders:
///   • A stats card (steps + XP earned/lost + calories + distance) for
///     that single date.
///   • A "Battle" section listing any battles whose window overlaps the
///     date.
///   • An "Activity" section listing track sessions for the date.
///
/// Empty-state copy per user spec:
///   • Battles AND Activity both empty → one banner that reads
///     "No battle & activity data recorded".
///   • Only Battles empty → "No battle data recorded" in the Battle
///     section; the Activity section still renders its data.
///   • Only Activity empty → mirror.
class DaySummaryScreen extends ConsumerWidget {
  /// ISO date the page is rendering. Always `yyyy-MM-dd` local.
  final String dateIso;

  const DaySummaryScreen({super.key, required this.dateIso});

  /// Default stride (same constant as run_tracking_service + the home
  /// distance pill) so the home and day-summary numbers agree.
  static const _defaultStrideMeters = 0.762;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final asyncData = ref.watch(daySummaryProvider(dateIso));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: Text(
          formatDayHeader(dateIso),
          style: theme.textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
      ),
      body: asyncData.when(
        loading: () => Center(
          child: CircularProgressIndicator(color: AppColors.primary),
        ),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Could not load day summary: $e',
              style: TextStyle(color: AppColors.onSurface),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        data: (d) => _DayBody(data: d, strideMeters: _defaultStrideMeters),
      ),
    );
  }
}

// =============================================================================
// Body — scrolling stack of stat card + battle section + activity section
// =============================================================================

class _DayBody extends ConsumerWidget {
  final DaySummaryData data;
  final double strideMeters;

  const _DayBody({required this.data, required this.strideMeters});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final distanceMeters = data.steps * strideMeters;
    final bothEmpty = !data.hasBattles && !data.hasSessions;
    // Needed by LiveBattleCard / CompletedBattleCard to derive per-user
    // step deltas and "you won"/"you lost" captions.
    final uid = ref.watch(authStateProvider).valueOrNull?.id ?? '';

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      children: [
        _StatsCard(
          steps: data.steps,
          calories: data.calories,
          distanceMeters: distanceMeters,
          xpEarned: data.xpEarned,
          xpLost: data.xpLost,
        ),

        const SizedBox(height: 24),

        // Combined empty banner takes priority when nothing was
        // recorded for the date — collapses two empty sections into
        // one calm placeholder.
        if (bothEmpty)
          const _EmptyBanner(text: 'No battle & activity data recorded')
        else ...[
          _SectionHeader(label: 'BATTLES'),
          const SizedBox(height: 10),
          if (data.hasBattles)
            // Same cards the Battles tab shows for live / completed
            // battles — read-only here (no arena button, no tap-to-
            // open). Non-live/completed statuses (pending, scheduled,
            // cancelled) still use the compact tile because the big
            // cards need per-user step deltas that only exist once a
            // battle is live.
            ..._buildBattleCards(data.battles, uid)
          else
            const _EmptyBanner(text: 'No battle data recorded'),
          const SizedBox(height: 20),
          _SectionHeader(label: 'ACTIVITY'),
          const SizedBox(height: 10),
          if (data.hasSessions)
            // Same rich track-session card the Home tab's "today's
            // session" peek uses — 2×2 stats grid + kcal + media
            // carousel with map + photos. Non-clickable here.
            ...data.sessions.map((s) => Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _DaySummarySessionCard(session: s),
                ))
          else
            const _EmptyBanner(text: 'No activity data recorded'),
        ],
      ],
    );
  }

  /// Build the ordered widget list for the BATTLES section.
  ///
  /// 1v1 battles (active + completed with a known opponent) render as
  /// the rich [DaySummaryBattleCard]. If the user played MULTIPLE
  /// qualifying 1v1s on this date, the cards stack into a swipeable
  /// [_BattleCarousel] with page dots. Group / team / cancelled /
  /// pending battles fall back to the compact [_BattleTile] since
  /// "You vs X" and single-opponent step deltas don't map cleanly.
  List<Widget> _buildBattleCards(List<BattleModel> battles, String uid) {
    final rich = <BattleModel>[];
    final fallback = <BattleModel>[];

    for (final b in battles) {
      final isRichEligible = b.type == BattleType.oneVsOne &&
          (b.status == BattleStatus.active ||
              b.status == BattleStatus.completed) &&
          b.opponentFor(uid) != null;
      if (isRichEligible) {
        rich.add(b);
      } else {
        fallback.add(b);
      }
    }

    final widgets = <Widget>[];

    if (rich.length == 1) {
      widgets.add(Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DaySummaryBattleCard(battle: rich.first, uid: uid),
      ));
    } else if (rich.length > 1) {
      widgets.add(Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _BattleCarousel(battles: rich, uid: uid),
      ));
    }

    for (final b in fallback) {
      widgets.add(Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _BattleTile(battle: b),
      ));
    }

    return widgets;
  }
}

/// Swipeable stack of `DaySummaryBattleCard`s — used when the user
/// has multiple 1v1 battles on the same day. Small dots below track
/// the current page; the PageView itself has default bouncing physics
/// so the swipe feel matches the rest of the app.
class _BattleCarousel extends StatefulWidget {
  final List<BattleModel> battles;
  final String uid;
  const _BattleCarousel({required this.battles, required this.uid});

  @override
  State<_BattleCarousel> createState() => _BattleCarouselState();
}

class _BattleCarouselState extends State<_BattleCarousel> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 220 dp accommodates the rich card's content on typical
        // Manrope-scaled devices. If your text scale is 1.3× the
        // bottom footer might crowd; that's a rare edge case.
        SizedBox(
          height: 220,
          child: PageView.builder(
            controller: _controller,
            itemCount: widget.battles.length,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (_, i) => DaySummaryBattleCard(
              battle: widget.battles[i],
              uid: widget.uid,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (int i = 0; i < widget.battles.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: i == _page ? 16 : 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: i == _page
                        ? AppColors.primary
                        : AppColors.outlineVariant.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Read-only wrapper around [SessionDetailBody] for Day Summary's
/// ACTIVITY section. Same 2×2 stats grid + kcal + media carousel the
/// Home tab's "today's session" peek shows, minus the InkWell — the
/// user is already on a day-detail page so tapping shouldn't nav
/// anywhere.
class _DaySummarySessionCard extends StatelessWidget {
  final RunSession session;
  const _DaySummarySessionCard({required this.session});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
      ),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 20),
      child: SessionDetailBody(
        session: session,
        compactStats: true,
        showDisclosures: false,
        showMetaChips: false,
      ),
    );
  }
}

// =============================================================================
// Stats card — mirrors the Overview-card aesthetic but parameterised
// =============================================================================

class _StatsCard extends StatelessWidget {
  final int steps;
  final int calories;
  final double distanceMeters;
  final int xpEarned;
  final int xpLost;

  const _StatsCard({
    required this.steps,
    required this.calories,
    required this.distanceMeters,
    required this.xpEarned,
    required this.xpLost,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Text(
              _formatNumber(steps),
              style: theme.textTheme.displayLarge?.copyWith(
                fontSize: 44,
                color: AppColors.onSurface,
                height: 1.0,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Center(
            child: Text(
              'STEPS',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                letterSpacing: 2.5,
                fontSize: 10,
              ),
            ),
          ),
          const SizedBox(height: 14),

          // XP lines — show "+X earned" and/or "-Y lost" depending on
          // what actually happened that day. Per the empty-state spec:
          // omit either line when its value is zero.
          if (xpEarned > 0 || xpLost > 0)
            Center(
              child: Column(
                children: [
                  if (xpEarned > 0)
                    _XpLine(
                      label: '+${_formatNumber(xpEarned)} XP earned',
                      icon: Icons.trending_up,
                      color: AppColors.success,
                    ),
                  if (xpEarned > 0 && xpLost > 0)
                    const SizedBox(height: 4),
                  if (xpLost > 0)
                    _XpLine(
                      label: '-${_formatNumber(xpLost)} XP lost',
                      icon: Icons.trending_down,
                      color: AppColors.error,
                    ),
                ],
              ),
            ),

          if (xpEarned == 0 && xpLost == 0)
            Center(
              child: Text(
                'No XP movement this day',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.onSurfaceVariant,
                ),
              ),
            ),

          const SizedBox(height: 18),

          // Bottom stat row — calories + distance side by side.
          Row(
            children: [
              Expanded(
                child: _MiniStat(
                  icon: Icons.bolt,
                  iconColor: AppColors.amber,
                  value: '$calories',
                  unit: 'kcal',
                  label: 'Burnt',
                ),
              ),
              Container(
                width: 1,
                height: 32,
                color: AppColors.outlineVariant.withValues(alpha: 0.4),
              ),
              Expanded(
                child: _MiniStat(
                  icon: Icons.straighten,
                  iconColor: AppColors.primary,
                  value: _fmtDistanceValue(distanceMeters),
                  unit: _fmtDistanceUnit(distanceMeters),
                  label: 'Distance',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _formatNumber(int n) {
    if (n == 0) return '0';
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  static String _fmtDistanceValue(double meters) {
    if (meters < 100) return '${meters.round()}';
    final km = meters / 1000.0;
    return km.toStringAsFixed(km < 10 ? 2 : 1);
  }

  static String _fmtDistanceUnit(double meters) =>
      meters < 100 ? 'm' : 'km';
}

class _XpLine extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  const _XpLine(
      {required this.label, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

class _MiniStat extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String value;
  final String unit;
  final String label;
  const _MiniStat({
    required this.icon,
    required this.iconColor,
    required this.value,
    required this.unit,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Icon(icon, color: iconColor, size: 22),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(width: 3),
            Text(
              unit,
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                fontSize: 11,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: AppColors.onSurfaceVariant,
            fontSize: 10,
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Section header + empty banner
// =============================================================================

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      label,
      style: theme.textTheme.labelSmall?.copyWith(
        color: AppColors.onSurfaceVariant,
        letterSpacing: 2,
        fontWeight: FontWeight.w800,
      ),
    );
  }
}

class _EmptyBanner extends StatelessWidget {
  final String text;
  const _EmptyBanner({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppColors.outlineVariant.withValues(alpha: 0.3),
        ),
      ),
      child: Center(
        child: Text(
          text,
          style: TextStyle(
            color: AppColors.onSurfaceVariant.withValues(alpha: 0.7),
            fontSize: 13,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

// =============================================================================
// Battle tile — compact row showing the battle's outcome for this user
// =============================================================================

class _BattleTile extends ConsumerWidget {
  final BattleModel battle;
  const _BattleTile({required this.battle});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final uid =
        ref.watch(authStateProvider).valueOrNull?.id ?? '';
    final tone = _toneFor(battle.status, battle, uid);
    final title = _titleFor(battle, uid);

    return GestureDetector(
      onTap: battle.status == BattleStatus.completed
          ? () => context.push('/battle-status/${battle.battleId}')
          : null,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: AppColors.outlineVariant.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: tone.tint.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(tone.icon, color: tone.tint, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tone.subtitle,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: tone.tint.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                tone.statusLabel,
                style: TextStyle(
                  color: tone.tint,
                  fontWeight: FontWeight.w800,
                  fontSize: 10,
                  letterSpacing: 0.6,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Battles have no name field; build a "You vs `<opponent>`" or
  /// "Team battle (X teams)" label depending on the type.
  String _titleFor(BattleModel b, String uid) {
    if (b.type == BattleType.team) {
      return '${b.teamCount ?? b.teamLabels.length}-team battle';
    }
    final me = b.participantFor(uid);
    if (me == null) {
      // Spectator-ish case — just list participants.
      return b.participants
          .take(3)
          .map((p) => p.friendlyName)
          .join(' · ');
    }
    final opponents = b.participants
        .where((p) => p.userId != uid)
        .toList();
    if (opponents.isEmpty) return 'Solo battle';
    if (opponents.length == 1) {
      return 'You vs ${opponents.first.friendlyName}';
    }
    return 'You + ${opponents.length} others';
  }

  _BattleTone _toneFor(BattleStatus s, BattleModel b, String uid) {
    switch (s) {
      case BattleStatus.pending:
        return _BattleTone(
          tint: AppColors.onSurfaceVariant,
          icon: Icons.hourglass_empty,
          statusLabel: 'INV',
          subtitle: 'Invite pending',
        );
      case BattleStatus.scheduled:
        return _BattleTone(
          tint: AppColors.amber,
          icon: Icons.schedule,
          statusLabel: 'SOON',
          subtitle: 'Scheduled',
        );
      case BattleStatus.active:
        return _BattleTone(
          tint: AppColors.success,
          icon: Icons.bolt,
          statusLabel: 'LIVE',
          subtitle: 'In progress that day',
        );
      case BattleStatus.completed:
        final isWinner = b.winnerId != null && b.winnerId == uid;
        return _BattleTone(
          tint: isWinner ? AppColors.success : AppColors.primary,
          icon: isWinner ? Icons.emoji_events : Icons.flag,
          statusLabel: isWinner ? 'WON' : 'DONE',
          subtitle: 'Completed',
        );
      case BattleStatus.cancelled:
        return _BattleTone(
          tint: AppColors.error,
          icon: Icons.close,
          statusLabel: 'CXL',
          subtitle: 'Cancelled',
        );
    }
  }
}

class _BattleTone {
  final Color tint;
  final IconData icon;
  final String statusLabel;
  final String subtitle;
  const _BattleTone({
    required this.tint,
    required this.icon,
    required this.statusLabel,
    required this.subtitle,
  });
}

// Track-session rendering moved to [_DaySummarySessionCard] (near the
// top of the file), which wraps SessionDetailBody so the Day Summary
// activity list looks like the Home tab's "today's session" peek.
