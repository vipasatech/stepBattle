import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import '../../config/colors.dart';
import '../../models/user_model.dart';
import '../../providers/user_provider.dart';
import '../../services/geo_boundary_loader.dart';

/// The four canonical zoom tiers we snap between.
enum MapTier { world, country, state, district }

/// Named extension so tests can import + exercise the tier transition logic
/// without spinning up the [MapScreen] widget.
extension MapTierX on MapTier {
  /// Target zoom level when snapped to this tier.
  double get targetZoom => switch (this) {
        MapTier.world => 2.0,
        MapTier.country => 4.5,
        MapTier.state => 6.5,
        MapTier.district => 9.5,
      };

  String get label => switch (this) {
        MapTier.world => 'WORLD',
        MapTier.country => 'COUNTRY',
        MapTier.state => 'STATE',
        MapTier.district => 'DISTRICT',
      };

  MapTier? get oneOut => switch (this) {
        MapTier.district => MapTier.state,
        MapTier.state => MapTier.country,
        MapTier.country => MapTier.world,
        MapTier.world => null,
      };

  MapTier? get oneIn => switch (this) {
        MapTier.world => MapTier.country,
        MapTier.country => MapTier.state,
        MapTier.state => MapTier.district,
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
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

  Future<void> _zoomOutOneTier() async {
    final next = _tier.oneOut;
    if (next == null) return;
    final user = ref.read(userProfileProvider).valueOrNull;
    if (user == null) return;

    final dest = switch (next) {
      MapTier.world => const LatLng(20, 0),
      MapTier.country => _countryCenter(user.countryCode) ??
          _userHomeCenter(user),
      MapTier.state =>
        _stateCenter(user) ?? _userHomeCenter(user),
      MapTier.district => _userHomeCenter(user),
    };

    await _animateCameraTo(dest, next.targetZoom,
        const Duration(milliseconds: 700));
    if (mounted) setState(() => _tier = next);
  }

  Future<void> _zoomInOneTier() async {
    final next = _tier.oneIn;
    if (next == null) return;
    final user = ref.read(userProfileProvider).valueOrNull;
    if (user == null) return;

    final dest = switch (next) {
      MapTier.country => _countryCenter(user.countryCode) ??
          _userHomeCenter(user),
      MapTier.state =>
        _stateCenter(user) ?? _userHomeCenter(user),
      MapTier.district => _userHomeCenter(user),
      MapTier.world => const LatLng(20, 0),
    };

    await _animateCameraTo(dest, next.targetZoom,
        const Duration(milliseconds: 700));
    if (mounted) setState(() => _tier = next);
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
    final theme = Theme.of(context);

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
              // No tile layer — pure polygon canvas on dark background.
              if (_tier == MapTier.world && _worldCountries.isNotEmpty)
                PolygonLayer(
                  polygons: [
                    for (final c in _worldCountries)
                      for (final ring in c.polygons)
                        Polygon(
                          points: ring,
                          color: _isHomeCountry(user, c)
                              ? AppColors.primary.withValues(alpha: 0.35)
                              : AppColors.surfaceContainerHigh
                                  .withValues(alpha: 0.7),
                          borderColor: AppColors.outlineVariant
                              .withValues(alpha: 0.4),
                          borderStrokeWidth: 0.5,
                        ),
                  ],
                ),
              if (_tier != MapTier.world && _worldCountries.isNotEmpty)
                PolygonLayer(
                  polygons: [
                    for (final c in _worldCountries)
                      if (!_isHomeCountry(user, c))
                        for (final ring in c.polygons)
                          Polygon(
                            points: ring,
                            color: AppColors.surfaceContainerHigh
                                .withValues(alpha: 0.4),
                            borderColor: AppColors.outlineVariant
                                .withValues(alpha: 0.15),
                            borderStrokeWidth: 0.3,
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
                          color: _isHomeState(user, s)
                              ? AppColors.primary.withValues(alpha: 0.25)
                              : AppColors.primary.withValues(alpha: 0.06),
                          borderColor: AppColors.primary.withValues(alpha: 0.4),
                          borderStrokeWidth: 0.6,
                        ),
                  ],
                ),

              // District polygons only visible at state/district zoom.
              // Renders on top of the state polygons so the home district
              // stands out within the highlighted state outline.
              if ((_tier == MapTier.state || _tier == MapTier.district) &&
                  _stateDistricts.isNotEmpty)
                PolygonLayer(
                  polygons: [
                    for (final d in _stateDistricts)
                      for (final ring in d.polygons)
                        Polygon(
                          points: ring,
                          color: _isHomeDistrict(user, d)
                              ? AppColors.primary.withValues(alpha: 0.5)
                              : AppColors.primary.withValues(alpha: 0.12),
                          borderColor: _isHomeDistrict(user, d)
                              ? AppColors.primary
                              : AppColors.primary.withValues(alpha: 0.6),
                          borderStrokeWidth:
                              _isHomeDistrict(user, d) ? 1.2 : 0.5,
                        ),
                  ],
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

          // Bottom chrome — zoom-step buttons + scope leaderboard preview
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: AppColors.onSurface.withValues(alpha: 0.08),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _ZoomStepButton(
                            icon: Icons.zoom_out,
                            enabled: _tier.oneOut != null,
                            onTap: _zoomOutOneTier,
                          ),
                          const SizedBox(width: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: AppColors.primary.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              _scopeLabel(user),
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: AppColors.primary,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          _ZoomStepButton(
                            icon: Icons.zoom_in,
                            enabled: _tier.oneIn != null,
                            onTap: _zoomInOneTier,
                          ),
                        ],
                      ),
                    ),
                  ],
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
      MapTier.district =>
        (user.districtName ?? 'DISTRICT').toUpperCase(),
    };
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
        MapTier.district => Icons.location_city,
      };
}

class _ZoomStepButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;
  const _ZoomStepButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: enabled
                ? AppColors.primary.withValues(alpha: 0.15)
                : AppColors.onSurface.withValues(alpha: 0.04),
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            size: 18,
            color: enabled
                ? AppColors.primary
                : AppColors.onSurfaceVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }
}
