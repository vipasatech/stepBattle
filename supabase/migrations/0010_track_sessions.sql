-- =============================================================================
-- StepBattle — track_sessions table for the "Run / Walk" tracker feature.
--
-- One row per Track session: snapshot baselines at Start, deltas at End. GPS
-- path stored as PostGIS LINESTRING (lazily lights up segment leaderboards /
-- heatmaps later — not queried spatially in v1). Sessions without enough GPS
-- fixes (indoor / permission denied) leave `path` NULL and rely on
-- pedometer-estimated distance.
--
-- HOW TO APPLY:
--   1. Dashboard → Database → Extensions → enable `postgis` (one-time).
--   2. Dashboard → SQL Editor → paste this whole file → Run.
-- =============================================================================

create extension if not exists postgis;

create table if not exists public.track_sessions (
  id                    uuid primary key default gen_random_uuid(),
  user_id               uuid not null references public.profiles(id) on delete cascade,
  started_at            timestamptz not null,
  ended_at              timestamptz,
  duration_seconds      integer not null default 0,
  steps                 integer not null default 0,
  distance_meters       double precision not null default 0,
  calories              integer not null default 0,
  avg_pace_sec_per_km   double precision,
  -- GeoJSON LineString accepted by PostgREST when this is a `geography(LINESTRING, 4326)` column.
  -- NULL when the session was indoor / fully fell back to pedometer-estimated distance.
  path                  geography(LINESTRING, 4326),
  -- Parallel jsonb array of { ts: int (epoch ms), accuracy: double, source: 'gps'|'pedometer' }.
  -- Lets us render dashed polyline segments for fallback portions on the detail screen later.
  point_meta            jsonb,
  -- Source of truth for the distance number: 'gps', 'pedometer', or 'mixed'.
  source                text not null default 'pedometer',
  created_at            timestamptz not null default now()
);

create index if not exists track_sessions_user_started_idx
  on public.track_sessions (user_id, started_at desc);

alter table public.track_sessions enable row level security;

drop policy if exists "track_sessions_own" on public.track_sessions;
create policy "track_sessions_own"
  on public.track_sessions for all
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- =============================================================================
-- Inspect after applying:
--   select count(*) from public.track_sessions where user_id = '<your uid>';
--   select id, started_at, distance_meters, steps, source
--     from public.track_sessions
--     where user_id = '<your uid>' order by started_at desc limit 10;
-- =============================================================================
