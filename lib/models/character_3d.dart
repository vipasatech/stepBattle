import 'user_model.dart' show Gender;

/// 3D character avatar the user picks in Profile and sees in the Battle
/// arena. Four Mixamo-rigged, animation-baked characters ship in the APK.
///
/// Assets per character (Blender-converted from Mixamo FBX with 512-px
/// textures + Draco compression, ~2-7 MB per file):
///   `assets/images/3dAvatars/<id>/character.glb` — idle/original pose
///     (shown in the profile picker preview and in the battle arena for
///     any user who is NOT top-ranked)
///   `assets/images/3dAvatars/<id>/Taunt.glb`     — taunt animation
///     (shown in the battle arena for the top-ranked player)
///
/// Persistence: [SupabaseAuthService.updateCharacter3D] writes the id to
/// `profiles.character_3d_id`. Legacy values (`'women'` / `'men'` from the
/// prior 2-character catalog) fall back through [byId] to a default in
/// the new catalog so no user ever sees a broken picker.
class Character3D {
  final String id;
  final String label;

  const Character3D({required this.id, required this.label});

  /// GLB shown in the picker + battle arena for non-top-ranked players.
  String get glbAssetPath => 'assets/images/3dAvatars/$id/character.glb';

  /// GLB with the taunt animation baked in — shown in the battle arena
  /// when the user is #1 on the battle board.
  String get tauntGlbAssetPath => 'assets/images/3dAvatars/$id/Taunt.glb';

  // ── Catalog ──────────────────────────────────────────────────────────────
  static const adam = Character3D(id: 'adam', label: 'Adam');
  static const amy = Character3D(id: 'amy', label: 'Amy');
  static const shannon = Character3D(id: 'shannon', label: 'Shannon');
  static const jackie = Character3D(id: 'jackie', label: 'Jackie');

  /// Full catalog. Order = display order in the picker.
  static const List<Character3D> catalog = [adam, amy, shannon, jackie];

  /// Lookup by id. Unknown ids (including the legacy `'women'` / `'men'`
  /// from the previous catalog) fall back through [defaultForGender] via
  /// a null gender → [amy], so the picker never crashes.
  static Character3D byId(String? id) {
    for (final c in catalog) {
      if (c.id == id) return c;
    }
    return defaultForGender(null);
  }

  /// Gender-based default when the user hasn't explicitly picked yet.
  /// Maps `Gender.man` → [adam]; everything else (woman / non-binary /
  /// prefer-not-to-say / null) → [amy]. Amy is the visually-distinctive
  /// default (bright athletic outfit).
  static Character3D defaultForGender(Gender? gender) => switch (gender) {
        Gender.man => adam,
        _ => amy,
      };
}
