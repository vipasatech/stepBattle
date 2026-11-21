
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config/colors.dart';
import '../../../models/user_model.dart';
import '../../../providers/user_provider.dart';
import '../../../sheets/set_home_sheet.dart';
import '../../../widgets/coming_soon_sheet.dart';
import '../../../widgets/glass_card.dart';

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
                            // Change-home affordance — only visible when a
                            // home is already set. Own tap target with
                            // HitTestBehavior.opaque so a tap here opens
                            // the SetHomeSheet instead of bubbling to the
                            // parent card's Coming-Soon handler. When
                            // hasHome is false, the whole card already
                            // opens the sheet (see InkWell onTap above),
                            // so the pencil would be redundant.
                            if (hasHome) ...[
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _openSetHomeSheet(context),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 4,
                                  ),
                                  child: Icon(
                                    Icons.edit_outlined,
                                    color: AppColors.onSurfaceVariant,
                                    size: 16,
                                    semanticLabel: 'Change home location',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 2),
                            ],
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

/// Decorative backdrop for the "Who's Leading Near You" card.
///
/// This was a live [FlutterMap] behind a PNG snapshot cache: fetch tiles,
/// screenshot the boundary once they had landed, then serve that image for
/// the rest of the widget's life. All of it existed to make a real map
/// cheap enough to sit on Home permanently.
///
/// Replaced 2026-11-21 by a drawn texture. The card never needed a real
/// map — it is a pin over your home city beside a leaderboard, and nobody
/// reads a street off it. Meanwhile the tile dependency had started to
/// cost: CARTO now requires an API key for raster basemaps and stamps
/// unkeyed tiles with "API KEY REQUIRED", which is what shipped in
/// 1.1.7+44. Drawing it removes the network request, the API key, the
/// monthly tile quota, the attribution obligation and the snapshot cache
/// in one move.
///
/// `HomeMapSnapshot` had no other caller and is now unused — safe to
/// delete whenever someone is tidying.
class _HomeMapBackground extends StatelessWidget {
  final double lat;
  final double lng;

  const _HomeMapBackground({required this.lat, required this.lng});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Container(
        color: AppColors.background,
        child: _DrawnMapBackdrop(lat: lat, lng: lng),
      ),
    );
  }
}


/// Abstract city-like texture standing in for a map.
///
/// Deterministic: the street layout is seeded from latitude and longitude,
/// so one home location always draws the same thing (no shimmer between
/// rebuilds) while two different cities look different from each other.
class _DrawnMapBackdrop extends StatelessWidget {
  const _DrawnMapBackdrop({required this.lat, required this.lng});

  final double lat;
  final double lng;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _MapTexturePainter(
        seed: ((lat * 1000).round() * 31 + (lng * 1000).round()) & 0x7fffffff,
        isDark: Theme.of(context).brightness == Brightness.dark,
      ),
      child: const Center(child: _HomePin()),
    );
  }
}

class _MapTexturePainter extends CustomPainter {
  _MapTexturePainter({required this.seed, required this.isDark});

  final int seed;
  final bool isDark;

  /// Tiny LCG. `dart:math`'s Random would do, but an explicit one makes
  /// it obvious the output is a pure function of [seed] — the whole point
  /// of this painter is that it never changes between frames.
  static int _next(int s) => (s * 1103515245 + 12345) & 0x7fffffff;

  @override
  void paint(Canvas canvas, Size size) {
    final base = isDark
        ? AppColors.surfaceContainerHigh
        : AppColors.surfaceContainerHigh;
    canvas.drawRect(Offset.zero & size, Paint()..color = base);

    final line = Paint()
      ..style = PaintingStyle.stroke
      ..color = AppColors.onSurfaceVariant.withValues(alpha: 0.10)
      ..strokeWidth = 1;

    // Minor grid — the suggestion of a street network.
    const gap = 26.0;
    for (double x = gap; x < size.width; x += gap) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    for (double y = gap; y < size.height; y += gap) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }

    // A few arterial roads, angled off the grid so it doesn't read as
    // graph paper. Positions come from the seed.
    final road = Paint()
      ..style = PaintingStyle.stroke
      ..color = AppColors.onSurfaceVariant.withValues(alpha: 0.18)
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    var s = _next(seed);
    for (var i = 0; i < 3; i++) {
      final startY = (s % 1000) / 1000 * size.height;
      s = _next(s);
      final endY = (s % 1000) / 1000 * size.height;
      s = _next(s);
      canvas.drawLine(Offset(-10, startY), Offset(size.width + 10, endY), road);
    }

    // One soft blob, reading as a park or water.
    final blobX = (s % 1000) / 1000 * size.width;
    s = _next(s);
    final blobY = (s % 1000) / 1000 * size.height;
    canvas.drawCircle(
      Offset(blobX, blobY),
      size.shortestSide * 0.22,
      Paint()..color = AppColors.primary.withValues(alpha: 0.07),
    );

    // Vignette so the pin sits on a slightly darker centre and the edges
    // fall away into the card.
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.transparent,
            AppColors.background.withValues(alpha: 0.55),
          ],
          stops: const [0.55, 1.0],
        ).createShader(Offset.zero & size),
    );
  }

  @override
  bool shouldRepaint(covariant _MapTexturePainter old) =>
      old.seed != seed || old.isDark != isDark;
}
