// =============================================================================
// [3D-DISABLED-2026-08-21]
//
// The 3D character avatar system is temporarily disabled to save ~35 MB of
// AAB size. Every user-facing entry point (the picker sheet) was never
// wired into any screen — the whole feature shipped dead. Preserving the
// code here so we can re-enable it later without re-writing.
//
// TO RE-ENABLE (search `[3D-DISABLED-2026-08-21]` across the whole repo):
//   1. Uncomment the block below.
//   2. Uncomment the three sibling files:
//        lib/providers/character_3d_provider.dart
//        lib/sheets/character_3d_picker_sheet.dart
//        lib/widgets/animated_character_viewer.dart
//   3. Uncomment the field / method blocks in:
//        lib/models/user_model.dart          (character3dId field)
//        lib/services/supabase_auth_service.dart  (updateCharacter3D method)
//        lib/services/media_warmup.dart      (primeWebViewEngine method)
//        lib/screens/battles/battles_screen.dart  (the warmup call)
//   4. Uncomment pubspec.yaml entries:
//        dependencies: flutter_3d_controller + flutter_inappwebview
//        dependency_overrides: flutter_3d_controller path override
//        flutter.assets: the four assets/images/3dAvatars/<name>/ lines
//   5. Restore GLB assets from git history:
//        git checkout <last-commit-before-removal> -- assets/images/3dAvatars/
//   6. Wire a call to `showCharacter3DPickerSheet(context)` from Profile
//      or Settings (nothing calls it today — that's why the feature was
//      dead in the first place).
//   7. `flutter pub get` + rebuild.
//
// DB compatibility: `profiles.character_3d_id` column is preserved via
// migration 0027 and not dropped. Existing users' saved character ids
// stay in the DB while this feature is disabled — they'll come back to
// life on re-enable with no data loss.
// =============================================================================

/*
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
*/
