import 'user_model.dart' show Gender, FitnessLevel;

/// Catalog of pickable runner avatars displayed on the battleground.
///
/// Each entry is a bird's-eye-view PNG in `assets/images/avatars/` —
/// generated to match the top-down camera angle of the battleground tile
/// so the runner reads as part of the world rather than a sticker on it.
///
/// The catalog is FIXED at build time. To add a new avatar:
///   1. Drop `avatar_NN.png` into `assets/images/avatars/`.
///   2. Append an [Avatar] entry to [Avatar.catalog] below.
///   3. Bump the picker preview to include it (no code change needed —
///      the picker iterates [Avatar.catalog]).
///
/// Stored on `profiles.battle_avatar_id` (text) — see migration 0019.
/// The `id` field is a stable string ("avatar_01") so future renames /
/// re-orderings of the catalog don't invalidate existing user picks.
class Avatar {
  /// Stable identifier persisted on `profiles.battle_avatar_id`. Matches
  /// the file's basename (without `.png`) so a single string drives both
  /// asset loading and DB storage.
  final String id;

  /// Short human label shown under the thumbnail in the picker. Not user-
  /// editable; just a hint so the picker isn't a wall of similar-looking
  /// runners. Kept generic — we deliberately do NOT advertise race /
  /// gender labels (the visual does that better than a tag).
  final String label;

  const Avatar({required this.id, required this.label});

  /// Asset path used by Flutter's image loader.
  String get assetPath => 'assets/images/avatars/$id.png';

  /// Lookup by id. Returns [defaultAvatar] when the stored id no longer
  /// exists in the catalog (e.g. after a future cleanup) — better to show
  /// a default runner than a crash or a broken-image placeholder.
  static Avatar byId(String? id) {
    if (id == null || id.isEmpty) return defaultAvatar;
    for (final a in catalog) {
      if (a.id == id) return a;
    }
    return defaultAvatar;
  }

  /// Avatar shown when a user hasn't picked one yet. Variation 01 — the
  /// "locked reference" we used to confirm the bird's-eye camera angle.
  static const Avatar defaultAvatar = Avatar(
    id: 'avatar_01',
    label: 'Runner 1',
  );

  /// Pick a personalised default avatar for a user based on their
  /// gender, fitness level, and age. Called when a fresh profile is
  /// finalised so `profiles.battle_avatar_id` gets seeded with a
  /// runner that visually resembles the user instead of everyone
  /// starting on `avatar_01`. The user can still override via the
  /// avatar-picker sheet at any time — this is purely the default.
  ///
  /// Rules (age buckets mirror `GoalFormula._ageFactor`):
  ///
  /// **man**
  /// | age  | beginner | intermediate | advanced | pro       |
  /// |------|----------|--------------|----------|-----------|
  /// | ≤30  | 03       | 05           | 01       | 11        |
  /// | 31-50| 03       | 05           | 07       | 11        |
  /// | 51-65| 09       | 09           | 09       | 09        |
  /// | 66+  | 12       | 12           | 12       | 12        |
  ///
  /// **woman**
  /// | age  | beginner | intermediate | advanced | pro       |
  /// |------|----------|--------------|----------|-----------|
  /// | ≤30  | 10       | 06           | 02       | 02        |
  /// | 31-50| 10       | 08           | 02       | 02        |
  /// | 51-65| 04       | 04           | 04       | 04        |
  /// | 66+  | 04       | 04           | 04       | 04        |
  ///
  /// **nonBinary / preferNotToSay** — age-only mapping (no gendered
  /// body cues):
  /// - ≤50 → avatar_01
  /// - 51-65 → avatar_09
  /// - 66+ → avatar_12
  ///
  /// Missing input (any of gender/fitness/age is null) → [defaultAvatar].
  static Avatar defaultForUser({
    required Gender? gender,
    required FitnessLevel? fitnessLevel,
    required int? ageYears,
  }) {
    if (gender == null || fitnessLevel == null || ageYears == null) {
      return defaultAvatar;
    }

    // Age bucket helper — matches the boundaries used by GoalFormula
    // so both systems agree on "young / adult / mature / senior".
    final ageBucket = ageYears <= 30
        ? _AgeBucket.young
        : ageYears <= 50
            ? _AgeBucket.adult
            : ageYears <= 65
                ? _AgeBucket.mature
                : _AgeBucket.senior;

    final id = switch (gender) {
      Gender.man => _menMap[ageBucket]![fitnessLevel]!,
      Gender.woman => _womenMap[ageBucket]![fitnessLevel]!,
      Gender.nonBinary || Gender.preferNotToSay => switch (ageBucket) {
          _AgeBucket.young || _AgeBucket.adult => 'avatar_01',
          _AgeBucket.mature => 'avatar_09',
          _AgeBucket.senior => 'avatar_12',
        },
    };
    return byId(id);
  }

  // Lookup tables for man / woman defaults. Extracted so the switch
  // above stays readable and additions/tweaks are one-liners.
  static const Map<_AgeBucket, Map<FitnessLevel, String>> _menMap = {
    _AgeBucket.young: {
      FitnessLevel.beginner: 'avatar_03',
      FitnessLevel.intermediate: 'avatar_05',
      FitnessLevel.advanced: 'avatar_01',
      FitnessLevel.pro: 'avatar_11',
    },
    _AgeBucket.adult: {
      FitnessLevel.beginner: 'avatar_03',
      FitnessLevel.intermediate: 'avatar_05',
      FitnessLevel.advanced: 'avatar_07',
      FitnessLevel.pro: 'avatar_11',
    },
    _AgeBucket.mature: {
      FitnessLevel.beginner: 'avatar_09',
      FitnessLevel.intermediate: 'avatar_09',
      FitnessLevel.advanced: 'avatar_09',
      FitnessLevel.pro: 'avatar_09',
    },
    _AgeBucket.senior: {
      FitnessLevel.beginner: 'avatar_12',
      FitnessLevel.intermediate: 'avatar_12',
      FitnessLevel.advanced: 'avatar_12',
      FitnessLevel.pro: 'avatar_12',
    },
  };

  static const Map<_AgeBucket, Map<FitnessLevel, String>> _womenMap = {
    _AgeBucket.young: {
      FitnessLevel.beginner: 'avatar_10',
      FitnessLevel.intermediate: 'avatar_06',
      FitnessLevel.advanced: 'avatar_02',
      FitnessLevel.pro: 'avatar_02',
    },
    _AgeBucket.adult: {
      FitnessLevel.beginner: 'avatar_10',
      FitnessLevel.intermediate: 'avatar_08',
      FitnessLevel.advanced: 'avatar_02',
      FitnessLevel.pro: 'avatar_02',
    },
    _AgeBucket.mature: {
      FitnessLevel.beginner: 'avatar_04',
      FitnessLevel.intermediate: 'avatar_04',
      FitnessLevel.advanced: 'avatar_04',
      FitnessLevel.pro: 'avatar_04',
    },
    _AgeBucket.senior: {
      FitnessLevel.beginner: 'avatar_04',
      FitnessLevel.intermediate: 'avatar_04',
      FitnessLevel.advanced: 'avatar_04',
      FitnessLevel.pro: 'avatar_04',
    },
  };

  /// Full catalog. Order = display order in the picker grid.
  ///
  /// Labels are intentionally generic ("Runner 1", "Runner 2", …) — the
  /// art carries the personality; the label is just a count chip so two
  /// similar avatars are still distinguishable in a screen-reader pass.
  static const List<Avatar> catalog = [
    Avatar(id: 'avatar_01', label: 'Runner 1'),
    Avatar(id: 'avatar_02', label: 'Runner 2'),
    Avatar(id: 'avatar_03', label: 'Runner 3'),
    Avatar(id: 'avatar_04', label: 'Runner 4'),
    Avatar(id: 'avatar_05', label: 'Runner 5'),
    Avatar(id: 'avatar_06', label: 'Runner 6'),
    Avatar(id: 'avatar_07', label: 'Runner 7'),
    Avatar(id: 'avatar_08', label: 'Runner 8'),
    Avatar(id: 'avatar_09', label: 'Runner 9'),
    Avatar(id: 'avatar_10', label: 'Runner 10'),
    Avatar(id: 'avatar_11', label: 'Runner 11'),
    Avatar(id: 'avatar_12', label: 'Runner 12'),
  ];
}

/// Age buckets for the [Avatar.defaultForUser] mapping. Boundaries
/// mirror `GoalFormula._ageFactor` so demographic logic stays
/// consistent across the app.
enum _AgeBucket { young, adult, mature, senior }
