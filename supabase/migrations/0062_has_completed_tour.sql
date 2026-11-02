-- =============================================================================
-- Migration 0062 — Server-side "has completed the new-user tour" flag.
--
-- WHY: The 1.1.6+39 new-user tour needs a durable server-side "user has
-- seen and completed the tour" bit so the overlay doesn't re-fire on
-- every install / device switch / cache clear. The client already:
--   • Reads it in `UserModel.hasCompletedTour` (models/user_model.dart:240),
--     defaulting to `true` when the column is absent — so existing
--     production builds don't fire the tour today.
--   • Sync-mirrors it into `CrossIsolateKV.tour_completed_local` in
--     services/tour_service.dart (syncFromServer / markCompleted /
--     resetForReplay), and gates first-fire on both source == not-
--     completed AND local mirror == not-completed
--     (`TourService.shouldFire`).
--   • Writes it via `.update({'has_completed_tour': true})` on skip /
--     finish (services/tour_service.dart lines ~52 + ~77).
-- The current release soft-fails those writes with PGRST204
-- ("has_completed_tour column not found in schema cache") — visible in
-- session logs as `tour:server:markCompletedFailed` — because the
-- column doesn't exist yet. Local mirror still gets set so the tour
-- doesn't re-fire on THIS device, but the flag doesn't sync across
-- devices. This migration ships the column so both sides agree.
--
-- SCHEMA: `profiles.has_completed_tour boolean not null default false`.
--   • `not null` so client reads never surprise us with a nullable —
--     we always know whether the tour was completed.
--   • `default false` so NEW sign-ups after the migration get the tour
--     on their first Home visit.
--
-- BACKFILL (the important part): every EXISTING row is set to `true` in
-- the same migration. Rationale — the client's grandfather default is
-- already `true`, users on today's app are NOT seeing the tour, and
-- setting them to `false` would retro-fire the tour on their next open
-- (unexpected + jarring for people who've been using the app for
-- months). The one-shot `update … set has_completed_tour = true` runs
-- immediately after the `add column` and only touches existing rows;
-- new sign-ups after this point default to `false` per the column
-- default. Result: cutover is invisible to existing users, cleanly
-- fires for new users, one-time only.
--
-- COST: `add column` at `not null default false` still rewrites the
-- column's storage across the profiles table (Postgres 11+ optimises
-- constant defaults but the NOT NULL fill still touches every heap
-- page). At today's row count (< 200 profiles) that's < 50 ms. The
-- follow-up `update … set has_completed_tour = true` is another single
-- pass, similar cost. Whole migration well under 1 s.
--
-- HOW TO APPLY: Dashboard → SQL Editor → paste → Run. Idempotent
-- (uses `add column if not exists` + conditional update).
--
-- ROLLBACK:
--   alter table public.profiles drop column if exists has_completed_tour;
--   (Loses per-user tour-completion history — irreversible.)
-- =============================================================================

-- 1. Add the column.
alter table public.profiles
  add column if not exists has_completed_tour boolean not null default false;

comment on column public.profiles.has_completed_tour is
  'Whether this user has finished (or explicitly skipped) the new-user tour. '
  'Set to true by the client on skip/finish; back to false by the Settings '
  '"Replay app tour" button. Default false; existing users grandfathered '
  'to true in migration 0062 backfill so they do not get retro-fired.';

-- 2. Grandfather every existing profile to "already completed". Runs in
--    the same statement/transaction as the add column so a fresh sign-up
--    between those two steps can't slip through as false. New rows
--    inserted after this migration follow the column default (false)
--    and correctly get the tour.
update public.profiles
   set has_completed_tour = true
 where has_completed_tour = false;
-- Idempotent: re-running finds zero matching rows.

-- =============================================================================
-- Verification queries (run separately after the migration above):
--
--   1. Confirm column exists with the intended shape:
--        select column_name, data_type, is_nullable, column_default
--        from information_schema.columns
--        where table_schema='public'
--          and table_name='profiles'
--          and column_name='has_completed_tour';
--      Expected: has_completed_tour | boolean | NO | false
--
--   2. Confirm every existing profile is grandfathered (backfill worked):
--        select
--          count(*) filter (where has_completed_tour is true)  as completed,
--          count(*) filter (where has_completed_tour is false) as not_completed,
--          count(*)                                            as total
--        from public.profiles;
--      Expected right after apply: completed = total, not_completed = 0.
--
--   3. Roundtrip the write path with your own uid — should succeed now,
--      previously would have raised PGRST204:
--        update public.profiles
--           set has_completed_tour = false
--         where user_id = <your-test-uid>;
--        -- (this would retro-fire the tour on your device on next open)
--        update public.profiles
--           set has_completed_tour = true
--         where user_id = <your-test-uid>;
-- =============================================================================
