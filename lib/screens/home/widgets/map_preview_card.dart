import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../config/colors.dart';
import '../../../models/user_model.dart';
import '../../../providers/user_provider.dart';
import '../../../sheets/set_home_sheet.dart';
import '../../../utils/home_map_snapshot.dart';
import '../../../widgets/coming_soon_sheet.dart';
import '../../../widgets/glass_card.dart';
import '../../../widgets/map_tile_layer.dart';

/// Map preview on Home — "Who's Leading Near You".
///
/// Two states:
///   • Home district set → render a stylized "tap to enter" tile that opens
///     the cinematic full-screen map at /map.
///   • Home district NOT set → "Set home" CTA tile that opens [SetHomeSheet].
///
/// We deliberately don't render an interactive map preview here — the
/// full map screen handles the GeoJSON download + cinematic open. This
/// preview is just an entry point.
class MapPreviewCard extends ConsumerWidget {
  const MapPreviewCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final user = ref.watch(userProfileProvider).valueOrNull;
    final hasHome = user?.hasHome ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          hasHome ? "Who's Leading Near You" : "Set your home",
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 12),

        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () {
              // v1 gate — "Who's Leading Near You" is Coming Soon. The
              // whole card taps into the same fade-out toast as the
              // Clan tab. Falls back to the Set-Home sheet only when
              // the user still needs to set their district (that's an
              // onboarding step, not the Leading-Near-You feature).
              if (hasHome) {
                showComingSoonSheet(context, title: "Who's Leading Near You");
              } else {
                _openSetHomeSheet(context);
              }
            },
            child: GlassCard(
              padding: EdgeInsets.zero,
              borderRadius: 20,
              child: SizedBox(
                height: 180,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Home location pinned → static PNG snapshot
                    // (cached to app documents on first capture). The
                    // background widget renders the live FlutterMap
                    // only ONCE per home location, captures its pixels
                    // via RepaintBoundary, then swaps to Image.file
                    // for every subsequent Home visit. Tap opens the
                    // Coming-Soon sheet, so a static frame is all we
                    // need for the preview.
                    //
                    // No home yet → stylised gradient + dot placeholder
                    // (the same fallback the map background widget
                    // shows during its brief cache-lookup gap).
                    if (hasHome && user?.homeLat != null && user?.homeLng != null)
                      _HomeMapBackground(
                        lat: user!.homeLat!,
                        lng: user.homeLng!,
                      )
                    else
                      const _FallbackGradient(),

                    // Bottom info bar
                    Positioned(
                      bottom: 14,
                      left: 14,
                      right: 14,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceContainerHigh
                              .withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: AppColors.onSurface.withValues(alpha: 0.06),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              hasHome ? Icons.public : Icons.location_off,
                              color: hasHome
                                  ? AppColors.primary
                                  : AppColors.amber,
                              size: 18,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: hasHome
                                  ? _HomeRow(user: user!)
                                  : _UnsetRow(),
                            ),
                            Icon(
                              Icons.chevron_right,
                              color: AppColors.onSurfaceVariant,
                              size: 18,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _openSetHomeSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const SetHomeSheet(),
    );
  }
}

class _HomeRow extends StatelessWidget {
  final UserModel user;
  const _HomeRow({required this.user});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final district = user.districtName ?? '';
    final state = user.stateName ?? '';
    final country = user.countryName ?? '';
    final headline = district.isNotEmpty
        ? district
        : (state.isNotEmpty ? state : country);
    final sub = state.isNotEmpty && district.isNotEmpty
        ? '$state · $country'
        : country;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(headline,
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        Text(sub,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: AppColors.onSurfaceVariant)),
      ],
    );
  }
}

class _UnsetRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Set your home district',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w800)),
        Text('Unlock local leaderboards + the cinematic map',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: AppColors.onSurfaceVariant)),
      ],
    );
  }
}

/// Filled violet circle with a white outer ring — matches the start /
/// end pins on the Track session-detail map so users see the same
/// "you are here" identity across the app.
class _HomePin extends StatelessWidget {
  const _HomePin();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.primary,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
    );
  }
}

class _MapDotsPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.outlineVariant.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;
    const spacing = 30.0;
    for (double x = spacing; x < size.width; x += spacing) {
      for (double y = spacing; y < size.height; y += spacing) {
        canvas.drawCircle(Offset(x, y), 1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Painted stand-in for the map preview when we don't have (yet) a
/// cached PNG of the user's home. Also serves as the "no home set"
/// state background, so both callers get the exact same visual.
/// Cheap — no network, no widget tree beyond a Container + one
/// CustomPaint + a glow dot.
class _FallbackGradient extends StatelessWidget {
  const _FallbackGradient();

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: RadialGradient(
              center: Alignment.center,
              radius: 1.2,
              colors: [
                AppColors.amber.withValues(alpha: 0.12),
                AppColors.surfaceContainerLowest,
              ],
            ),
          ),
        ),
        CustomPaint(painter: _MapDotsPainter()),
        Center(
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: AppColors.amber,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppColors.amber.withValues(alpha: 0.55),
                  blurRadius: 16,
                  spreadRadius: 6,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Map preview background for the "Who's Leading Near You" card.
///
/// Flow:
///   1. On mount, check [HomeMapSnapshot] for a cached PNG at the
///      given lat/lng bucket.
///   2. If a cached file exists → render it via `Image.file`. Zero
///      tile downloads, zero FlutterMap widget cost. This is the
///      steady-state after the first successful capture.
///   3. If nothing is cached → render a live [FlutterMap] wrapped in
///      a `RepaintBoundary`, then after a delay long enough for OSM
///      tiles to land, capture the boundary and persist it. The
///      widget then swaps itself over to `Image.file` for the rest
///      of its lifetime.
///
/// Dependencies on `widget.lat`/`widget.lng` are re-evaluated in
/// [didUpdateWidget] so a user updating their home location kicks
/// off a fresh capture instead of continuing to serve the previous
/// location's PNG.
class _HomeMapBackground extends StatefulWidget {
  final double lat;
  final double lng;

  const _HomeMapBackground({required this.lat, required this.lng});

  @override
  State<_HomeMapBackground> createState() => _HomeMapBackgroundState();
}

class _HomeMapBackgroundState extends State<_HomeMapBackground> {
  /// Anchors the [RepaintBoundary] we capture pixels from. Recreated
  /// whenever we drop back to the live-map path (which shouldn't
  /// normally happen twice per widget lifetime, but keeping the key
  /// stable across state resets is what makes the capture reliable).
  final GlobalKey _boundaryKey = GlobalKey();

  /// The captured PNG on disk. Non-null → we render `Image.file`.
  File? _cached;

  /// True once the async cache-existence check has completed. Before
  /// that we render the same fallback gradient the "no home" branch
  /// uses, so the card doesn't flash blank on very first mount before
  /// the cache resolves.
  bool _checkedCache = false;

  /// Scheduled capture timer. Cancelled on dispose and on lat/lng
  /// change so we never capture a boundary the user has moved past.
  Timer? _captureTimer;

  /// Brightness we last resolved a cache for. Kept in state so a
  /// theme toggle can be detected in [didChangeDependencies] and the
  /// snapshot swapped over without waiting for a lat/lng change. `null`
  /// before the first `didChangeDependencies` fires.
  Brightness? _lastBrightness;

  /// Delay before capturing. Bumped from 2.5 s → 3.5 s because the
  /// earlier value sometimes fired while OSM tiles were still landing,
  /// resulting in PNGs with white gutters where the tile grid hadn't
  /// covered yet. The user sees the live FlutterMap during this
  /// window, so a longer wait is a UX no-op — the map is already on
  /// screen the whole time.
  static const Duration _captureDelay = Duration(milliseconds: 3500);

  /// If a capture fails (network was slow, boundary hadn't painted),
  /// retry once after this longer delay. If it fails again we give
  /// up and re-attempt on the next Home mount — the widget is small
  /// enough that we shouldn't spin here.
  static const Duration _captureRetryDelay = Duration(seconds: 3);

  Brightness get _brightness => Theme.of(context).brightness;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final now = _brightness;
    if (_lastBrightness == now) return;
    _lastBrightness = now;
    // First run (transitions null → light|dark) OR a theme toggle at
    // runtime. Either way, invalidate whatever we had loaded and
    // resolve fresh for the new brightness.
    _captureTimer?.cancel();
    _captureTimer = null;
    _cached = null;
    _checkedCache = false;
    _loadCacheThenMaybeSchedule();
  }

  @override
  void didUpdateWidget(covariant _HomeMapBackground old) {
    super.didUpdateWidget(old);
    // Meaningful move? Cache is keyed by rounded lat/lng, so tiny
    // GPS jitter reuses the existing snapshot; a real home move
    // produces a different filename and needs a fresh capture.
    if (old.lat != widget.lat || old.lng != widget.lng) {
      _captureTimer?.cancel();
      _captureTimer = null;
      setState(() {
        _cached = null;
        _checkedCache = false;
      });
      _loadCacheThenMaybeSchedule();
    }
  }

  Future<void> _loadCacheThenMaybeSchedule() async {
    final b = _lastBrightness ?? _brightness;
    final f = await HomeMapSnapshot.readCached(widget.lat, widget.lng, b);
    if (!mounted) return;
    setState(() {
      _cached = f;
      _checkedCache = true;
    });
    if (f == null) {
      _captureTimer = Timer(_captureDelay, _capture);
    }
  }

  Future<void> _capture() async {
    if (!mounted) return;
    final pixelRatio = MediaQuery.of(context).devicePixelRatio;
    final brightness = _brightness;
    final saved = await HomeMapSnapshot.capture(
      boundaryKey: _boundaryKey,
      lat: widget.lat,
      lng: widget.lng,
      brightness: brightness,
      pixelRatio: pixelRatio,
    );
    if (!mounted) return;
    if (saved != null) {
      // Only accept the capture if the brightness we started with
      // still matches what's on screen — a mid-capture theme toggle
      // would otherwise overwrite the new theme's slot with the old
      // theme's pixels.
      if (brightness == _brightness) {
        setState(() => _cached = saved);
      }
    } else {
      // One retry with a longer delay in case tiles hadn't arrived
      // by the first attempt. After that we give up until next mount.
      _captureTimer = Timer(_captureRetryDelay, () async {
        if (!mounted) return;
        final retryBrightness = _brightness;
        final retry = await HomeMapSnapshot.capture(
          boundaryKey: _boundaryKey,
          lat: widget.lat,
          lng: widget.lng,
          brightness: retryBrightness,
          pixelRatio: pixelRatio,
        );
        if (mounted &&
            retry != null &&
            retryBrightness == _brightness) {
          setState(() => _cached = retry);
        }
      });
    }
  }

  @override
  void dispose() {
    _captureTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_checkedCache) return const _FallbackGradient();

    final cached = _cached;
    if (cached != null) {
      // Backing `Container` with an opaque theme background so any
      // rounding artefacts or aspect-ratio delta between the PNG and
      // the current layout size resolve against a colour that
      // matches the ambient card — never a white flash.
      // `gaplessPlayback` keeps the previous frame visible during a
      // hot-restart-triggered rebuild instead of flashing empty.
      return ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Container(
          color: AppColors.background,
          child: Image.file(
            cached,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          ),
        ),
      );
    }

    // First-time render for this brightness/location: live
    // FlutterMap, wrapped so we can screenshot it. The
    // RepaintBoundary is what `boundary.toImage()` reads pixels from
    // in the capture step. The Container behind the ClipRRect gives
    // the FlutterMap an OPAQUE theme-coloured backdrop so any pixel
    // the OSM tile grid hasn't covered at capture time (edges of the
    // rounded rect, tile-load gaps) is baked as background, not
    // white — the source of the "white gutters" in the earlier
    // snapshots.
    return RepaintBoundary(
      key: _boundaryKey,
      child: Container(
        color: AppColors.background,
        child: IgnorePointer(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: FlutterMap(
              options: MapOptions(
                initialCenter: LatLng(widget.lat, widget.lng),
                initialZoom: 12,
                interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.none,
              ),
            ),
            children: [
              osmTileLayer(context),
              MarkerLayer(
                markers: [
                  Marker(
                    point: LatLng(widget.lat, widget.lng),
                    width: 22,
                    height: 22,
                    child: const _HomePin(),
                  ),
                ],
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}
