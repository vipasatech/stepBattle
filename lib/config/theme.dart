import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_palette.dart';
import 'colors.dart';
import 'typography.dart';

/// Light + dark [ThemeData] for the app.
///
/// Both themes share the same typography, shape language, and brand
/// violets. The surface stack and text tokens flip per [Brightness];
/// off-scheme tokens (glass, primary-brand, medals) live on the
/// [AppPalette] [ThemeExtension] attached to each theme.
abstract final class AppTheme {
  // ---------------------------------------------------------------------------
  // DARK
  // ---------------------------------------------------------------------------
  static ThemeData get dark => _build(
        brightness: Brightness.dark,
        scaffoldBackground: AppColors.darkBackground,
        scheme: const ColorScheme.dark(
          surface: AppColors.darkSurface,
          primary: AppColors.darkPrimary,
          onPrimary: AppColors.onPrimary,
          secondary: AppColors.darkSecondary,
          secondaryContainer: AppColors.darkSecondaryContainer,
          tertiary: AppColors.darkTertiary,
          tertiaryContainer: AppColors.darkTertiaryContainer,
          error: AppColors.error,
          errorContainer: AppColors.errorContainer,
          onSurface: AppColors.darkOnSurface,
          onSurfaceVariant: AppColors.darkOnSurfaceVariant,
          outline: AppColors.darkOutline,
          outlineVariant: AppColors.darkOutlineVariant,
          surfaceContainerLowest: AppColors.darkSurfaceContainerLowest,
          surfaceContainerLow: AppColors.darkSurfaceContainerLow,
          surfaceContainer: AppColors.darkSurfaceContainer,
          surfaceContainerHigh: AppColors.darkSurfaceContainerHigh,
          surfaceContainerHighest: AppColors.darkSurfaceContainerHighest,
          inverseSurface: AppColors.darkInverseSurface,
          inversePrimary: AppColors.darkInversePrimary,
        ),
        palette: AppPalette.dark,
        primaryBrandForButtons: AppColors.darkPrimaryBrand,
        statusBarStyle: SystemUiOverlayStyle.light,
      );

  // ---------------------------------------------------------------------------
  // LIGHT
  // ---------------------------------------------------------------------------
  static ThemeData get light => _build(
        brightness: Brightness.light,
        scaffoldBackground: AppColors.lightBackground,
        scheme: const ColorScheme.light(
          surface: AppColors.lightSurface,
          primary: AppColors.lightPrimary,
          onPrimary: AppColors.onPrimary, // white on violet — same as dark
          secondary: AppColors.lightSecondary,
          secondaryContainer: AppColors.lightSecondaryContainer,
          tertiary: AppColors.lightTertiary,
          tertiaryContainer: AppColors.lightTertiaryContainer,
          error: AppColors.lightError,
          errorContainer: AppColors.lightErrorContainer,
          onSurface: AppColors.lightOnSurface,
          onSurfaceVariant: AppColors.lightOnSurfaceVariant,
          outline: AppColors.lightOutline,
          outlineVariant: AppColors.lightOutlineVariant,
          surfaceContainerLowest: AppColors.lightSurfaceContainerLowest,
          surfaceContainerLow: AppColors.lightSurfaceContainerLow,
          surfaceContainer: AppColors.lightSurfaceContainer,
          surfaceContainerHigh: AppColors.lightSurfaceContainerHigh,
          surfaceContainerHighest: AppColors.lightSurfaceContainerHighest,
          inverseSurface: AppColors.lightInverseSurface,
          inversePrimary: AppColors.lightInversePrimary,
          primaryContainer: AppColors.lightPrimaryContainer,
        ),
        palette: AppPalette.light,
        primaryBrandForButtons: AppColors.lightPrimaryBrand,
        statusBarStyle: SystemUiOverlayStyle.dark,
      );

  // ---------------------------------------------------------------------------
  // Shared builder — keeps light & dark in lock-step on typography, shape,
  // and component theming. Only colors differ.
  // ---------------------------------------------------------------------------
  static ThemeData _build({
    required Brightness brightness,
    required Color scaffoldBackground,
    required ColorScheme scheme,
    required AppPalette palette,
    required Color primaryBrandForButtons,
    required SystemUiOverlayStyle statusBarStyle,
  }) {
    final isDark = brightness == Brightness.dark;
    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: scaffoldBackground,
      colorScheme: scheme,
      extensions: <ThemeExtension<dynamic>>[palette],

      textTheme: TextTheme(
        displayLarge: AppTypography.displayLarge,
        displayMedium: AppTypography.displayMedium,
        displaySmall: AppTypography.displaySmall,
        headlineLarge: AppTypography.headlineLarge,
        headlineMedium: AppTypography.headlineMedium,
        headlineSmall: AppTypography.headlineSmall,
        titleLarge: AppTypography.titleLarge,
        titleMedium: AppTypography.titleMedium,
        titleSmall: AppTypography.titleSmall,
        bodyLarge: AppTypography.bodyLarge,
        bodyMedium: AppTypography.bodyMedium,
        bodySmall: AppTypography.bodySmall,
        labelLarge: AppTypography.labelLarge,
        labelMedium: AppTypography.labelMedium,
        labelSmall: AppTypography.labelSmall,
      ).apply(
        // Apply on-surface as the default text color so light/dark text
        // flips automatically without every TextStyle hard-coding white.
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      ),

      appBarTheme: AppBarTheme(
        backgroundColor: scaffoldBackground,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: AppTypography.headlineSmall.copyWith(
          color: palette.primaryBrand,
        ),
        iconTheme: IconThemeData(color: scheme.primary),
        systemOverlayStyle: statusBarStyle,
      ),

      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: Colors.transparent,
        elevation: 0,
        selectedItemColor: scheme.primary,
        unselectedItemColor: isDark ? Colors.grey : scheme.onSurfaceVariant,
        type: BottomNavigationBarType.fixed,
        showUnselectedLabels: true,
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainer,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        showDragHandle: false,
      ),

      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        margin: EdgeInsets.zero,
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primaryBrandForButtons,
          foregroundColor: Colors.white,
          shape: const StadiumBorder(),
          padding:
              const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          textStyle: AppTypography.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          side: BorderSide(
              color: scheme.outlineVariant.withValues(alpha: 0.3)),
          shape: const StadiumBorder(),
          padding:
              const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          textStyle: AppTypography.labelLarge,
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color: scheme.primary.withValues(alpha: 0.4),
          ),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        hintStyle: AppTypography.bodyMedium.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),

      dividerTheme: const DividerThemeData(
        color: Colors.transparent,
        thickness: 0,
      ),

      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        labelStyle: AppTypography.labelSmall,
        shape: const StadiumBorder(),
        side: BorderSide.none,
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        contentTextStyle: AppTypography.bodyMedium.copyWith(
          color: scheme.onSurface,
        ),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),

      splashFactory: InkSparkle.splashFactory,
    );
  }
}
