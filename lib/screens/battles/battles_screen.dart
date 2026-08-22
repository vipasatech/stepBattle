// [3D-DISABLED-2026-08-21] dart:async import was for `unawaited()` around
// MediaWarmup.primeWebViewEngine() — both commented out below. Re-add on
// re-enable.
// import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../config/colors.dart';
import '../../models/battle_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/battle_provider.dart';
// [3D-DISABLED-2026-08-21] media_warmup import was only used for
// primeWebViewEngine, commented below.
// import '../../services/media_warmup.dart';
import '../../sheets/new_battle_selection_sheet.dart';
import '../../sheets/pending_battle_actions_sheet.dart';
import '../../widgets/avatar_circle.dart';
import '../../widgets/glass_card.dart';
import '../../widgets/insufficient_xp_dialog.dart';
import '../../widgets/mount_stagger.dart';
import '../../widgets/shimmer_loader.dart';
import '../../providers/subscription_provider.dart';
import '../../sheets/upgrade_cta_sheet.dart';
import '../family/widgets/incoming_family_invite_card.dart';
import 'widgets/battle_card.dart';

/// Session-local set of series IDs the user has stopped via the
/// inline "Stop recurring" action. Populated on successful
/// [BattleService.stopSeries] and read by [_stopRecurringCallback]
/// to hide the button on the next rebuild — otherwise the button
/// keeps showing until app restart because BattleModel doesn't
/// hydrate `battle_series.status`, and `battle_participants` realtime
/// doesn't fire when only the series row flips.
///
/// Session-only is fine: on cold-start the series is refetched and
/// its post-stop lifecycle (settle_daily_battle marking the series
/// stopped, no more spawn, etc.) means the whole battle typically
/// won't reappear in the "active" list at all.
final _clientStoppedSeriesIdsProvider =
    StateProvider<Set<String>>((_) => const {});

class BattlesScreen extends ConsumerStatefulWidget {
  const BattlesScreen({super.key});

  @override
  ConsumerState<BattlesScreen> createState() => _BattlesScreenState();
}

class _BattlesScreenState extends ConsumerState<BattlesScreen> {
  @override
  void initState() {
    super.initState();
    // Auto-cancel any pending battles older than 24h that the user
    // created, and pull scheduled battles into the active state.
    // Battle COMPLETION is server-owned since 1.1.6+29 (see the block
    // comment on battle_service.completeExpiredBattles); we no longer
    // call that here — the server cron settles the pot and flips
    // status, and the "Ending…" pill on active-past-end-time cards
    // covers the ~60 s transition window for the user.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final uid = ref.read(authStateProvider).valueOrNull?.id;
      if (uid != null) {
        final svc = ref.read(battleServiceProvider);
        svc.cancelExpiredPendingBattles(uid);
        svc.activateScheduledBattles(uid);
      }
      // [3D-DISABLED-2026-08-21] — WebView priming skipped. The 3D
      // character system is disabled, so the WebView never mounts and
      // priming it wastes ~500-1000 ms of CPU on every Battles tab
      // open. Re-enable alongside the rest of the 3D stack.
      //
      // Prime the WebView engine so the first `Flutter3DViewer` mount
      // (avatar customizer / arena) doesn't pay the ~500-1000 ms
      // cold-start. The user is on the Battles tab → arena open is
      // seconds away; this is the right place for this warmup, not
      // during the splash where it competed with first-paint I/O.
      // unawaited(MediaWarmup.primeWebViewEngine());
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Strava-style hero header:
    //   ── Row 1 (AppBar) ──────────────────────────────────
    //   Battles                              [+ New Battle]
    //   ── Row 2 (AppBar.bottom) ───────────────────────────
    //   0/60 · Pro Pass · B/W —
    //
    // Title is left-aligned (not centered like the other shell tabs)
    // and up-sized to headlineMedium/w800 so it acts as the anchor
    // for the whole tab. Primary action pinned right, thumb-reachable.
    // Stats collapse to a single muted caption below — one line of
    // secondary information instead of two competing pills.
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        titleSpacing: 20,
        title: Text(
          'Battles',
          style: theme.textTheme.headlineMedium?.copyWith(
            color: AppColors.onSurface,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: () => _showNewBattleSheet(context),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('New Battle'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 8),
                textStyle: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(28),
          child: Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: _BattlesHeaderCaption(),
            ),
          ),
        ),
      ),
      body: const _BattlesBody(),
    );
  }

  Future<void> _showNewBattleSheet(BuildContext context) async {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      // Push to root navigator so the sheet covers the shell's bottom nav.
      // Without this, the CTA at the bottom of the setup sheets is hidden
      // behind the floating nav (extendBody: true on the shell scaffold).
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const NewBattleSelectionSheet(),
    );
  }
}

/// Returns the "Start Now" callback for the pending-battle card when the
/// current user is the creator AND enough people have joined to actually
/// start. Applies to BOTH Group and Team battles under the 24h lifecycle
/// (Migration 0040) — 1v1 has no manual start (opponent's accept fires
/// activation automatically).
///
/// Gating rules mirror [BattleService.startBattleNow]:
///   • Group: creator + ≥1 non-creator acceptor
///   • Team:  creator + ≥1 non-creator acceptor + ≥2 teams have members
VoidCallback? _startBattleNowCallback(
  BuildContext context,
  WidgetRef ref,
  BattleModel b,
  String uid,
) {
  if (b.type == BattleType.oneVsOne) return null;
  if (b.status != BattleStatus.pending) return null;
  if (b.createdBy != uid) return null;

  final accepted = b.participants
      .where((p) => p.inviteStatus == ParticipantInviteStatus.accepted)
      .toList();
  final nonCreatorAcceptors =
      accepted.where((p) => p.userId != uid).length;
  if (nonCreatorAcceptors < 1) return null;

  if (b.type == BattleType.team) {
    final teamsWithMembers = <String>{
      for (final p in accepted)
        if (p.teamLabel != null) p.teamLabel!,
    };
    if (teamsWithMembers.length < 2) return null;
  }

  return () async {
    final pending = b.participants
        .where((p) => p.inviteStatus == ParticipantInviteStatus.pending)
        .length;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Start with current players?'),
        content: Text(
          pending == 0
              ? 'Roster locks and the clock starts immediately.'
              : '$pending player${pending == 1 ? "" : "s"} still pending. '
                  "They'll be dropped and the clock starts immediately.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep waiting'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Start now'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await ref.read(battleServiceProvider).startBattleNow(
            battleId: b.battleId,
            actorId: uid,
          );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Battle started!')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start: $e')),
        );
      }
    }
  };
}

/// Returns the "Leave lobby" callback for non-creator participants of a
/// pending team battle. Returns null unless ALL of these hold:
///   • Battle is a team battle
///   • Battle is still pending (lobby, not active/completed)
///   • Current user IS a participant with `invite_status = accepted`
///   • Current user is NOT the creator (they use the sheet's Cancel
///     button to end the whole lobby)
///
/// On tap: confirmation dialog, then [BattleService.leaveTeamBattle]
/// (Migration 0042's `refund_participant_stake` RPC — refunds the
/// leaver's stake + marks them rejected). Everyone else's pot shrinks
/// in real time via the participants stream.
VoidCallback? _leaveLobbyCallback(
  BuildContext context,
  WidgetRef ref,
  BattleModel b,
  String uid,
) {
  if (b.type != BattleType.team) return null;
  if (b.status != BattleStatus.pending) return null;
  if (b.createdBy == uid) return null;
  final me = b.participantFor(uid);
  if (me == null) return null;
  if (me.inviteStatus != ParticipantInviteStatus.accepted) return null;
  return () async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainerHigh,
        title: const Text('Leave this lobby?'),
        content: Text(
          b.stakeXp > 0
              ? 'You\'ll get your ${b.stakeXp} XP stake back. The remaining players stay in the lobby.'
              : 'You\'ll leave the lobby. The remaining players stay.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Stay'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await ref.read(battleServiceProvider).leaveTeamBattle(
            battleId: b.battleId,
            userId: uid,
          );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              b.stakeXp > 0
                  ? 'Left the lobby. ${b.stakeXp} XP refunded.'
                  : 'Left the lobby.',
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not leave: $e')),
        );
      }
    }
  };
}

/// Returns the `onStopRecurring` callback to pass to [BattleCard] for `b`,
/// or null when the action shouldn't render (battle isn't part of a series,
/// or the current user isn't its creator). The callback prompts the user
/// for confirmation and then calls [BattleService.stopSeries].
VoidCallback? _stopRecurringCallback(
  BuildContext context,
  WidgetRef ref,
  BattleModel b,
  String uid,
) {
  if (b.seriesId == null || b.createdBy != uid) return null;
  // Hide the button after the creator has stopped the series in this
  // session. Reads (not watches) — the caller is `build` which already
  // watches the battle stream via other providers, and a change to the
  // stopped-set triggers a rebuild via the `.watch` in the section
  // header (see _StoppedSeriesWatcher). See
  // `_clientStoppedSeriesIdsProvider` for why session-local is fine.
  if (ref.watch(_clientStoppedSeriesIdsProvider).contains(b.seriesId)) {
    return null;
  }
  return () async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stop daily recurrence?'),
        content: const Text(
          "Today's battle still finishes normally. No new daily instances "
          'will be created starting tomorrow.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep recurring'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Stop recurring'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await ref.read(battleServiceProvider).stopSeries(b.seriesId!);
      // Optimistically mark the series stopped so the button hides
      // on the next rebuild. Any provider watching this set (see
      // _stopRecurringCallback above) will re-evaluate and now
      // return null instead of the callback.
      ref.read(_clientStoppedSeriesIdsProvider.notifier).update(
            (s) => {...s, b.seriesId!},
          );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Daily series stopped. No new instances tomorrow.')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to stop: $e')),
        );
      }
    }
  };
}

/// Muted single-line caption under the Battles title. Collapses what
/// used to be two pills (subscription usage + B/W ratio) plus the tier
/// name into one Strava-style stats line:
///
///   `0/60 · Pro Pass · B/W 45%`
///
/// The usage segment tints amber/red as the user nears their monthly
/// cap so the free-tier ceiling is still visible at a glance — the
/// rest of the line stays in the muted secondary tone. Tap anywhere
/// opens the upgrade CTA sheet (same affordance the old pill had).
class _BattlesHeaderCaption extends ConsumerWidget {
  const _BattlesHeaderCaption();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final uid = ref.watch(authStateProvider).valueOrNull?.id;
    final sub = ref.watch(subscriptionProvider);
    final used = sub.usage.totalEntries;
    final cap = sub.limits.monthlyBattleEntries;
    final ratio = cap == 0 ? 0.0 : used / cap;

    // Same colour ladder the old SubscriptionUsagePill used, so the
    // free-tier ceiling still telegraphs urgency once you're close.
    final Color usageColor = ratio < 0.5
        ? AppColors.onSurfaceVariant
        : (ratio < 0.85 ? AppColors.amber : AppColors.error);

    String bwLabel = 'B/W —';
    if (uid != null) {
      final stats = ref.watch(battleWinStatsProvider(uid)).valueOrNull;
      final bw = stats == null ? null : battleWinRatioOf(stats);
      if (bw != null) bwLabel = 'B/W ${(bw * 100).toStringAsFixed(0)}%';
    }

    final baseStyle = theme.textTheme.bodySmall?.copyWith(
      color: AppColors.onSurfaceVariant,
      fontFamily: 'Manrope',
      fontWeight: FontWeight.w600,
      fontSize: 12.5,
      letterSpacing: 0.1,
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showUpgradeCtaSheet(context),
      child: RichText(
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(
          style: baseStyle,
          children: [
            TextSpan(
              text: '$used/$cap',
              style: TextStyle(color: usageColor, fontWeight: FontWeight.w800),
            ),
            const TextSpan(text: '  ·  '),
            TextSpan(text: sub.tier.displayName),
            const TextSpan(text: '  ·  '),
            TextSpan(text: bwLabel),
          ],
        ),
      ),
    );
  }
}

class _BattlesBody extends ConsumerWidget {
  const _BattlesBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allBattles = ref.watch(allBattlesProvider);

    // Show the live reconnecting pill above whatever the body renders.
    // Realtime errors should never reach the user as raw exception text;
    // `retryingRealtimeStream` (see battle_provider.dart) keeps the
    // StreamProvider in a value state and surfaces the reconnect state
    // via [battlesReconnectingProvider] instead.
    final reconnecting = ref.watch(battlesReconnectingProvider);

    Widget body;
    body = allBattles.when(
      // Phase 2 cache-then-network normally paints the last-known list
      // immediately, so this loading branch only fires on true cold
      // boot with no cache (fresh install / just-signed-in). Shimmer
      // cards read as "content coming" instead of the ambiguous spinner
      // that made a fresh install look like a broken load.
      loading: () => ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
        children: const [
          SizedBox(height: 8),
          ShimmerCard(),
          SizedBox(height: 12),
          ShimmerCard(),
          SizedBox(height: 12),
          ShimmerCard(),
        ],
      ),
      // Non-transient errors only — transient realtime drops are caught
      // by the retry wrapper before they ever reach this branch.
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Could not load battles. Pull to retry.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.onSurfaceVariant),
          ),
        ),
      ),
      data: (_) => const _BattlesListOrEmpty(),
    );

    // Stack the body under a slim "Reconnecting…" pill while the
    // realtime stream is retrying. Pill is intentionally small + at the
    // top so it doesn't obscure content during normal reconnects.
    //
    // Wrap the body in a RefreshIndicator so the user can pull down to
    // re-fetch the battles list on demand. The realtime provider stays
    // live in normal operation; refresh is the escape hatch after a
    // long offline stretch or when the tester wants a definitive
    // "give me the latest right now."
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(allBattlesProvider);
            await Future<void>.delayed(const Duration(milliseconds: 400));
          },
          child: body,
        ),
        if (reconnecting)
          Positioned(
            top: 8,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                      color: AppColors.primary.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.primary),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Reconnecting…',
                      style: TextStyle(
                        color: AppColors.primary,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// =============================================================================
// Body dispatcher — picks between empty state and the per-section list.
// Consumers below each watch ONE bucket so a step-count tick on an active
// battle only rebuilds the Active section, not the Completed / Scheduled /
// Discover / Invites tree above and below it.
// =============================================================================

class _BattlesListOrEmpty extends ConsumerWidget {
  const _BattlesListOrEmpty();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // `.select` narrows the uid watch so an auth-provider tick that
    // doesn't change the user id (e.g. token refresh) doesn't rebuild
    // the whole list.
    final uid = ref.watch(
      authStateProvider.select((a) => a.valueOrNull?.id ?? ''),
    );
    // `hasAnyBattlesProvider` is a plain bool so the empty \u2194 non-empty
    // transition is the only thing that rebuilds this widget. The
    // per-section consumers below take care of their own live updates.
    final hasAny = ref.watch(hasAnyBattlesProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
      cacheExtent: 800,
      children: [
        // Discover tile ALWAYS renders \u2014 including for brand-new
        // users with zero battles. A newcomer's fastest path to
        // their first battle is joining a public one; hiding this
        // behind "have at least one battle first" inverted the
        // funnel. The RepaintBoundary keeps ambient ticks from
        // dirtying the compositor here.
        RepaintBoundary(
          child: _DiscoverEntryTile(
            onTap: () => context.push('/battles/discover'),
          ),
        ),
        const SizedBox(height: 20),

        // Pending Family-Pass invites \u2014 self-hides when empty.
        const IncomingFamilyInviteSection(),

        if (hasAny) ...[
          // Each section subscribes to ONLY its own bucket. An
          // Active-battle step tick doesn't walk the Completed /
          // Scheduled / Discover subtrees.
          _IncomingBattleInvitesSection(uid: uid),
          _ActiveBattlesSection(uid: uid),
          _ScheduledBattlesSection(uid: uid),
          _CompletedBattlesSection(uid: uid),
        ] else
          _EmptyBattlesInlineCard(
            onStartBattle: () => _showNewBattleSheet(context),
          ),
      ],
    );
  }

  void _showNewBattleSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const NewBattleSelectionSheet(),
    );
  }
}

/// Compact inline empty-state card shown BELOW the persistent
/// Discover tile when the user has no battles yet. Deliberately
/// smaller than the full-screen `EmptyState` widget so it doesn't
/// out-shout the Discover CTA above it \u2014 the primary invitation is
/// "jump into a public battle"; this is the secondary "or start
/// your own".
class _EmptyBattlesInlineCard extends StatelessWidget {
  final VoidCallback onStartBattle;
  const _EmptyBattlesInlineCard({required this.onStartBattle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        decoration: BoxDecoration(
          color: AppColors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: AppColors.onSurface.withValues(alpha: 0.05),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.bolt, color: AppColors.primary, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'No battles yet',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'Jump into a public battle above, or challenge a friend to a private one.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: onStartBattle,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Start a Battle'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IncomingBattleInvitesSection extends ConsumerWidget {
  final String uid;
  const _IncomingBattleInvitesSection({required this.uid});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final incoming =
        ref.watch(incomingBattleInvitesProvider).valueOrNull ?? const [];
    if (incoming.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(
          title: 'Incoming Invites',
          count: incoming.length,
          highlight: true,
        ),
        const SizedBox(height: 12),
        ...incoming.map((b) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: RepaintBoundary(
                child: _IncomingInviteCard(battle: b, currentUserId: uid),
              ),
            )),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _ActiveBattlesSection extends ConsumerWidget {
  final String uid;
  const _ActiveBattlesSection({required this.uid});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeBattlesProvider);
    if (active.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(title: 'Active Battles', count: active.length),
        const SizedBox(height: 12),
        // Stagger only the first 6 cards on mount — a long active-list
        // shouldn't stall the section render. Cards use battleId in
        // their outer Padding key so identity stays stable across
        // Riverpod ticks and animations don't replay.
        MountStagger(
          animateCount: 6,
          children: [
            for (final b in active)
              Padding(
                key: ValueKey('active-${b.battleId}'),
                padding: const EdgeInsets.only(bottom: 12),
                child: BattleCard(
                  battle: b,
                  currentUserId: uid,
                  onTap: () => context.push('/battle-ground/${b.battleId}'),
                  onStopRecurring:
                      _stopRecurringCallback(context, ref, b, uid),
                ),
              ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _ScheduledBattlesSection extends ConsumerWidget {
  final String uid;
  const _ScheduledBattlesSection({required this.uid});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheduled = ref.watch(scheduledBattlesProvider);
    if (scheduled.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(
          title: 'Waiting for Opponent',
          count: scheduled.length,
          onChevronTap: () => context.go('/battles/pending'),
        ),
        const SizedBox(height: 12),
        MountStagger(
          animateCount: 6,
          children: [
            for (final b in scheduled)
              Padding(
                key: ValueKey('scheduled-${b.battleId}'),
                padding: const EdgeInsets.only(bottom: 12),
                child: BattleCard(
                  battle: b,
                  currentUserId: uid,
                  onTap: () {
                    // Team battle cards route to the full-screen lobby
                    // page — creator + joiners share the same URL so an
                    // accidental back-swipe out of the lobby leaves it
                    // reopenable in the same state.
                    if (b.type == BattleType.team) {
                      context.push('/team-lobby/${b.battleId}');
                    } else {
                      showPendingBattleActionsSheet(
                        context,
                        battle: b,
                        currentUserId: uid,
                      );
                    }
                  },
                  onStopRecurring:
                      _stopRecurringCallback(context, ref, b, uid),
                  onStartTeamBattle:
                      _startBattleNowCallback(context, ref, b, uid),
                  onLeaveLobby:
                      _leaveLobbyCallback(context, ref, b, uid),
                ),
              ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _CompletedBattlesSection extends ConsumerWidget {
  final String uid;
  const _CompletedBattlesSection({required this.uid});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Preview uses the lean top-5 provider so this section only
    // rebuilds when one of the visible five actually changes —
    // historical completed churn is invisible here.
    final recent = ref.watch(recentCompletedBattlesProvider);
    if (recent.isEmpty) return const SizedBox.shrink();
    // Peek the full provider only for the "show all" chevron count
    // — reading it here doesn't materialise the full list into
    // widget space, just uses its length for the badge.
    final fullLength = ref.watch(completedBattlesProvider).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionHeader(
          title: 'Completed',
          count: fullLength,
          onChevronTap: fullLength > 5
              ? () => context.push('/battles/completed')
              : null,
        ),
        const SizedBox(height: 12),
        MountStagger(
          animateCount: 6,
          children: [
            for (final b in recent)
              Padding(
                key: ValueKey('completed-${b.battleId}'),
                padding: const EdgeInsets.only(bottom: 12),
                child: BattleCard(
                  battle: b,
                  currentUserId: uid,
                  onTap: () => context.push('/battle-status/${b.battleId}'),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

// =============================================================================
// Incoming battle invite card with Accept / Reject
// =============================================================================
class _IncomingInviteCard extends ConsumerStatefulWidget {
  final BattleModel battle;
  final String currentUserId;

  const _IncomingInviteCard({
    required this.battle,
    required this.currentUserId,
  });

  @override
  ConsumerState<_IncomingInviteCard> createState() =>
      _IncomingInviteCardState();
}

class _IncomingInviteCardState extends ConsumerState<_IncomingInviteCard> {
  bool _busy = false;

  Future<void> _accept() async {
    // Subscription gate — pick the right decision by battle visibility.
    // Invites always flow through the private-join counter unless the
    // battle is a public one someone tapped-to-join with a code (which
    // is discover_battles flow, not this).
    final isPublic = widget.battle.visibility == BattleVisibility.public;
    final decision = isPublic
        ? ref.read(canJoinPublicBattleProvider)
        : ref.read(canJoinPrivateBattleProvider);
    if (!decision.allowed) {
      await showUpgradeCtaSheet(
        context,
        focusTier: decision.upgradeTo,
      );
      return;
    }
    // Insufficient-XP pre-check on the accept side. acceptInvite
    // charges the stake server-side; if we let it run, the RPC
    // rejects with a generic error and the invite gets stuck in a
    // half-accepted state. Show the buy-XP path first, and only
    // call acceptInvite if the user has (or gains) enough XP.
    final stake = widget.battle.stakeXp;
    if (stake > 0) {
      final me = ref.read(currentUserProvider).valueOrNull;
      final balance = me?.totalXP ?? 0;
      if (balance < stake) {
        await showInsufficientXpDialog(
          context,
          required: stake,
          balance: balance,
          action: 'accept this invite',
        );
        return;
      }
    }
    setState(() => _busy = true);
    var accepted = false;
    try {
      await ref.read(battleServiceProvider).acceptInvite(
            battleId: widget.battle.battleId,
            userId: widget.currentUserId,
          );
      accepted = true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not accept: $e')),
        );
      }
    }
    if (mounted) setState(() => _busy = false);
    // Post-accept routing per battle type:
    //
    //   • Team  → team lobby. The battle stays pending until the
    //     creator hits Start, so pushing to arena early would show
    //     an empty leaderboard.
    //   • 1v1   → arena. acceptInvite runs _snapAndActivate the
    //     moment the opponent accepts, so the battle is already
    //     active by the time we push. This is what the tester asked
    //     for — accepting an invite should land the invitee in the
    //     arena, not leave them staring at the Battles list.
    //   • Group → arena, same reasoning (last-accept flips status
    //     to active via _snapAndActivate or _activateBattle).
    if (accepted && mounted) {
      if (widget.battle.type == BattleType.team) {
        context.push('/team-lobby/${widget.battle.battleId}');
      } else {
        context.push('/battle-ground/${widget.battle.battleId}');
      }
    }
  }

  Future<void> _reject() async {
    setState(() => _busy = true);
    try {
      await ref.read(battleServiceProvider).rejectInvite(
            battleId: widget.battle.battleId,
            userId: widget.currentUserId,
          );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not reject: $e')),
        );
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final battle = widget.battle;

    // Find the inviter (the first participant who accepted — usually the creator)
    final inviter = battle.participants.firstWhere(
      (p) => p.userId == battle.createdBy,
      orElse: () => battle.participants.first,
    );

    final typeLabel = switch (battle.type) {
      BattleType.oneVsOne => '1v1',
      BattleType.group => 'Multi battle',
      BattleType.team => 'Team',
    };

    return GlassCard(
      padding: const EdgeInsets.all(16),
      border: Border.all(color: AppColors.amber.withValues(alpha: 0.3)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AvatarCircle(
                radius: 22,
                imageUrl: inviter.avatarURL,
                initials: inviter.friendlyName.isNotEmpty
                    ? inviter.friendlyName[0].toUpperCase()
                    : '?',
                borderColor: AppColors.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${inviter.friendlyName} challenged you',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    Text(
                      '$typeLabel battle · ${battle.durationDays}-day duration · +${battle.stakeXp} XP on win',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.onSurfaceVariant),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_busy)
            Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.primary),
              ),
            )
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _reject,
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(
                          color: AppColors.error.withValues(alpha: 0.4)),
                      foregroundColor: AppColors.error,
                    ),
                    child: const Text('Reject'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: _accept,
                    child: const Text('Accept'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Persistent tile that points to the public lobby list. Doubles as a
/// "paste join code" entry point (long-press → dialog).
class _DiscoverEntryTile extends ConsumerWidget {
  final VoidCallback onTap;
  const _DiscoverEntryTile({required this.onTap});

  Future<void> _pasteCode(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surfaceContainer,
        title: const Text('Join with code'),
        content: TextField(
          controller: controller,
          textCapitalization: TextCapitalization.characters,
          maxLength: 6,
          decoration: const InputDecoration(
            hintText: 'e.g. A4X9KP',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, controller.text.trim().toUpperCase()),
            child: const Text('Join'),
          ),
        ],
      ),
    );
    if (code == null || code.length != 6) return;
    final me = ref.read(currentUserProvider).valueOrNull;
    if (me == null) return;
    try {
      final battleId =
          await ref.read(battleServiceProvider).joinByCode(
                code: code,
                userId: me.userId,
                displayName: me.displayName,
                preferredName: me.preferredName,
                avatarUrl: me.avatarURL,
              );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Joined!')),
        );
        context.push('/battle-ground/$battleId');
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return GlassCard(
      padding: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.travel_explore,
                    color: AppColors.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Discover open battles',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    Text(
                      'Public lobbies you can drop into',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Join with code',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.qr_code, color: AppColors.primary),
                onPressed: () => _pasteCode(context, ref),
              ),
              Icon(Icons.chevron_right, color: AppColors.primary),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final bool highlight;
  final VoidCallback? onChevronTap;

  const _SectionHeader({
    required this.title,
    required this.count,
    this.highlight = false,
    this.onChevronTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chevron = Icon(
      Icons.chevron_right,
      color: onChevronTap != null
          ? AppColors.primary
          : AppColors.primary.withValues(alpha: 0.25),
      size: 24,
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Text(
              title,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: highlight ? AppColors.amber : AppColors.onSurface,
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: highlight
                      ? AppColors.amber.withValues(alpha: 0.15)
                      : AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('$count',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: highlight ? AppColors.amber : AppColors.primary,
                      fontWeight: FontWeight.w900,
                    )),
              ),
            ],
          ],
        ),
        onChevronTap != null
            ? GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onChevronTap,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: chevron,
                ),
              )
            : chevron,
      ],
    );
  }
}
