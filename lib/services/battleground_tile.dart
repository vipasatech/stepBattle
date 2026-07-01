/// Battleground arena art selection — two orthogonal axes:
///
///   1. [ArenaPack]      — which scenery (forest vs. city). User preference,
///                          persisted to Hive. Forest is vertical/portrait
///                          (1:2); city is horizontal/landscape (2:1).
///   2. [BattlegroundTimeOfDay] — picked from the device clock at build time.
///                          Same composition, four lighting variants.
///
/// Combining the two yields the concrete asset path via [ArenaPack.assetFor].
library;

/// Which scenery the user wants in the battle arena.
///
///   • forest — portrait tiles in `assets/images/battleground/`, 1024×2048.
///     Multiple copies stack vertically because the path is designed to
///     loop top↔bottom.
///   • city   — landscape WebPs in `assets/images/horizontalBg/`, 2048×1024.
///     A single tile is enough; the screen flips to landscape and pans
///     left↔right.
enum ArenaPack {
  forest,
  city;

  /// Returns the asset path for this pack + time-of-day combination.
  String assetFor(BattlegroundTimeOfDay tod) {
    switch (this) {
      case ArenaPack.forest:
        return 'assets/images/battleground/${tod.name}Version.png';
      case ArenaPack.city:
        return 'assets/images/horizontalBg/${tod.name}Version.webp';
    }
  }

  /// True when this pack is wider than tall (city). The arena screen uses
  /// this to flip orientation and switch between vertical-stack and
  /// horizontal-pan layouts.
  bool get isLandscape => this == ArenaPack.city;

  /// Display label for the in-arena chooser.
  String get label => switch (this) {
        ArenaPack.forest => 'Forest',
        ArenaPack.city => 'City',
      };

  static ArenaPack fromKey(String? key) => switch (key) {
        'city' => ArenaPack.city,
        _ => ArenaPack.forest,
      };
}

/// Time-of-day selection for the battleground tile background.
///
/// We ship four tiles per pack — morning, afternoon, evening, night — with
/// the same composition and different lighting. The right one is picked
/// from the user's local clock at the moment the screen builds. There's no
/// animated cross-fade; the user just sees whichever matches the wall time
/// when they enter the battle.
///
/// Boundaries (local time, 24h):
///   • 05:00 – 11:59  → morning
///   • 12:00 – 16:59  → afternoon
///   • 17:00 – 19:59  → evening
///   • 20:00 – 04:59  → night
///
/// The "night" bucket wraps midnight, so it covers both the late-evening
/// and pre-dawn slots.
enum BattlegroundTimeOfDay {
  morning,
  afternoon,
  evening,
  night;

  /// Pick the bucket for the given local hour (0-23). Pure function so it's
  /// trivially testable without freezing the clock.
  static BattlegroundTimeOfDay forHour(int hour) {
    if (hour >= 5 && hour < 12) return BattlegroundTimeOfDay.morning;
    if (hour >= 12 && hour < 17) return BattlegroundTimeOfDay.afternoon;
    if (hour >= 17 && hour < 20) return BattlegroundTimeOfDay.evening;
    return BattlegroundTimeOfDay.night;
  }

  /// Pick the bucket from the current device wall clock.
  static BattlegroundTimeOfDay forNow() => forHour(DateTime.now().hour);
}
