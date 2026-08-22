import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/colors.dart';
import '../../models/leaderboard_entry_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/connectivity_provider.dart';
import '../../providers/leaderboard_provider.dart';
import '../../providers/user_provider.dart';
import '../../sheets/location_permission_sheet.dart';
import '../../sheets/set_home_sheet.dart';
import '../../widgets/app_network_image.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/mount_stagger.dart';
import '../../widgets/needs_location_card.dart';
import '../../widgets/shimmer_loader.dart';
import 'widgets/leaderboard_hero.dart';
import 'widgets/rank_row.dart';
import 'widgets/floating_rank_card.dart';

/// Four leaderboard tabs:
///   • District — same locality (~tens of users)
///   • State    — same state/province (~hundreds)
///   • Country  — same country (~thousands)
///   • Friends  — your friends only
///
/// District/State/Country require the user to have set a home district —
/// when unset, those tabs render a "Set home" CTA instead of an empty board.
/// Display order is worldwide (label: "All") → friends → district →
/// state → country. "All" leads because it's the broadest board and
/// makes the most sense as the default landing view — anyone can see
/// themselves against everyone, no home-district required. The tabs
/// bar iterates `_Tab.values` so reordering the enum drives the
/// visual order; all switches stay correct because they're keyed by
/// case, not index.
enum _Tab { worldwide, friends, district, state, country }

extension on _Tab {
  String get label => switch (this) {
        _Tab.worldwide => 'All',
        _Tab.friends => 'Friends',
        _Tab.district => 'District',
        _Tab.state => 'State',
        _Tab.country => 'Country',
      };

  IconData get icon => switch (this) {
        _Tab.worldwide => Icons.public,
        _Tab.friends => Icons.group,
        _Tab.district => Icons.location_city,
        _Tab.state => Icons.map,
        _Tab.country => Icons.flag_outlined,
      };

  /// Map the private `_Tab` to the public [LeaderboardScope] used by
  /// [myScopedRankProvider]. 1:1 by ordinal but kept explicit so
  /// enum reordering can't silently misalign the pill's rank source.
  LeaderboardScope get scope => switch (this) {
        _Tab.worldwide => LeaderboardScope.worldwide,
        _Tab.friends => LeaderboardScope.friends,
        _Tab.district => LeaderboardScope.district,
        _Tab.state => LeaderboardScope.state,
        _Tab.country => LeaderboardScope.country,
      };
}

class LeaderboardScreen extends ConsumerStatefulWidget {
  const LeaderboardScreen({super.key});

  @override
  ConsumerState<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends ConsumerState<LeaderboardScreen> {
  // Default to All (worldwide) — leftmost tab, broadest board, works
  // for every user regardless of whether they've set a home district.
  _Tab _tab = _Tab.worldwide;

  /// Tracks whether we've already attempted the one-time location
  /// re-prompt for this session. Guard so the sheet doesn't keep
  /// appearing every time the user navigates back to Ranks.
  bool _locationPromptShown = false;

  @override
  void initState() {
    super.initState();
    // Re-prompt for location once per session on the first Ranks open.
    // Reason: geo-scoped leaderboards (district/state/country) only
    // populate when the user has a home set, which itself needs
    // location. Better to ask here than have empty tabs.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _locationPromptShown) return;
      _locationPromptShown = true;
      await ensureLocationPermission(
        context,
        reason:
            'StepBattle uses your location to place you on local leaderboards (district, state, country) and to show you how you rank among nearby players.',
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Scoped rank: pill number now reflects the currently-selected tab
    // rather than always showing worldwide. See myScopedRankProvider
    // docstring for why worldwide delegates to the server-count
    // myRankProvider while other scopes scan the loaded list.
    final myRank = ref.watch(myScopedRankProvider(_tab.scope));
    final online = ref.watch(isOnlineProvider).valueOrNull ?? true;
    final user = ref.watch(userProfileProvider).valueOrNull;
    final hasHome = user?.hasHome ?? false;

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(
          'Leaderboards',
          style: theme.textTheme.headlineSmall?.copyWith(
            color: AppColors.onSurface,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              _TabsBar(
                active: _tab,
                onTap: (t) => setState(() => _tab = t),
              ),
              const SizedBox(height: 8),
              // The scope banner used to render here, but was moved
              // INTO `LeaderboardHero` so the rays background can
              // span both the banner AND the top-user profile (per
              // the reference the user shared). It's built here and
              // handed down as a widget so `_Tab` can stay private.
              Expanded(
                child: switch (_tab) {
                  _Tab.friends => _BoardView(
                      provider: 'friends',
                      scopeBanner: _ScopeBanner(tab: _tab, user: user),
                    ),
                  _Tab.district => _GeoTabContent(
                      scope: 'district',
                      hasHome: hasHome,
                      scopeBanner: _ScopeBanner(tab: _tab, user: user),
                    ),
                  _Tab.state => _GeoTabContent(
                      scope: 'state',
                      hasHome: hasHome,
                      scopeBanner: _ScopeBanner(tab: _tab, user: user),
                    ),
                  _Tab.country => _GeoTabContent(
                      scope: 'country',
                      hasHome: hasHome,
                      scopeBanner: _ScopeBanner(tab: _tab, user: user),
                    ),
                  // Worldwide doesn't depend on the user having set a
                  // home district — it's the global leaderboard.
                  _Tab.worldwide => _BoardView(
                      provider: 'worldwide',
                      scopeBanner: _ScopeBanner(tab: _tab, user: user),
                    ),
                },
              ),
            ],
          ),

          // Sticky "You" card — three states:
          //   • Have rank AND ranked >5: normal card
          //   • No rank AND offline: offline card
          //   • Have rank AND ranked ≤5: hide (duplicates the in-list row)
          //   • No rank AND online: hide (loading / unranked)
          //
          // Bottom offset: the shell uses `extendBody: true`, so the
          // Positioned coordinate space runs edge-to-edge under the
          // shell nav bar. Previously hardcoded to `90 + viewPadding`
          // which was too tight on Samsung 3-button devices (nav bar
          // reads ~100dp because of One UI accessibility padding on
          // top of the safe-area inset). Now: measure the shell nav
          // bar via Scaffold.geometryOf so the offset is correct on
          // every device. Fallback of 116dp when geometry hasn't
          // registered yet (first frame) is intentionally generous
          // — over-clearing is safer than under-clearing.
          if (myRank != null && myRank.rank > 5)
            _ShellNavAwareBottomPin(
              child: FloatingRankCard(entry: myRank),
            )
          else if (myRank == null && !online)
            const _ShellNavAwareBottomPin(
              child: FloatingRankCard.offline(),
            ),
        ],
      ),
    );
  }
}

// =============================================================================
// Tabs bar — chip-style, horizontally scrollable. Each tab is its own
// pill with a border; the active tab uses the brand-violet outline +
// text, inactive tabs use a subtle outline + muted text. Matches the
// Strava reference the user shared.
// =============================================================================
class _TabsBar extends StatelessWidget {
  final _Tab active;
  final ValueChanged<_Tab> onTap;
  const _TabsBar({required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _Tab.values.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final t = _Tab.values[i];
          return Center(
            child: _TabChip(
              tab: t,
              isActive: t == active,
              onTap: () => onTap(t),
            ),
          );
        },
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  final _Tab tab;
  final bool isActive;
  final VoidCallback onTap;
  const _TabChip({
    required this.tab,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: isActive
                ? AppColors.primary
                : AppColors.outlineVariant.withValues(alpha: 0.55),
            width: isActive ? 1.5 : 1,
          ),
        ),
        child: Text(
          tab.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: 'Manrope',
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: isActive
                ? AppColors.primary
                : AppColors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Scope banner — shows the current scope label (e.g., "Hyderabad")
// =============================================================================
class _ScopeBanner extends StatelessWidget {
  final _Tab tab;
  final dynamic user; // UserModel
  const _ScopeBanner({required this.tab, required this.user});

  @override
  Widget build(BuildContext context) {
    final scope = _scopeLabel();
    if (scope == null) return const SizedBox(height: 0);

    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Row(
        children: [
          Icon(tab.icon, size: 14, color: AppColors.primary),
          const SizedBox(width: 6),
          Text(
            scope,
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppColors.primary,
              letterSpacing: 1.2,
              fontWeight: FontWeight.w800,
            ),
          ),
          const Spacer(),
          Text(
            'Top by XP',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: AppColors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  String? _scopeLabel() {
    if (user == null) return null;
    return switch (tab) {
      _Tab.friends => 'YOUR FRIENDS',
      _Tab.district =>
        (user.districtName as String?)?.toUpperCase(),
      _Tab.state => (user.stateName as String?)?.toUpperCase(),
      _Tab.country => (user.countryName as String?)?.toUpperCase() ??
          (user.countryCode as String?)?.toUpperCase(),
      _Tab.worldwide => 'GLOBAL',
    };
  }
}

// =============================================================================
// "Set home" CTA shown when user opens a geo-scoped tab without a home.
// =============================================================================
class _SetHomeCta extends StatelessWidget {
  final String scope;
  const _SetHomeCta({required this.scope});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.location_off,
                size: 48, color: AppColors.amber.withValues(alpha: 0.6)),
            const SizedBox(height: 16),
            Text(
              'Set your home to unlock the $scope leaderboard',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'Takes 5 seconds — use your location or enter a postal code.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppColors.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                useRootNavigator: true,
                backgroundColor: Colors.transparent,
                builder: (_) => const SetHomeSheet(),
              ),
              icon: const Icon(Icons.home, size: 18),
              label: const Text('Set home'),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Geo-scoped tab content. If the user already has a home set, just render
// the board. Otherwise pre-flight location state — if the OS-level switch
// is off (or permission denied), render NeedsLocationCard so the user
// can fix it inline; only when location is available do we fall through
// to the _SetHomeCta flow.
// =============================================================================
class _GeoTabContent extends StatefulWidget {
  final String scope;
  final bool hasHome;

  /// Scope banner (built by the leaderboard screen because it needs the
  /// private `_Tab`) — passed through to `_BoardView` so it renders
  /// inside the hero's rays area.
  final Widget scopeBanner;

  const _GeoTabContent({
    required this.scope,
    required this.hasHome,
    required this.scopeBanner,
  });

  @override
  State<_GeoTabContent> createState() => _GeoTabContentState();
}

class _GeoTabContentState extends State<_GeoTabContent> {
  // Null = still resolving. Non-null = "blocked by location" with this reason.
  // Set to null + checking=false when the check returns ok.
  NeedsLocationReason? _blockReason;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    if (!widget.hasHome) {
      _checkLocation();
    } else {
      _checking = false;
    }
  }

  @override
  void didUpdateWidget(covariant _GeoTabContent old) {
    super.didUpdateWidget(old);
    if (old.hasHome != widget.hasHome && !widget.hasHome) {
      _checkLocation();
    }
  }

  Future<void> _checkLocation() async {
    setState(() => _checking = true);
    final reason = await resolveLocationBlock();
    if (!mounted) return;
    setState(() {
      _blockReason = reason;
      _checking = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.hasHome) {
      return _BoardView(
        provider: widget.scope,
        scopeBanner: widget.scopeBanner,
      );
    }
    if (_checking) {
      return ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: const [
          SizedBox(height: 12),
          ShimmerRow(),
          ShimmerRow(),
          ShimmerRow(),
          ShimmerRow(),
          ShimmerRow(),
          ShimmerRow(),
        ],
      );
    }
    if (_blockReason != null) {
      return Center(
        child: NeedsLocationCard(
          reason: _blockReason!,
          featureName: 'StepBattle',
          onRetry: _checkLocation,
        ),
      );
    }
    // Location is available but home isn't set yet — existing CTA.
    return _SetHomeCta(scope: widget.scope);
  }
}

// =============================================================================
// Generic board view — picks the right provider by string key.
// =============================================================================
class _BoardView extends ConsumerWidget {
  final String provider;
  final Widget scopeBanner;

  const _BoardView({
    required this.provider,
    required this.scopeBanner,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = switch (provider) {
      'district' => ref.watch(districtLeaderboardProvider),
      'state' => ref.watch(stateLeaderboardProvider),
      'country' => ref.watch(countryLeaderboardProvider),
      'friends' => ref.watch(friendsLeaderboardProvider),
      'worldwide' => ref.watch(globalLeaderboardProvider),
      _ => ref.watch(globalLeaderboardProvider),
    };

    return async.when(
      // Shimmer rows instead of an ambiguous spinner — the leaderboard
      // is a list, so a list-shaped skeleton reads correctly.
      loading: () => ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: const [
          SizedBox(height: 12),
          ShimmerRow(),
          ShimmerRow(),
          ShimmerRow(),
          ShimmerRow(),
          ShimmerRow(),
          ShimmerRow(),
          ShimmerRow(),
          ShimmerRow(),
        ],
      ),
      error: (e, _) => Center(child: Text('Could not load: $e')),
      data: (entries) {
        if (entries.isEmpty) {
          return EmptyState(
            icon: provider == 'friends' ? Icons.group : Icons.leaderboard,
            title: provider == 'friends'
                ? 'Invite friends to compare'
                : 'No one ranked here yet',
            subtitle: provider == 'friends'
                ? 'Add friends to see your ranking among them.'
                : 'Be the first — start walking to claim the top spot!',
          );
        }
        return _LeaderboardList(
          entries: entries,
          scopeBanner: scopeBanner,
        );
      },
    );
  }
}

// =============================================================================
// Shared list view — podium + rest
// =============================================================================
class _LeaderboardList extends ConsumerStatefulWidget {
  final List<LeaderboardEntry> entries;
  final Widget scopeBanner;

  const _LeaderboardList({
    required this.entries,
    required this.scopeBanner,
  });

  @override
  ConsumerState<_LeaderboardList> createState() => _LeaderboardListState();
}

class _LeaderboardListState extends ConsumerState<_LeaderboardList> {
  /// Number of avatars we pre-warm through `precacheImage` on first
  /// mount. Tuned to cover the initially visible rows + one full
  /// scroll page ahead — after that, on-demand decode is fast enough
  /// (avatars ship through `ResizeImage` so each decode is small).
  static const int _precacheTopN = 20;

  /// Tracks which URLs we've already asked to precache so scroll
  /// re-mounts (e.g. tab-switch back to Ranks) don't re-queue the
  /// same decodes.
  final Set<String> _precacheQueued = <String>{};

  @override
  void initState() {
    super.initState();
    _precacheAvatars();
  }

  @override
  void didUpdateWidget(covariant _LeaderboardList old) {
    super.didUpdateWidget(old);
    // A new entries list (tab switch, filter change) means fresh
    // avatars to warm. `_precacheQueued` de-dupes across calls.
    if (!identical(old.entries, widget.entries)) _precacheAvatars();
  }

  /// Pre-warm the ImageCache with the top-N row avatars so their
  /// decode happens off the scroll critical path. Without this, the
  /// first scroll pass through rows 8-20 stalls one frame each while
  /// their bitmap decodes.
  void _precacheAvatars() {
    // Run after the first frame so we don't compete with the paint
    // pass that's about to render the shimmer / first data frame.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = context;
      final take = widget.entries.length < _precacheTopN
          ? widget.entries.length
          : _precacheTopN;
      final dpr = MediaQuery.of(ctx).devicePixelRatio;
      for (var i = 0; i < take; i++) {
        final url = widget.entries[i].avatarURL;
        if (url == null || url.isEmpty) continue;
        if (!_precacheQueued.add(url)) continue;
        // `AvatarCircle` uses radius: 22 (44 dp diameter) for
        // RankRow; match that to the ResizeImage config so the
        // cache warmup and the widget-side decode land on the same
        // cache key.
        final provider = appNetworkImageProvider(
          url,
          maxSize: 44,
          devicePixelRatio: dpr,
        );
        // Fire-and-forget; the future completes whenever the
        // network + decode is done. Errors already bubble through
        // CachedNetworkImage's error widget on the row itself, so
        // there's nothing meaningful to do here.
        precacheImage(provider, ctx).catchError((_) {});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Current-user id lets us mark exactly one row as "YOU" — the
    // RankRow widget switches to its gradient+pill treatment when
    // highlightYou is true. Anonymous / signed-out state returns
    // null, which correctly leaves every row unhighlighted.
    final currentUid = ref.watch(authStateProvider).valueOrNull?.id;

    // New Strava-style layout:
    //   • Hero at top spotlighting the #1 (laurel wreath + XP + name)
    //   • Small-caps column headers row
    //   • Full ranked list — the #1 appears here too, with a crown
    //     icon in the rank cell, matching Strava's leaderboard design
    //
    // `ListView.builder` (not the eager `ListView(...)` we had before):
    // Country / State boards fetch up to 100 rows; the constructor
    // form built every `RankRow` up front on every rebuild, even the
    // ~90% that were off-screen. With the builder, only the ~8 rows
    // in the viewport materialise. First four indexes are the fixed
    // prelude (hero, gap, headers, divider), remainder are rank rows.
    const preludeItemCount = 4;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 200),
      // Pre-inflate ~800 dp past the viewport. RankRows are ~56 dp
      // tall — that's ~14 rows warm ahead of the scroll edge, which
      // combined with the top-N avatar precache means fast flicks
      // through the board don't stall on decode + inflate.
      cacheExtent: 800,
      itemCount: widget.entries.length + preludeItemCount,
      itemBuilder: (context, index) {
        if (index == 0) {
          return LeaderboardHero(
            topEntry: widget.entries.first,
            scopeBanner: widget.scopeBanner,
          );
        }
        if (index == 1) return const SizedBox(height: 12);
        if (index == 2) return const RankColumnHeaders();
        if (index == 3) {
          // Segregating line between the column-header caps row and
          // the first data row, so the caps read as a header for the
          // table below. Matches the divider style used between rank
          // rows.
          return Divider(
            height: 1,
            thickness: 1,
            color: AppColors.outlineVariant.withValues(alpha: 0.4),
          );
        }
        final rankIndex = index - preludeItemCount;
        final entry = widget.entries[rankIndex];
        // First 6 rank rows get a per-index fade+slide on mount.
        // Rows past 6 render instantly. Recycled rows re-animate when
        // scrolling back to top (documented caveat in StaggerIndex).
        return RankRow(
          entry: entry,
          highlightYou:
              currentUid != null && entry.userId == currentUid,
          onTap: () => _showProfile(context, entry),
        ).staggerAt(rankIndex);
      },
    );
  }

  void _showProfile(BuildContext context, LeaderboardEntry entry) {
    // Self → own Profile tab (has Edit, Settings, Share, no Add-friend
    // affordance). Everyone else → public profile at /users/:userId.
    // Previously we routed self to /users/:selfUid too, which hit the
    // profiles_public view and lost fields our own view has, plus
    // rendered an inappropriate "Add friend" button.
    final selfUid = ref.read(authStateProvider).valueOrNull?.id;
    if (selfUid != null && entry.userId == selfUid) {
      context.push('/profile');
      return;
    }
    context.push('/users/${entry.userId}');
  }
}

/// Positioned wrapper that pins its `child` above the shell nav bar
/// with enough headroom to clear the shell's height on every device
/// we've tested — including Samsung One UI 3-button-nav phones where
/// the shell reads ~100dp tall (larger than the ~90dp we originally
/// budgeted).
///
/// Earlier attempt used `Scaffold.geometryOf(context).value` inside an
/// `AnimatedBuilder` to read the measured nav-bar top edge — that
/// throws "Scaffold.geometryOf() must only be accessed during the
/// paint phase" because ScaffoldGeometry is computed later than build.
/// Reverted to the simpler constant approach with a comfortable
/// margin.
///
/// Constant math:
///   shell nav content     : icon 24 + gap 4 + label ~14 ≈ 42dp
///   shell nav padding     : 8 + 8 (button v-pad) + 8 (container) = 24dp
///   shell total (min)     : ~66dp
///   shell total (Samsung) : ~74dp with One UI extras
///   safe area (gesture)   : +34dp   (added via viewPaddingOf)
///   safety buffer         : +16dp   (clear gap above nav)
///   → 120 + safe area is the floor.
class _ShellNavAwareBottomPin extends StatelessWidget {
  final Widget child;
  const _ShellNavAwareBottomPin({required this.child});

  static const double _minBottom = 120;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 16,
      right: 16,
      bottom: _minBottom + MediaQuery.viewPaddingOf(context).bottom,
      child: child,
    );
  }
}
