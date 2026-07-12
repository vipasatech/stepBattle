-- =============================================================================
-- StepBattle — 3D character picker (Stage-1 catalog: female / male).
--
-- Users pick a 3D character in the Home showcase / Profile picker; the
-- selection is stored here so opponents' clients can render the same
-- character on the battle arena.
--
-- HOW THE ID IS USED:
--   • Client stores 'women' or 'men' in profiles.character_3d_id.
--   • flutter_3d_controller loads assets/images/3dAvatars/<id>/runner.glb
--     (bundled in the APK, ~7 MB each).
--   • Null falls back to Character3D.defaultForGender(profile.gender) —
--     Gender.man -> men, everything else -> women. See
--     lib/models/character_3d.dart. Users who never touch the picker get
--     the survey-gender-matching default automatically.
--
-- Unlike battle_avatar_id (see 0019), we deliberately DO NOT snapshot this
-- to battle_participants. Reading the opponent's current selection means
-- their character updates live on your arena view if they change it —
-- that's a feature, not a bug.
--
-- DEPENDS ON: 0016_xp_economy_onboarding.sql (profiles.gender column).
-- HOW TO APPLY: Dashboard -> SQL Editor -> paste -> Run. Idempotent.
-- =============================================================================

alter table public.profiles
  add column if not exists character_3d_id text;

-- No RLS changes — existing profiles policies already cover the new column
-- (UPDATE restricted to auth.uid() = id).
