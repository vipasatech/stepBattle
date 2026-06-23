import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../config/colors.dart';
import '../../models/leaderboard_entry_model.dart';
import '../../providers/leaderboard_provider.dart';
import '../../providers/user_provider.dart';
import '../../sheets/public_profile_sheet.dart';
import '../../sheets/set_home_sheet.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/needs_location_card.dart';
import 'widgets/podium_section.dart';
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
enum _Tab { friends, district, state, country }

extension on _Tab {
  String get label => switch (this) {
        _Tab.friends => 'Friends',
        _Tab.district => 'District',
        _Tab.state => 'State',
        _Tab.country => 'Country',
      };

  IconData get icon => switch (this) {
        _Tab.friends => Icons.group,
        _Tab.district => Icons.location_city,
        _Tab.state => Icons.map,
        _Tab.country => Icons.public,
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
              _ScopeBanner(tab: _tab, user: user),
              Expanded(
                child: switch (_tab) {
                  _Tab.friends => const _BoardView(provider: 'friends'),
                  _Tab.district => _GeoTabContent(
                      scope: 'district',
                      hasHome: hasHome,
                    ),
                  _Tab.state => _GeoTabContent(
                      scope: 'state',
                      hasHome: hasHome,
                    ),
                  _Tab.country => _GeoTabContent(
                      scope: 'country',
                      hasHome: hasHome,
                    ),
                },
              ),
            ],
          ),

          // Floating rank card
          if (myRank != null)
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
// Tabs bar
// =============================================================================
class _TabsBar extends StatelessWidget {
  final _Tab active;
  final ValueChanged<_Tab> onTap;
  const _TabsBar({required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          for (final t in _Tab.values)
            Expanded(
              child: _TabButton(
                tab: t,
                isActive: t == active,
                onTap: () => onTap(t),
              ),
            ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  final _Tab tab;
  final bool isActive;
  final VoidCallback onTap;
  const _TabButton({
    required this.tab,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: isActive ? AppColors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              tab.icon,
              size: 14,
              color: isActive
                  ? AppColors.onPrimary
                  : AppColors.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              tab.label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: isActive
                    ? AppColors.onPrimary
                    : AppColors.onSurfaceVariant,
                fontWeight: FontWeight.w800,
                fontSize: 11,
              ),
            ),
          ],
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

  const _GeoTabContent({required this.scope, required this.hasHome});

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
    if (widget.hasHome) return _BoardView(provider: widget.scope);
    if (_checking) {
      return const Center(
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
  const _BoardView({required this.provider});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = switch (provider) {
      'district' => ref.watch(districtLeaderboardProvider),
      'state' => ref.watch(stateLeaderboardProvider),
      'country' => ref.watch(countryLeaderboardProvider),
      'friends' => ref.watch(friendsLeaderboardProvider),
      _ => ref.watch(globalLeaderboardProvider),
    };

    return async.when(
      loading: () => const Center(
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
        return _LeaderboardList(entries: entries);
      },
    );
  }
}

// =============================================================================
// Shared list view — podium + rest
// =============================================================================
class _LeaderboardList extends StatelessWidget {
  final List<LeaderboardEntry> entries;

  const _LeaderboardList({required this.entries});

  @override
  Widget build(BuildContext context) {
    final topThree = entries.length >= 3
        ? entries.sublist(0, 3)
        : entries;
    final rest = entries.length > 3 ? entries.sublist(3) : <LeaderboardEntry>[];

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 200),
      children: [
        PodiumSection(
          topThree: topThree,
          onTap: (entry) => _showProfile(context, entry),
        ),
        const SizedBox(height: 20),
        ...rest.map((entry) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: RankRow(
                entry: entry,
                onTap: () => _showProfile(context, entry),
              ),
            )),
      ],
    );
  }

  void _showProfile(BuildContext context, LeaderboardEntry entry) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => PublicProfileSheet(entry: entry),
    );
  }
}
