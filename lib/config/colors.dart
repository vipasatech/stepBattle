import 'dart:ui';

/// Design tokens — "Violet Kinetic" palette.
///
/// Brand identity sits on a vivid violet → deep-violet ramp, on a near-black
/// surface stack. Semantic colors (success/error/amber/gold) are unchanged
/// so leaderboard medals, error banners, and amber nudges still read clearly.
///
/// Glow intensity is deliberately low (`glassGlow` is primary @ 8%, down
/// from 20%) so the dark theme stays calm rather than neon.
abstract final class AppColors {
  // Core palette — violet-first
  static const background = Color(0xFF0E0E10);
  /// Vivid violet. Use for icons, rings, ticks, highlights, link text.
  static const primary = Color(0xFFA855F7);
  /// Deeper violet. Use for solid CTAs, active button fills, brand wordmarks.
  static const primaryBrand = Color(0xFF7C3AED);
  /// Lavender. Secondary accent — e.g., XP / reward badges to differentiate
  /// them from primary brand actions.
  static const tertiary = Color(0xFFD8B4FE);

  // Semantic (unchanged — keep clear color associations across the app)
  static const success = Color(0xFF34A853);
  static const error = Color(0xFFFF716C);
  static const errorDim = Color(0xFFD7383B);
  static const amber = Color(0xFFFBBC04);

  // Surface hierarchy (The Floor → The Podium → The Spotlight) — unchanged
  static const surface = Color(0xFF0E0E10);
  static const surfaceContainerLowest = Color(0xFF000000);
  static const surfaceContainerLow = Color(0xFF131315);
  static const surfaceContainer = Color(0xFF19191C);
  static const surfaceContainerHigh = Color(0xFF1F1F22);
  static const surfaceContainerHighest = Color(0xFF252528);
  static const surfaceVariant = Color(0xFF252528);
  static const surfaceBright = Color(0xFF2C2C2F);

  // Text / On-surface
  static const onSurface = Color(0xFFFEFBFE);
  static const onSurfaceVariant = Color(0xFFACAAAD);
  /// Text/icon color sitting on top of `primary` or `primaryBrand`. White
  /// reads cleanly on both violet shades.
  static const onPrimary = Color(0xFFFFFFFF);
  static const onBackground = Color(0xFFFEFBFE);

  // Outline (unchanged)
  static const outline = Color(0xFF767577);
  static const outlineVariant = Color(0xFF48474A);

  // Extended violet palette
  static const secondary = Color(0xFFC084FC);
  static const secondaryContainer = Color(0xFF4C1D95);
  static const primaryContainer = Color(0xFF6D28D9);
  static const primaryDim = Color(0xFF8B5CF6);
  static const primaryFixedDim = Color(0xFF7C3AED);
  static const tertiaryDim = Color(0xFFA78BFA);
  static const tertiaryContainer = Color(0xFFC084FC);
  static const errorContainer = Color(0xFF9F0519);
  static const inverseSurface = Color(0xFFFCF8FB);
  static const inversePrimary = Color(0xFF5B21B6);

  // Glassmorphism — low-glow per design intent
  static const glassBackground = Color(0x99252528); // surfaceVariant @ 60%
  static const glassGlow = Color(0x14A855F7);       // primary @ 8% (was 20%)

  // Leaderboard podium (unchanged)
  static const gold = Color(0xFFFFD700);
  static const silver = Color(0xFFC0C0C0);
  static const bronze = Color(0xFFCD7F32);
}
