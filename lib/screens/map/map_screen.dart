import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import '../../config/colors.dart';
import '../../models/leaderboard_entry_model.dart';
import '../../models/user_model.dart';
import '../../providers/leaderboard_provider.dart';
import '../../providers/user_provider.dart';
import '../../services/geo_boundary_loader.dart';
import '../../sheets/avatar_customizer_sheet.dart';
import '../../widgets/fluttermoji_avatar.dart';
import '../../widgets/map_tile_layer.dart';

/// The canonical zoom tiers we snap between.
///
/// `city` was added between `state` and `district` for the map screen's
/// filter row (District / City / State / Country). We don't have city
/// polygon data yet, so the City tier renders as a zoomed-in view over
/// the district polygons — it's mostly a "closer look" preset until
/// city boundaries land.
enum MapTier { world, country, state, city, district }

/// Named extension so tests can import + exercise the tier transition logic
/// without spinning up the [MapScreen] widget.
extension MapTierX on MapTier {
  /// Target zoom level when snapped to this tier.
  double get targetZoom => switch (this) {
        MapTier.world => 2.0,
        MapTier.country => 4.5,
        MapTier.state => 6.5,
        MapTier.city => 8.5,
        MapTier.district => 10.5,
      };

  String get label => switch (this) {
        MapTier.world => 'WORLD',
        MapTier.country => 'COUNTRY',
        MapTier.state => 'STATE',
        MapTier.city => 'CITY',
        MapTier.district => 'DISTRICT',
      };

  MapTier? get oneOut => switch (this) {
        MapTier.district => MapTier.city,
        MapTier.city => MapTier.state,
        MapTier.state => MapTier.country,
        MapTier.country => MapTier.world,
        MapTier.world => null,
      };

  MapTier? get oneIn => switch (this) {
        MapTier.world => MapTier.country,
        MapTier.country => MapTier.state,
        MapTier.state => MapTier.city,
        MapTier.city => MapTier.district,
        MapTier.district => null,
      };
}

final geoBoundaryLoaderProvider =
    Provider<GeoBoundaryLoader>((ref) => GeoBoundaryLoader());

/// Cinematic full-screen map. Opens at the user's district level. Zoom
/// out steps through state → country → world with smooth animated camera
/// transitions. Tap a polygon to drill into its leaderboard.
///
/// This screen REQUIRES the user has set a home district — the host
/// route guards against opening it otherwise (sends them to Set Home first).
class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen>
    with TickerProviderStateMixin {
  late final MapController _map;
  AnimationController? _camAnim;

  MapTier _tier = MapTier.district;
  // Where we are right now (animated end-state).
  LatLng _currentCenter = const LatLng(20, 0);
  double _currentZoom = 2;

  // Boundary data, lazy-loaded.
  List<GeoRegion> _worldCountries = const [];
  List<GeoRegion> _countryStates = const [];
  List<GeoRegion> _stateDistricts = const [];

  bool _ignoreNextEvent = false; // suppress callbacks from our own animation
  bool _firstFrame = true;

  @override
  void initState() {
    super.initState();
    _map = MapController();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Prompt the user to design their character avatar the first
      // time they open the Map. Cancellation is fine — the sheet
      // pops up again on the next Map / Create Battle entry until
      // they save a spec.
      if (mounted) {
        await showAvatarCustomizerIfNeeded(context, ref);
      }
      if (!mounted) return;
      _bootstrap();
    });
  }

  @override
  void dispose() {
    _camAnim?.dispose();
    _map.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Bootstrap — load boundaries + run cinematic open sequence
  // ---------------------------------------------------------------------------

  Future<void> _bootstrap() async {
    final user = ref.read(userProfileProvider).valueOrNull;
    if (user == null || !user.hasHome) {
      // Should not happen — host route should redirect. Defensive close.
      if (mounted) context.pop();
      return;
    }

    final loader = ref.read(geoBoundaryLoaderProvider);

    // Kick off both loads in parallel — world is needed for zoom-out,
    // country for state polygons. Don't await before first cinematic step,
    // we want to show *something* immediately.
    final worldFuture = loader.loadWorldCountries();
    final statesFuture = user.countryCode != null
        ? loader.loadStatesForCountry(user.countryCode!)
        : Future<List<GeoRegion>>.value(const []);

    // Step 1: snap to user's home immediately (no animation) so we have a
    // real position to start the cinematic from.
    final home = _userHomeCenter(user);
    _currentCenter = home;
    _currentZoom = MapTier.district.targetZoom;
    _map.move(home, MapTier.district.targetZoom);

    // Wait for world data — needed for the zoom-out chain.
    _worldCountries = await worldFuture;
    _countryStates = await statesFuture;
    if (!mounted) return;
    setState(() {});

    // Districts are only bundled for India today (placeholder file in
    // assets/geo/IN-districts.geojson, replaced when real data is added).
    if (user.countryCode != null && user.stateName != null) {
      final districts = await loader.loadDistrictsForState(
        countryCode: user.countryCode!,
        stateName: user.stateName!,
      );
      if (!mounted) return;
      setState(() => _stateDistricts = districts);
    }

    // Step 2: cinematic — start zoomed out at world, then animate in
    // through country → state → district. Total ~3.5s.
    if (_firstFrame) {
      _firstFrame = false;
      await _runCinematicOpen(user);
    }
  }

  Future<void> _runCinematicOpen(UserModel user) async {
    final home = _userHomeCenter(user);

    // Jump to world view first (no anim).
    _map.move(const LatLng(20, 0), MapTier.world.targetZoom);
    setState(() {
      _tier = MapTier.world;
      _currentCenter = const LatLng(20, 0);
      _currentZoom = MapTier.world.targetZoom;
    });
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;

    // World → Country
    final countryCenter = _countryCenter(user.countryCode);
    await _animateCameraTo(
      countryCenter ?? home,
      MapTier.country.targetZoom,
      const Duration(milliseconds: 1100),
    );
    if (!mounted) return;
    setState(() => _tier = MapTier.country);

    // Country → State
    final stateCenter = _stateCenter(user);
    await _animateCameraTo(
      stateCenter ?? home,
      MapTier.state.targetZoom,
      const Duration(milliseconds: 1000),
    );
    if (!mounted) return;
    setState(() => _tier = MapTier.state);

    // State → District (home)
    await _animateCameraTo(
      home,
      MapTier.district.targetZoom,
      const Duration(milliseconds: 900),
    );
    if (!mounted) return;
    setState(() => _tier = MapTier.district);
  }

  LatLng _userHomeCenter(UserModel user) {
    if (user.homeLat != null && user.homeLng != null &&
        (user.homeLat != 0 || user.homeLng != 0)) {
      return LatLng(user.homeLat!, user.homeLng!);
    }
    // Fall back to country center if we don't have a fix (PIN-only signup).
    return _countryCenter(user.countryCode) ?? const LatLng(20, 0);
  }

  LatLng? _countryCenter(String? iso2) {
    if (iso2 == null) return null;
    for (final c in _worldCountries) {
      if (c.id.toUpperCase() == iso2.toUpperCase()) return c.center;
    }
    return null;
  }

  LatLng? _stateCenter(UserModel user) {
    final name = user.stateName?.toLowerCase();
    if (name == null) return null;
    for (final s in _countryStates) {
      if (s.name.toLowerCase() == name) return s.center;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Camera animation
  // ---------------------------------------------------------------------------

  Future<void> _animateCameraTo(
    LatLng dest,
    double zoom,
    Duration duration,
  ) async {
    _camAnim?.dispose();
    final controller = AnimationController(vsync: this, duration: duration);
    _camAnim = controller;

    final fromLat = _currentCenter.latitude;
    final fromLng = _currentCenter.longitude;
    final fromZoom = _currentZoom;

    final latTween = Tween<double>(begin: fromLat, end: dest.latitude);
    final lngTween = Tween<double>(begin: fromLng, end: dest.longitude);
    final zoomTween = Tween<double>(begin: fromZoom, end: zoom);
    final curved = CurvedAnimation(parent: controller, curve: Curves.easeInOutCubic);

    controller.addListener(() {
      _ignoreNextEvent = true;
      final c = LatLng(latTween.evaluate(curved), lngTween.evaluate(curved));
      _map.move(c, zoomTween.evaluate(curved));
      _currentCenter = c;
      _currentZoom = zoomTween.evaluate(curved);
    });

    await controller.forward();
    _ignoreNextEvent = false;
    _currentCenter = dest;
    _currentZoom = zoom;
  }

  // ---------------------------------------------------------------------------
  // Tier transitions
  // ---------------------------------------------------------------------------

  /// Jump straight to [target] tier. Used by the filter-chip row so a
  /// user tapping "Country" from "District" doesn't have to step
  /// through State + Country in sequence.
  Future<void> _jumpToTier(MapTier target) async {
    if (target == _tier) return;
    final user = ref.read(userProfileProvider).valueOrNull;
    if (user == null) return;
    final dest = switch (target) {
      MapTier.world => const LatLng(20, 0),
      MapTier.country => _countryCenter(user.countryCode) ??
          _userHomeCenter(user),
      MapTier.state =>
        _stateCenter(user) ?? _userHomeCenter(user),
      MapTier.city => _userHomeCenter(user),
      MapTier.district => _userHomeCenter(user),
    };
    await _animateCameraTo(
      dest,
      target.targetZoom,
      const Duration(milliseconds: 700),
    );
    if (mounted) setState(() => _tier = target);
  }

  /// User pinch-zoomed/scrolled — snap to nearest tier when their gesture
  /// crosses a threshold halfway between two tiers.
  void _onMapEvent(MapEvent event) {
    if (_ignoreNextEvent) return;
    if (event is! MapEventMoveEnd && event is! MapEventScrollWheelZoom) return;

    final z = _map.camera.zoom;
    _currentCenter = _map.camera.center;
    _currentZoom = z;

    final newTier = _nearestTier(z);
    if (newTier != _tier) {
      setState(() => _tier = newTier);
    }
  }

  MapTier _nearestTier(double zoom) {
    var best = MapTier.world;
    var bestDist = (zoom - MapTier.world.targetZoom).abs();
    for (final t in MapTier.values) {
      final d = (zoom - t.targetZoom).abs();
      if (d < bestDist) {
        best = t;
        bestDist = d;
      }
    }
    return best;
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(userProfileProvider).valueOrNull;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          // Map
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _currentCenter,
              initialZoom: _currentZoom,
              minZoom: 1,
              maxZoom: 12,
              backgroundColor: AppColors.background,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.pinchZoom |
                    InteractiveFlag.drag |
                    InteractiveFlag.doubleTapZoom |
                    InteractiveFlag.scrollWheelZoom,
              ),
              onMapEvent: _onMapEvent,
            ),
            children: [
              // Raster basemap — CartoDB dark_all in dark mode, OSM
              // default in light. Same helper used by the Track live
              // + session detail maps so all three share tile visuals.
              osmTileLayer(context),

              // Polygon overlays layered ON TOP of the tiles at very
              // low opacity so the road / label detail from the
              // basemap still reads through. The current-scope home
              // region uses a stronger tint + solid border so it
              // pops within its parent.
              if (_tier == MapTier.world && _worldCountries.isNotEmpty)
                PolygonLayer(
                  polygons: [
                    for (final c in _worldCountries)
                      for (final ring in c.polygons)
                        Polygon(
                          points: ring,
                          color: _isHomeCountry(user, c)
                              ? AppColors.primary.withValues(alpha: 0.30)
                              : Colors.transparent,
                          borderColor: AppColors.outlineVariant
                              .withValues(alpha: 0.35),
                          borderStrokeWidth: 0.5,
                        ),
                  ],
                ),
              if (_tier != MapTier.world && _countryStates.isNotEmpty)
                PolygonLayer(
                  polygons: [
                    for (final s in _countryStates)
                      for (final ring in s.polygons)
                        Polygon(
                          points: ring,
                          color: _isHomeState(user, s) &&
                                  _tier == MapTier.state
                              ? AppColors.primary.withValues(alpha: 0.22)
                              : Colors.transparent,
                          borderColor: AppColors.primary.withValues(
                              alpha: _tier == MapTier.state ? 0.7 : 0.35),
                          borderStrokeWidth:
                              _tier == MapTier.state ? 1.0 : 0.5,
                        ),
                  ],
                ),

              // District polygons stay visible at state / city /
              // district zoom. `city` isn't a real polygon tier — we
              // use the same district outlines but render them a
              // touch thicker so the region under the camera stays
              // legible over the basemap.
              if ((_tier == MapTier.state ||
                      _tier == MapTier.city ||
                      _tier == MapTier.district) &&
                  _stateDistricts.isNotEmpty)
                PolygonLayer(
                  polygons: [
                    for (final d in _stateDistricts)
                      for (final ring in d.polygons)
                        Polygon(
                          points: ring,
                          color: _isHomeDistrict(user, d) &&
                                  (_tier == MapTier.district ||
                                      _tier == MapTier.city)
                              ? AppColors.primary.withValues(alpha: 0.35)
                              : Colors.transparent,
                          borderColor: _isHomeDistrict(user, d)
                              ? AppColors.primary
                              : AppColors.primary.withValues(alpha: 0.5),
                          borderStrokeWidth:
                              _isHomeDistrict(user, d) ? 1.6 : 0.6,
                        ),
                  ],
                ),

              // Leader marker for the current scope. Renders a small
              // fan of avatars — leader at the top with a crown +
              // ambient glow, top followers arranged in a row below.
              // Positioned at the region centre (home district / state
              // / country centre depending on the tier).
              _LeaderMarkerLayer(
                center: _regionCenterForCurrentTier(user),
                tier: _tier,
              ),

              if (user?.hasHome ?? false)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _userHomeCenter(user!),
                      width: 40,
                      height: 40,
                      child: const _HomePin(),
                    ),
                  ],
                ),
            ],
          ),

          // Top chrome — close + tier label
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: [
                  _GlassIconBtn(
                    icon: Icons.close,
                    onTap: () => context.pop(),
                  ),
                  const Spacer(),
                  _TierBadge(tier: _tier, scopeLabel: _scopeLabel(user)),
                  const Spacer(),
                  _GlassIconBtn(
                    icon: Icons.my_location,
                    onTap: () async {
                      final u = ref.read(userProfileProvider).valueOrNull;
                      if (u == null) return;
                      await _animateCameraTo(_userHomeCenter(u),
                          MapTier.district.targetZoom,
                          const Duration(milliseconds: 700));
                      if (mounted) setState(() => _tier = MapTier.district);
                    },
                  ),
                ],
              ),
            ),
          ),

          // Bottom chrome — 4-way tier filter (District / City / State
          // / Country). Tapping a chip animates to that tier's zoom
          // and refocuses on the matching region centre.
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: _TierFilterBar(
                  current: _tier,
                  onSelect: _jumpToTier,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _scopeLabel(UserModel? user) {
    if (user == null) return _tier.label;
    return switch (_tier) {
      MapTier.world => 'WORLD',
      MapTier.country => (user.countryName ?? user.countryCode ?? 'COUNTRY')
          .toUpperCase(),
      MapTier.state => (user.stateName ?? 'STATE').toUpperCase(),
      MapTier.city =>
        (user.districtName ?? user.stateName ?? 'CITY').toUpperCase(),
      MapTier.district =>
        (user.districtName ?? 'DISTRICT').toUpperCase(),
    };
  }

  /// The lat/lng we point the leader marker at for the current tier.
  /// For District / City the leader clusters over the user's home
  /// district; for State / Country over the region centre.
  LatLng? _regionCenterForCurrentTier(UserModel? user) {
    if (user == null) return null;
    switch (_tier) {
      case MapTier.world:
        return null; // No single-region leader at world zoom.
      case MapTier.country:
        return _countryCenter(user.countryCode) ?? _userHomeCenter(user);
      case MapTier.state:
        return _stateCenter(user) ?? _userHomeCenter(user);
      case MapTier.city:
      case MapTier.district:
        return _userHomeCenter(user);
    }
  }

  bool _isHomeCountry(UserModel? user, GeoRegion region) {
    if (user?.countryCode == null) return false;
    return region.id.toUpperCase() == user!.countryCode!.toUpperCase();
  }

  bool _isHomeState(UserModel? user, GeoRegion region) {
    if (user?.stateName == null) return false;
    return region.name.toLowerCase() == user!.stateName!.toLowerCase();
  }

  bool _isHomeDistrict(UserModel? user, GeoRegion region) {
    if (user?.districtName == null) return false;
    return region.name.toLowerCase() == user!.districtName!.toLowerCase();
  }
}

// =============================================================================
// Pieces
// =============================================================================

class _HomePin extends StatelessWidget {
  const _HomePin();

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.25),
            shape: BoxShape.circle,
          ),
        ),
        Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: AppColors.primary,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.6),
                blurRadius: 12,
                spreadRadius: 2,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _GlassIconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _GlassIconBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            shape: BoxShape.circle,
            border: Border.all(color: AppColors.onSurface.withValues(alpha: 0.12)),
          ),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

class _TierBadge extends StatelessWidget {
  final MapTier tier;
  final String scopeLabel;
  const _TierBadge({required this.tier, required this.scopeLabel});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.onSurface.withValues(alpha: 0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_iconFor(tier), color: AppColors.primary, size: 14),
          const SizedBox(width: 6),
          Text(scopeLabel,
              style: const TextStyle(
                fontFamily: 'Manrope',
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 11,
                letterSpacing: 0.6,
              )),
        ],
      ),
    );
  }

  IconData _iconFor(MapTier t) => switch (t) {
        MapTier.world => Icons.public,
        MapTier.country => Icons.flag,
        MapTier.state => Icons.map,
        MapTier.city => Icons.location_city,
        MapTier.district => Icons.pin_drop,
      };
}

/// Bottom-anchored 4-way filter: District / City / State / Country.
/// The selected chip is filled with brand-primary; the rest are
/// outlined ghost-chips over the map. Sits inside a glass pill so it
/// stays legible over both light-tile and dark-tile basemaps.
class _TierFilterBar extends StatelessWidget {
  final MapTier current;
  final ValueChanged<MapTier> onSelect;
  const _TierFilterBar({required this.current, required this.onSelect});

  static const _tiers = <MapTier>[
    MapTier.district,
    MapTier.city,
    MapTier.state,
    MapTier.country,
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: AppColors.onSurface.withValues(alpha: 0.10),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final t in _tiers)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: _TierChip(
                label: t.label,
                selected: t == current,
                onTap: () => onSelect(t),
              ),
            ),
        ],
      ),
    );
  }
}

class _TierChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _TierChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.primary
                : AppColors.primary.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : AppColors.primary,
              fontFamily: 'Manrope',
              fontWeight: FontWeight.w800,
              fontSize: 11,
              letterSpacing: 0.6,
            ),
          ),
        ),
      ),
    );
  }
}

/// Renders the top-N leaderboard entries for the current scope as a
/// cluster on the map:
///
///   • Leader (rank 1) — bigger 62 dp avatar, brand-primary halo,
///     crown icon perched on top. Anchored just above the region
///     centre.
///   • Followers (ranks 2–5) — 34 dp avatars in a horizontal row
///     under the leader, no crown.
///
/// The whole cluster lives inside a single `Marker` so the fan doesn't
/// spread apart when the user zooms — everything scales with the
/// avatar dp not the map's coordinate space.
class _LeaderMarkerLayer extends ConsumerWidget {
  final LatLng? center;
  final MapTier tier;
  const _LeaderMarkerLayer({required this.center, required this.tier});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // World tier — no meaningful single-scope leader to show.
    if (center == null || tier == MapTier.world) {
      return const SizedBox.shrink();
    }

    // Which leaderboard feeds this tier? City reuses the district
    // list because we don't have a distinct city ranking yet.
    final AsyncValue<List<LeaderboardEntry>> board = switch (tier) {
      MapTier.country => ref.watch(countryLeaderboardProvider),
      MapTier.state => ref.watch(stateLeaderboardProvider),
      MapTier.city => ref.watch(districtLeaderboardProvider),
      MapTier.district => ref.watch(districtLeaderboardProvider),
      MapTier.world => const AsyncValue.data(<LeaderboardEntry>[]),
    };

    final entries = board.valueOrNull ?? const <LeaderboardEntry>[];
    if (entries.isEmpty) return const SizedBox.shrink();

    final leader = entries.first;
    final followers = entries.length > 1
        ? entries.sublist(1, entries.length.clamp(0, 5))
        : const <LeaderboardEntry>[];

    return MarkerLayer(
      markers: [
        Marker(
          point: center!,
          width: 260,
          height: 160,
          alignment: Alignment.center,
          child: _LeaderCluster(leader: leader, followers: followers),
        ),
      ],
    );
  }
}

class _LeaderCluster extends StatelessWidget {
  final LeaderboardEntry leader;
  final List<LeaderboardEntry> followers;
  const _LeaderCluster({required this.leader, required this.followers});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ---- Leader --------------------------------------------
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              MdiIcons.crown,
              color: AppColors.amber,
              size: 26,
              shadows: [
                Shadow(
                  color: AppColors.amber.withValues(alpha: 0.6),
                  blurRadius: 12,
                ),
              ],
            ),
            const SizedBox(height: 2),
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.65),
                    blurRadius: 20,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: FluttermojiAvatar(
                config: leader.avatarConfig,
                imageUrl: leader.avatarURL,
                initials: _initials(leader.friendlyName),
                radius: 28,
                borderColor: Colors.white,
                borderWidth: 2,
              ),
            ),
            const SizedBox(height: 4),
            _NamePill(name: leader.friendlyName, leader: true),
          ],
        ),
        if (followers.isNotEmpty) ...[
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final f in followers)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: FluttermojiAvatar(
                    config: f.avatarConfig,
                    imageUrl: f.avatarURL,
                    initials: _initials(f.friendlyName),
                    radius: 15,
                    borderColor: Colors.white.withValues(alpha: 0.85),
                    borderWidth: 1.5,
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  static String _initials(String name) {
    if (name.trim().isEmpty) return '?';
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name[0].toUpperCase();
  }
}

/// Small dark-glass name pill sitting under an avatar. `leader: true`
/// gives it a brand-primary text colour for the top-ranked user.
class _NamePill extends StatelessWidget {
  final String name;
  final bool leader;
  const _NamePill({required this.name, required this.leader});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 130),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: AppColors.onSurface.withValues(alpha: 0.12),
        ),
      ),
      child: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: leader ? AppColors.primary : Colors.white,
          fontFamily: 'Manrope',
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
