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
