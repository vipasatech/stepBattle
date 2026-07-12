import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/colors.dart';
import '../../models/leaderboard_entry_model.dart';
import '../../providers/leaderboard_provider.dart';
import '../../providers/user_provider.dart';
import '../../sheets/location_permission_sheet.dart';
import '../../sheets/set_home_sheet.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/needs_location_card.dart';
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
/// Display order is friends → district → state → country — friends first
/// because that's the most personally relevant board for most users. The
/// tabs bar iterates `_Tab.values` so reordering the enum drives the visual
/// order; all switches stay correct because they're keyed by case, not index.
enum _Tab { friends, district, state, country, worldwide }

extension on _Tab {
  String get label => switch (this) {
        _Tab.friends => 'Friends',
        _Tab.district => 'District',
        _Tab.state => 'State',
        _Tab.country => 'Country',
        _Tab.worldwide => 'World',
      };

  IconData get icon => switch (this) {
        _Tab.friends => Icons.group,
        _Tab.district => Icons.location_city,
        _Tab.state => Icons.map,
        _Tab.country => Icons.public,
        _Tab.worldwide => Icons.public_off,
      };
}

class LeaderboardScreen extends ConsumerStatefulWidget {
  const LeaderboardScreen({super.key});

  @override
  ConsumerState<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends ConsumerState<LeaderboardScreen> {
  // Default to Friends — leftmost tab, most personally relevant board.
  _Tab _tab = _Tab.friends;

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
    final myRank = ref.watch(myRankProvider).valueOrNull;
    final user = ref.watch(userProfileProvider).valueOrNull;
    final hasHome = user?.hasHome ?? false;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'LEADERBOARD',
          style: theme.textTheme.headlineSmall?.copyWith(
            color: AppColors.onSurface,
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
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

          // Sticky "You" card — only rendered when the user is
          // outside the top 5 (per the redesign spec). If they're
          // already visible in the main list, the card would just
          // duplicate the row and eat scroll real estate.
          if (myRank != null && myRank.rank > 5)
            Positioned(
              left: 16,
              right: 16,
              bottom: 90,
              child: FloatingRankCard(entry: myRank),
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
      return Center(
        child: CircularProgressIndicator(color: AppColors.primary),
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
      loading: () => Center(
          child: CircularProgressIndicator(color: AppColors.primary)),
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
class _LeaderboardList extends StatelessWidget {
  final List<LeaderboardEntry> entries;
  final Widget scopeBanner;

  const _LeaderboardList({
    required this.entries,
    required this.scopeBanner,
  });

  @override
  Widget build(BuildContext context) {
    // New Strava-style layout:
    //   • Hero at top spotlighting the #1 (laurel wreath + XP + name)
    //   • Small-caps column headers row
    //   • Full ranked list — the #1 appears here too, with a crown
    //     icon in the rank cell, matching Strava's leaderboard design
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 200),
      children: [
        LeaderboardHero(
          topEntry: entries.first,
          scopeBanner: scopeBanner,
        ),
        const SizedBox(height: 12),
        const RankColumnHeaders(),
        // Segregating line between the column-header caps row and the
        // first data row, so the caps read as a header for the table
        // below. Matches the divider style used between rank rows.
        Divider(
          height: 1,
          thickness: 1,
          color: AppColors.outlineVariant.withValues(alpha: 0.4),
        ),
        for (final entry in entries)
          RankRow(
            entry: entry,
            onTap: () => _showProfile(context, entry),
          ),
      ],
    );
  }

  void _showProfile(BuildContext context, LeaderboardEntry entry) {
    // Full-screen public profile page instead of the peek sheet —
    // taps from the leaderboard now navigate to `/users/:userId`
    // (root navigator route defined in routes.dart) so users see the
    // same profile surface as the arena avatar taps.
    context.push('/users/${entry.userId}');
  }
}
