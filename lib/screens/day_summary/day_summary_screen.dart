import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/colors.dart';
import '../../models/battle_model.dart';
import '../../models/run_session_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/day_summary_provider.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/shimmer_loader.dart';
import '../track/track_session_detail_screen.dart';
import 'widgets/day_summary_battle_card.dart';
import '../battles/widgets/battle_card.dart';

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
        loading: () => ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: const [
            ShimmerLoader(height: 120, borderRadius: 20),
            SizedBox(height: 16),
            ShimmerCard(),
            SizedBox(height: 12),
            ShimmerCard(),
          ],
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
            // Cancelled battles are hidden here. Completed battles
            // (all types) render as the shared BattleCard from the
            // Battles tab. Live 1v1s keep the DaySummaryBattleCard
            // split-score layout. Live group/team + pending/scheduled
            // fall through to the shared BattleCard too.
            ..._buildBattleCards(context, data.battles, uid)
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
  /// Rules (in order of priority):
  ///   1. Cancelled battles are HIDDEN — they're noise on a "here's
  ///      what happened today" recap. Nothing landed, nothing lost.
  ///   2. Completed battles (any type) use the shared [BattleCard]
  ///      from the Battles tab so the visual matches everywhere the
  ///      user sees a completed battle.
  ///   3. Live 1v1 battles use the pretty [DaySummaryBattleCard] with
  ///      the split score. Multiple live 1v1s stack into a
  ///      [_BattleCarousel].
  ///   4. Anything else (live group/team, pending, scheduled) uses the
  ///      shared [BattleCard] which already handles those states.
  List<Widget> _buildBattleCards(
    BuildContext context,
    List<BattleModel> battles,
    String uid,
  ) {
    // Filter cancelled up front — no need to render them at all.
    final visible = battles
        .where((b) => b.status != BattleStatus.cancelled)
        .toList();
    if (visible.isEmpty) return const [];

    final richLive = <BattleModel>[]; // live 1v1 → DaySummaryBattleCard
    final shared = <BattleModel>[];    // completed + live group/team → BattleCard

    for (final b in visible) {
      final isRichLive1v1 = b.type == BattleType.oneVsOne &&
          b.status == BattleStatus.active &&
          b.opponentFor(uid) != null;
      if (isRichLive1v1) {
        richLive.add(b);
      } else {
        shared.add(b);
      }
    }

    final widgets = <Widget>[];

    if (richLive.length == 1) {
      widgets.add(Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DaySummaryBattleCard(battle: richLive.first, uid: uid),
      ));
    } else if (richLive.length > 1) {
      widgets.add(Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _BattleCarousel(battles: richLive, uid: uid),
      ));
    }

    for (final b in shared) {
      widgets.add(Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: BattleCard(
          battle: b,
          currentUserId: uid,
          onTap: () => context.push('/battle-status/${b.battleId}'),
        ),
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

// Old `_BattleTile` (compact CXL/DONE/WON row) removed — the Day
// Summary now uses the shared [BattleCard] from the Battles tab for
// every status except live-1v1 (which uses [DaySummaryBattleCard]),
// and cancelled battles are filtered out entirely in
// [DaySummaryScreen._buildBattleCards].

// Track-session rendering moved to [_DaySummarySessionCard] (near the
// top of the file), which wraps SessionDetailBody so the Day Summary
// activity list looks like the Home tab's "today's session" peek.
