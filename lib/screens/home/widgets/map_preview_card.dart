import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../config/colors.dart';
import '../../../providers/user_provider.dart';
import '../../../sheets/set_home_sheet.dart';
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
              if (hasHome) {
                context.push('/map');
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
                    // Background — radial gradient + grid dots
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        gradient: RadialGradient(
                          center: Alignment.center,
                          radius: 1.2,
                          colors: hasHome
                              ? [
                                  AppColors.primary.withValues(alpha: 0.18),
                                  AppColors.surfaceContainerLowest,
                                ]
                              : [
                                  AppColors.amber.withValues(alpha: 0.12),
                                  AppColors.surfaceContainerLowest,
                                ],
                        ),
                      ),
                    ),
                    CustomPaint(painter: _MapDotsPainter()),

                    // Center pin
                    Center(
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: hasHome ? AppColors.primary : AppColors.amber,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: (hasHome
                                      ? AppColors.primary
                                      : AppColors.amber)
                                  .withValues(alpha: 0.55),
                              blurRadius: 16,
                              spreadRadius: 6,
                            ),
                          ],
                        ),
                      ),
                    ),

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
                            color: Colors.white.withValues(alpha: 0.06),
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
  final dynamic user;
  const _HomeRow({required this.user});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final district = user.districtName as String? ?? '';
    final state = user.stateName as String? ?? '';
    final country = user.countryName as String? ?? '';
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
