/// Battleground arena art selection.
///
/// The forest pack was retired — city is now the only shipped pack. The
/// [ArenaPack] enum is kept as an extension point in case future packs
/// (stadium, mountain, night-city, etc.) land later. Time-of-day still
/// picks between morning/afternoon/evening/night lighting variants of
/// the same pack from the device clock at build time.
library;

/// Which scenery the user wants in the battle arena.
///
/// Portrait 1:2 tiles named `morningView.png` / `afternoonView.png` /
/// `eveningView.png` / `nightView.png`, living in a pack-specific
/// subfolder under `assets/images/battleground/`. Tiles stack vertically
/// at render time; the 14% top/bottom crop in `battle_ground_screen.dart`
/// hides the seam that the generator's empty-sidewalk edges would
/// otherwise create.
///
///   • city → `assets/images/battleground/cityView/*.png`
///
/// [forest] is retained as an INTERNAL value — the forest tile art was
/// retired, but `battleground_path.dart` still uses this enum value to
/// select the vertical path routing (`_forestWaypoints`, top→bottom) that
/// the arena's vertical scroll view depends on. Do NOT expose forest as a
/// user-pickable pack; `assetFor` would fail. It's kept solely as a
/// routing constant.
enum ArenaPack {
  city,
  forest;

  /// Returns the asset path for this pack + time-of-day combination.
  /// Only defined for shipped packs (city). [forest] is a routing-only
  /// value and calling this on it throws.
  String assetFor(BattlegroundTimeOfDay tod) {
    final folder = switch (this) {
      ArenaPack.city => 'cityView',
      ArenaPack.forest =>
        throw StateError('forest is a routing-only value; no tile asset'),
    };
    return 'assets/images/battleground/$folder/${tod.name}View.png';
  }

  /// True when this pack is wider than tall. Currently always false —
  /// kept as an extension point in case a future pack ships as landscape.
  bool get isLandscape => false;

  /// Display label for the in-arena chooser (if / when we ship one).
  String get label => switch (this) {
        ArenaPack.city => 'City',
        ArenaPack.forest => 'Forest',
      };

  /// Parse the persisted preference key. Legacy `'forest'` values (from
  /// pre-0027 builds) transparently migrate to [ArenaPack.city] on next
  /// read — the enum value is preserved for path routing, but the user's
  /// arena preference is city.
  static ArenaPack fromKey(String? key) => switch (key) {
        _ => ArenaPack.city,
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
