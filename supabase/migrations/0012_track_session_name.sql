-- =============================================================================
-- StepBattle — optional name on track_sessions.
--
-- The Track UI lets the user name a session before Start, mid-run, or after
-- saving (from the detail screen). The name is optional but auto-defaulted on
-- save to "Run · Jun 3, 11:12 AM" (built from started_at) if the user leaves
-- it blank — so list rows always display something meaningful. Renaming back
-- to blank auto-defaults the same way.
--
-- HOW TO APPLY:
--   Dashboard → SQL Editor → paste this whole file → Run.
--   Safe to re-run.
-- =============================================================================

alter table public.track_sessions
  add column if not exists name text;
