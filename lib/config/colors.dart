import 'dart:ui';

/// Design tokens — "Violet Kinetic" palette.
///
/// Brand identity sits on a vivid violet → deep-violet ramp. The violet
/// works on both dark and light surfaces with minimal adjustment; the
/// surface stack and text tokens flip per [Brightness].
///
/// MIGRATION (Path B):
///
///   The static getters on this class read from a global `_brightness`
///   field, set once per build from `MaterialApp.builder` via
///   [AppColors.updateBrightness]. This means every existing call site
///   like `AppColors.surface` AUTOMATICALLY returns the correct value
///   for the active theme — no per-call-site context edits required.
///
///   Three caveats:
///
///     1. Static getters can't be used in `const` constructors
///        (`const Icon(color: AppColors.primary)` is now invalid because
///        the value is no longer a compile-time constant). Drop the
///        `const` keyword on those widgets.
///     2. The semantic medal colors (gold/silver/bronze) and `success`/
///        `error` shades that should always read the same on any
///        background are still `static const` — they intentionally do
///        NOT flip.
///     3. If you need a brand-only token that flips (`primaryBrand`,
///        `glassGlow`, etc.), prefer `AppPalette.of(context).X` — the
///        ThemeExtension flips via Material's standard mechanism and
///        composes properly with `Theme.lerp`.
abstract final class AppColors {
  AppColors._();

  /// Active brightness. Mutated by [updateBrightness] inside
  /// `MaterialApp.builder` so that every static getter below reflects the
  /// currently-resolved theme.
  static Brightness _brightness = Brightness.dark;

  /// Update the active brightness. Called from `MaterialApp.builder` —
  /// no-op when the value is unchanged. Returning a bool is convenient
  /// for the caller to decide whether to skip an extra rebuild.
  static bool updateBrightness(Brightness b) {
    if (b == _brightness) return false;
    _brightness = b;
    return true;
  }

  static bool get isLight => _brightness == Brightness.light;
  static bool get isDark => _brightness == Brightness.dark;

  static Color _pick(Color dark, Color light) => isDark ? dark : light;

  // ---------------------------------------------------------------------------
  // Surface stack — flips per brightness.
  // ---------------------------------------------------------------------------
  static Color get background => _pick(_darkBackground, _lightBackground);
  static Color get surface => _pick(_darkSurface, _lightSurface);
  static Color get surfaceContainerLowest =>
      _pick(_darkSurfaceContainerLowest, _lightSurfaceContainerLowest);
  static Color get surfaceContainerLow =>
      _pick(_darkSurfaceContainerLow, _lightSurfaceContainerLow);
  static Color get surfaceContainer =>
      _pick(_darkSurfaceContainer, _lightSurfaceContainer);
  static Color get surfaceContainerHigh =>
      _pick(_darkSurfaceContainerHigh, _lightSurfaceContainerHigh);
  static Color get surfaceContainerHighest =>
      _pick(_darkSurfaceContainerHighest, _lightSurfaceContainerHighest);
  static Color get surfaceVariant =>
      _pick(_darkSurfaceVariant, _lightSurfaceVariant);
  static Color get surfaceBright =>
      _pick(_darkSurfaceBright, _lightSurfaceBright);

  // ---------------------------------------------------------------------------
  // Text / on-surface — flips per brightness.
  // ---------------------------------------------------------------------------
  static Color get onSurface => _pick(_darkOnSurface, _lightOnSurface);
  static Color get onSurfaceVariant =>
      _pick(_darkOnSurfaceVariant, _lightOnSurfaceVariant);
  static Color get onBackground =>
      _pick(_darkOnBackground, _lightOnBackground);

  /// Text/icon color sitting on top of `primary` or `primaryBrand`. White
  /// reads cleanly on both violet shades regardless of theme.
  static const onPrimary = Color(0xFFFFFFFF);

  // ---------------------------------------------------------------------------
  // Brand violets — primary flips slightly deeper on light for AA contrast.
  // ---------------------------------------------------------------------------
  static Color get primary => _pick(_darkPrimary, _lightPrimary);
  static Color get primaryBrand => _pick(_darkPrimaryBrand, _lightPrimaryBrand);
  static Color get primaryDim => _pick(_darkPrimaryDim, _lightPrimaryDim);
  static Color get primaryContainer =>
      _pick(_darkPrimaryContainer, _lightPrimaryContainer);
  static Color get secondary => _pick(_darkSecondary, _lightSecondary);
  static Color get secondaryContainer =>
      _pick(_darkSecondaryContainer, _lightSecondaryContainer);
  static Color get tertiary => _pick(_darkTertiary, _lightTertiary);
  static Color get tertiaryContainer =>
      _pick(_darkTertiaryContainer, _lightTertiaryContainer);
  static Color get tertiaryDim => _pick(_darkTertiaryDim, _lightTertiaryDim);
  static const primaryFixedDim = Color(0xFF7C3AED);

  // ---------------------------------------------------------------------------
  // Outlines — flip per brightness.
  // ---------------------------------------------------------------------------
  static Color get outline => _pick(_darkOutline, _lightOutline);
  static Color get outlineVariant =>
      _pick(_darkOutlineVariant, _lightOutlineVariant);

  // ---------------------------------------------------------------------------
  // Inverse — flip per brightness.
  // ---------------------------------------------------------------------------
  static Color get inverseSurface =>
      _pick(_darkInverseSurface, _lightInverseSurface);
  static Color get inversePrimary =>
      _pick(_darkInversePrimary, _lightInversePrimary);

  // ---------------------------------------------------------------------------
  // Glassmorphism — flips per brightness so a frosted card reads on either
  // background.
  // ---------------------------------------------------------------------------
  static Color get glassBackground =>
      _pick(_darkGlassBackground, _lightGlassBackground);
  static Color get glassGlow => _pick(_darkGlassGlow, _lightGlassGlow);

  // ---------------------------------------------------------------------------
  // Semantic — error / success / medal colors stay static const because they
  // read fine on both light and dark surfaces. AMBER is the exception:
  // the dark-mode shade (#FBBC04, vivid Material amber) washes out on white,
  // so it flips to a deeper marigold on light. Callers can still use it in
  // non-const contexts without thinking about brightness.
  // ---------------------------------------------------------------------------
  static const success = Color(0xFF34A853);
  static const error = Color(0xFFFF716C);
  static const errorDim = Color(0xFFD7383B);
  static const errorContainer = Color(0xFF9F0519);

  /// Amber accent — used for streak fire, B/W ratio, "behind by" warnings.
  /// Flips between vivid amber on dark and deeper marigold on light so it
  /// keeps a similar visual weight across themes.
  static Color get amber => _pick(_darkAmber, lightAmber);
  static const _darkAmber = Color(0xFFFBBC04);
  /// Const-safe dark amber for any caller that needs a compile-time
  /// constant (e.g. an icon inside a `const` widget). Most call sites
  /// should use `AppColors.amber` and let it flip.
  static const amberConst = _darkAmber;

  // Leaderboard podium (semantic — same in both themes)
  static const gold = Color(0xFFFFD700);
  static const silver = Color(0xFFC0C0C0);
  static const bronze = Color(0xFFCD7F32);

  // ===========================================================================
  // DARK palette constants — originals.
  // ===========================================================================
  static const darkBackground = _darkBackground;
  static const darkSurface = _darkSurface;
  static const darkSurfaceContainerLowest = _darkSurfaceContainerLowest;
  static const darkSurfaceContainerLow = _darkSurfaceContainerLow;
  static const darkSurfaceContainer = _darkSurfaceContainer;
  static const darkSurfaceContainerHigh = _darkSurfaceContainerHigh;
  static const darkSurfaceContainerHighest = _darkSurfaceContainerHighest;
  static const darkSurfaceVariant = _darkSurfaceVariant;
  static const darkSurfaceBright = _darkSurfaceBright;
  static const darkOnSurface = _darkOnSurface;
  static const darkOnSurfaceVariant = _darkOnSurfaceVariant;
  static const darkOnBackground = _darkOnBackground;
  static const darkOutline = _darkOutline;
  static const darkOutlineVariant = _darkOutlineVariant;
  static const darkInverseSurface = _darkInverseSurface;
  static const darkInversePrimary = _darkInversePrimary;
  static const darkPrimary = _darkPrimary;
  static const darkPrimaryBrand = _darkPrimaryBrand;
  static const darkPrimaryDim = _darkPrimaryDim;
  static const darkPrimaryContainer = _darkPrimaryContainer;
  static const darkSecondary = _darkSecondary;
  static const darkSecondaryContainer = _darkSecondaryContainer;
  static const darkTertiary = _darkTertiary;
  static const darkTertiaryContainer = _darkTertiaryContainer;
  static const darkTertiaryDim = _darkTertiaryDim;
  static const darkGlassBackground = _darkGlassBackground;
  static const darkGlassGlow = _darkGlassGlow;

  static const _darkBackground = Color(0xFF0E0E10);
  static const _darkSurface = Color(0xFF0E0E10);
  static const _darkSurfaceContainerLowest = Color(0xFF000000);
  static const _darkSurfaceContainerLow = Color(0xFF131315);
  static const _darkSurfaceContainer = Color(0xFF19191C);
  static const _darkSurfaceContainerHigh = Color(0xFF1F1F22);
  static const _darkSurfaceContainerHighest = Color(0xFF252528);
  static const _darkSurfaceVariant = Color(0xFF252528);
  static const _darkSurfaceBright = Color(0xFF2C2C2F);
  static const _darkOnSurface = Color(0xFFFEFBFE);
  static const _darkOnSurfaceVariant = Color(0xFFACAAAD);
  static const _darkOnBackground = Color(0xFFFEFBFE);
  static const _darkOutline = Color(0xFF767577);
  static const _darkOutlineVariant = Color(0xFF48474A);
  static const _darkInverseSurface = Color(0xFFFCF8FB);
  static const _darkInversePrimary = Color(0xFF5B21B6);

  static const _darkPrimary = Color(0xFFA855F7);
  static const _darkPrimaryBrand = Color(0xFF7C3AED);
  static const _darkPrimaryDim = Color(0xFF8B5CF6);
  static const _darkPrimaryContainer = Color(0xFF6D28D9);
  static const _darkSecondary = Color(0xFFC084FC);
  static const _darkSecondaryContainer = Color(0xFF4C1D95);
  static const _darkTertiary = Color(0xFFD8B4FE);
  static const _darkTertiaryContainer = Color(0xFFC084FC);
  static const _darkTertiaryDim = Color(0xFFA78BFA);

  static const _darkGlassBackground = Color(0x99252528); // surfaceVariant @ 60%
  static const _darkGlassGlow = Color(0x14A855F7);       // primary @ 8%

  // ===========================================================================
  // LIGHT palette constants — counterparts.
  //
  // Surface ramp goes white → progressively cooler off-whites. Text tokens
  // go to dark ink. Brand violets tilt slightly deeper for AA contrast on
  // white.
  // ===========================================================================
  static const _lightBackground = Color(0xFFFAF8FC);
  static const _lightSurface = Color(0xFFFAF8FC);
  static const _lightSurfaceContainerLowest = Color(0xFFFFFFFF);
  static const _lightSurfaceContainerLow = Color(0xFFF4EFF7);
  static const _lightSurfaceContainer = Color(0xFFEEE8F2);
  static const _lightSurfaceContainerHigh = Color(0xFFE7E1ED);
  static const _lightSurfaceContainerHighest = Color(0xFFE0DAE7);
  static const _lightSurfaceVariant = Color(0xFFE7E1ED);
  static const _lightSurfaceBright = Color(0xFFFFFFFF);
  static const _lightOnSurface = Color(0xFF1B1B1F);
  static const _lightOnSurfaceVariant = Color(0xFF49464E);
  static const _lightOnBackground = Color(0xFF1B1B1F);
  static const _lightOutline = Color(0xFF7A767E);
  static const _lightOutlineVariant = Color(0xFFCBC4D0);
  static const _lightInverseSurface = Color(0xFF19191C);
  static const _lightInversePrimary = Color(0xFFD8B4FE);

  static const _lightPrimary = Color(0xFF7C3AED);
  static const _lightPrimaryBrand = Color(0xFF6D28D9);
  static const _lightPrimaryDim = Color(0xFF8B5CF6);
  static const _lightPrimaryContainer = Color(0xFFEDE4FE);
  static const _lightSecondary = Color(0xFF7C3AED);
  static const _lightSecondaryContainer = Color(0xFFEDE4FE);
  static const _lightTertiary = Color(0xFF7C3AED);
  static const _lightTertiaryContainer = Color(0xFFEDE4FE);
  static const _lightTertiaryDim = Color(0xFFA78BFA);

  static const _lightGlassBackground = Color(0xCCFFFFFF);
  static const _lightGlassGlow = Color(0x147C3AED); // primary @ 8%

  // ===========================================================================
  // Exposed light-mode tokens — kept for the few call sites (AppTheme,
  // AppPalette) that need to bake the light value at construction time
  // rather than reading via the dynamic getter.
  // ===========================================================================
  static const lightBackground = _lightBackground;
  static const lightSurface = _lightSurface;
  static const lightSurfaceContainerLowest = _lightSurfaceContainerLowest;
  static const lightSurfaceContainerLow = _lightSurfaceContainerLow;
  static const lightSurfaceContainer = _lightSurfaceContainer;
  static const lightSurfaceContainerHigh = _lightSurfaceContainerHigh;
  static const lightSurfaceContainerHighest = _lightSurfaceContainerHighest;
  static const lightSurfaceVariant = _lightSurfaceVariant;
  static const lightSurfaceBright = _lightSurfaceBright;
  static const lightOnSurface = _lightOnSurface;
  static const lightOnSurfaceVariant = _lightOnSurfaceVariant;
  static const lightOnBackground = _lightOnBackground;
  static const lightOutline = _lightOutline;
  static const lightOutlineVariant = _lightOutlineVariant;
  static const lightInverseSurface = _lightInverseSurface;
  static const lightInversePrimary = _lightInversePrimary;
  static const lightPrimary = _lightPrimary;
  static const lightPrimaryBrand = _lightPrimaryBrand;
  static const lightPrimaryDim = _lightPrimaryDim;
  static const lightPrimaryContainer = _lightPrimaryContainer;
  static const lightSecondary = _lightSecondary;
  static const lightSecondaryContainer = _lightSecondaryContainer;
  static const lightTertiary = _lightTertiary;
  static const lightTertiaryContainer = _lightTertiaryContainer;
  static const lightTertiaryDim = _lightTertiaryDim;
  static const lightGlassBackground = _lightGlassBackground;
  static const lightGlassGlow = _lightGlassGlow;
  static const lightError = Color(0xFFD7383B);
  static const lightErrorContainer = Color(0xFFFFD9DA);
  static const lightSuccess = Color(0xFF2E8B43);
  static const lightAmber = Color(0xFFD97706);
}
