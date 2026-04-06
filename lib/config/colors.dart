import 'dart:ui';

/// Design tokens from titanium_velocity/DESIGN.md — "Kinetic Competition" system.
abstract final class AppColors {
  // Core palette
  static const background = Color(0xFF0E0E10);
  static const primary = Color(0xFF84ADFF);
  static const primaryBrand = Color(0xFF1A73E8);
  static const tertiary = Color(0xFFFAB0FF);

  // Semantic
  static const success = Color(0xFF34A853);
  static const error = Color(0xFFFF716C);
  static const errorDim = Color(0xFFD7383B);
  static const amber = Color(0xFFFBBC04);

  // Surface hierarchy (The Floor → The Podium → The Spotlight)
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
  static const onPrimary = Color(0xFF002C65);
  static const onBackground = Color(0xFFFEFBFE);

  // Outline
  static const outline = Color(0xFF767577);
  static const outlineVariant = Color(0xFF48474A);

  // Extended palette
  static const secondary = Color(0xFF7E98FF);
  static const secondaryContainer = Color(0xFF1E3DA1);
  static const primaryContainer = Color(0xFF6C9FFF);
  static const primaryDim = Color(0xFF679DFF);
  static const primaryFixedDim = Color(0xFF5091FF);
  static const tertiaryDim = Color(0xFFE48FED);
  static const tertiaryContainer = Color(0xFFF39CFB);
  static const errorContainer = Color(0xFF9F0519);
  static const inverseSurface = Color(0xFFFCF8FB);
  static const inversePrimary = Color(0xFF005BC1);

  // Glassmorphism
  static const glassBackground = Color(0x99252528); // surfaceVariant @ 60%
  static const glassGlow = Color(0x3384ADFF); // primary @ 20%

  // Leaderboard podium
  static const gold = Color(0xFFFFD700);
  static const silver = Color(0xFFC0C0C0);
  static const bronze = Color(0xFFCD7F32);
}
