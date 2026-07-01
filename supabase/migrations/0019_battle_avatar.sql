-- =============================================================================
-- StepBattle — Battle-ground avatar (separate from profile photo).
--
-- The "battle avatar" is one of 12 bird's-eye-view runner illustrations
-- shipped in `assets/images/avatars/`. It's distinct from `avatar_url`
-- (which is the user's profile photo / Google login picture) because the
-- battle avatar must match the top-down camera angle of the arena art
-- and most profile photos don't.
--
-- HOW THE ID IS USED:
--   • Client stores the string id ("avatar_01" … "avatar_12") in
--     `profiles.battle_avatar_id`.
--   • At battle-creation time, BattleService snapshots each participant's
--     current `battle_avatar_id` into `battle_participants.battle_avatar_id`
--     so a later profile change doesn't retroactively swap the avatar in
--     historical battles.
--   • The Flutter side resolves the id → asset path via
--     [Avatar.byId(id).assetPath] — unknown ids fall back to the default.
--
-- DEPENDS ON: nothing (additive columns only).
-- HOW TO APPLY: Dashboard → SQL Editor → paste → Run. Idempotent.
-- =============================================================================

-- 1. profiles — what the user currently has selected. Defaults to
-- 'avatar_01' (the locked reference avatar) so legacy rows have a valid
-- visible runner without forcing every user through the picker.
alter table public.profiles
  add column if not exists battle_avatar_id text not null default 'avatar_01';

-- 2. battle_participants — snapshot of the participant's avatar at the
-- moment they joined this battle. Nullable; legacy rows from before this
-- migration stay null and the client falls back to the user's current
-- profile.battle_avatar_id (and ultimately the default) when null.
alter table public.battle_participants
  add column if not exists battle_avatar_id text;

-- No RLS changes — existing policies on these tables already cover the
-- new columns (UPDATE on profiles is restricted to `auth.uid() = id`,
-- and battle_participants is participant-scoped).
