-- =============================================================================
-- StepBattle — Search + Leaderboard indexes for 50k+ profiles.
--
-- WHY:
--
-- The friend-search box on the Add Friends sheet runs
--
--   SELECT ... FROM profiles WHERE display_name ILIKE 'foo%' LIMIT 15;
--
-- Without a supporting index the planner does a Seq Scan + filter, which
-- costs ~50-150 ms at 50k rows. `ilike` cannot use a plain B-tree index
-- because case-folding happens at query time.
--
-- The leaderboard reads run
--
--   SELECT ... FROM profile_earned_xp
--   WHERE country_code = 'IN'
--   ORDER BY earned_xp DESC LIMIT 100;
--
-- Existing composite indexes from 0001_init (on profiles, keyed by
-- total_xp) already help the planner: for the ~99% of users with zero
-- purchases, `earned_xp = total_xp` and the planner can use the
-- (geo_col, total_xp desc) index directly on the underlying profiles
-- scan even when we query through the view. But global scan (no geo
-- filter) currently sorts the whole table on `earned_xp` — that hurts
-- once the row count crosses ~10k.
--
-- WHAT:
--
-- 1. pg_trgm extension + GIN index on LOWER(display_name).
--    - Supports ILIKE 'foo%' AND ILIKE '%foo%' via the ~~* operator
--      class the planner picks automatically for `column ILIKE literal`.
--    - Prefix search: same order-of-magnitude as a plain B-tree but
--      handles the case-fold cleanly.
--    - Room for future "find users whose name CONTAINS 'foo'" queries
--      without another migration.
--
-- 2. B-tree index on profiles.total_xp DESC — used by the global
--    leaderboard query. Standing in for a true earned_xp index because
--    the view's expression cannot be indexed directly. Accepts a small
--    approximation for the ~1% of users who have purchased XP: their
--    rows sort by total_xp within the index, then the outer view
--    computes earned_xp and re-sorts the top-N in memory. For a top-100
--    board this is trivially fast.
--
-- HOW TO APPLY:
--   Dashboard → SQL Editor → paste this file → Run.
--   Safe to re-run — every CREATE uses IF NOT EXISTS. Runs in-place;
--   CREATE INDEX CONCURRENTLY is not used because Supabase runs each
--   statement in an implicit transaction (which is incompatible with
--   CONCURRENTLY). Downtime: at 50k rows the CREATE INDEX takes
--   < 5 seconds and holds an ACCESS SHARE lock — no table writes are
--   blocked, only DDL.
--
-- ROLLBACK:
--   drop index if exists profiles_display_name_trgm_idx;
--   drop index if exists profiles_total_xp_desc_idx;
--   (Keeps the pg_trgm extension — cheap to leave installed.)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. pg_trgm — trigram matching for ILIKE searches.
-- ---------------------------------------------------------------------------

create extension if not exists pg_trgm;

create index if not exists profiles_display_name_trgm_idx
  on public.profiles
  using gin (lower(display_name) gin_trgm_ops);

-- ---------------------------------------------------------------------------
-- 2. total_xp DESC — global leaderboard sort.
--
-- Composite (country/state/district, total_xp desc) indexes already
-- exist from 0001_init. This adds the un-scoped variant so the World
-- tab's `ORDER BY earned_xp DESC LIMIT N` (which sees no filter) can
-- walk the index instead of sorting the whole table.
-- ---------------------------------------------------------------------------

create index if not exists profiles_total_xp_desc_idx
  on public.profiles (total_xp desc);
