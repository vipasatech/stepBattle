import 'package:flutter/material.dart';

import 'colors.dart';

/// [ThemeExtension] holding tokens that aren't part of Material's
/// [ColorScheme] but still need to flip with the theme — brand-only
/// shades, glassmorphism, leaderboard medals, semantic warm colors.
///
/// Read inside widgets via `AppPalette.of(context).X`. Both light and
/// dark instances are attached to [ThemeData.extensions] by AppTheme.
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  // Brand violet variants beyond what ColorScheme already exposes.
  final Color primaryBrand;
  final Color primaryDim;
  final Color tertiaryDim;

  // Glassmorphism — frosted surface + soft brand glow tint.
  final Color glassBackground;
  final Color glassGlow;

  // Semantic warm tokens (success, error-dim, amber).
  final Color success;
  final Color errorDim;
  final Color amber;

  // Leaderboard medals (semantic, but explicit so callers don't reach for
  // Colors.yellow/grey/brown approximations).
  final Color gold;
  final Color silver;
  final Color bronze;

  const AppPalette({
    required this.primaryBrand,
    required this.primaryDim,
    required this.tertiaryDim,
    required this.glassBackground,
    required this.glassGlow,
    required this.success,
    required this.errorDim,
    required this.amber,
    required this.gold,
    required this.silver,
    required this.bronze,
  });

  /// Dark palette — matches the original `AppColors.*` constants.
  static const dark = AppPalette(
    primaryBrand: AppColors.darkPrimaryBrand,
    primaryDim: AppColors.darkPrimaryDim,
    tertiaryDim: AppColors.darkTertiaryDim,
    glassBackground: AppColors.darkGlassBackground,
    glassGlow: AppColors.darkGlassGlow,
    success: AppColors.success,
    errorDim: AppColors.errorDim,
    amber: AppColors.amberConst,
    gold: AppColors.gold,
    silver: AppColors.silver,
    bronze: AppColors.bronze,
  );

  /// Light palette — deeper violets for AA contrast on white, lighter
  /// glass, slightly darker amber.
  static const light = AppPalette(
    primaryBrand: AppColors.lightPrimaryBrand,
    primaryDim: AppColors.lightPrimaryDim,
    tertiaryDim: AppColors.lightTertiaryDim,
    glassBackground: AppColors.lightGlassBackground,
    glassGlow: AppColors.lightGlassGlow,
    success: AppColors.lightSuccess,
    errorDim: AppColors.error, // Use error red for contrast
    amber: AppColors.lightAmber,
    gold: AppColors.gold,
    silver: AppColors.silver,
    bronze: AppColors.bronze,
  );

  static AppPalette of(BuildContext context) {
    return Theme.of(context).extension<AppPalette>() ?? AppPalette.dark;
  }

  @override
  AppPalette copyWith({
    Color? primaryBrand,
    Color? primaryDim,
    Color? tertiaryDim,
    Color? glassBackground,
    Color? glassGlow,
    Color? success,
    Color? errorDim,
    Color? amber,
    Color? gold,
    Color? silver,
    Color? bronze,
  }) {
    return AppPalette(
      primaryBrand: primaryBrand ?? this.primaryBrand,
      primaryDim: primaryDim ?? this.primaryDim,
      tertiaryDim: tertiaryDim ?? this.tertiaryDim,
      glassBackground: glassBackground ?? this.glassBackground,
      glassGlow: glassGlow ?? this.glassGlow,
      success: success ?? this.success,
      errorDim: errorDim ?? this.errorDim,
      amber: amber ?? this.amber,
      gold: gold ?? this.gold,
      silver: silver ?? this.silver,
      bronze: bronze ?? this.bronze,
    );
  }

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return AppPalette(
      primaryBrand: Color.lerp(primaryBrand, other.primaryBrand, t)!,
      primaryDim: Color.lerp(primaryDim, other.primaryDim, t)!,
      tertiaryDim: Color.lerp(tertiaryDim, other.tertiaryDim, t)!,
      glassBackground:
          Color.lerp(glassBackground, other.glassBackground, t)!,
      glassGlow: Color.lerp(glassGlow, other.glassGlow, t)!,
      success: Color.lerp(success, other.success, t)!,
      errorDim: Color.lerp(errorDim, other.errorDim, t)!,
      amber: Color.lerp(amber, other.amber, t)!,
      gold: Color.lerp(gold, other.gold, t)!,
      silver: Color.lerp(silver, other.silver, t)!,
      bronze: Color.lerp(bronze, other.bronze, t)!,
    );
  }
}
