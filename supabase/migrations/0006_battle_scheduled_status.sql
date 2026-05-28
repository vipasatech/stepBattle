-- =============================================================================
-- StepBattle — add 'scheduled' to the battles.status enum.
--
-- Why: the user-selectable start_time can be in the future. After all
-- invitees accept, the battle moves to 'scheduled' (not yet counting steps)
-- until start_time arrives — at which point a background sweep flips it
-- to 'active' and snapshots each participant's lifetime baseline.
--
--   pending   — created; waiting for at least one invitee to accept
--   scheduled — all accepted; waiting for start_time (NEW)
--   active    — start_time reached; step counting in progress
--   completed — end_time reached; scores frozen
--   cancelled — aborted before activation
--
-- HOW TO APPLY:
--   Supabase Dashboard → SQL Editor → New query → paste → Run.
-- =============================================================================

-- Drop and re-add the CHECK constraint with the new value.
alter table public.battles
  drop constraint if exists battles_status_check;

alter table public.battles
  add constraint battles_status_check
  check (status in ('pending','scheduled','active','completed','cancelled'));
