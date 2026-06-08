-- =============================================================================
-- StepBattle — switch track_sessions.path from PostGIS geography(LINESTRING,
-- 4326) to plain jsonb.
--
-- WHY: PostgREST does not auto-convert a JSON LineString to a PostGIS
-- geography column on insert (it serialises the object as text, and PostGIS
-- can't parse "{" as WKT). Every Track session save was failing with
--   `parse error - invalid geometry`
-- jsonb works trivially. We lose spatial query support (segment
-- leaderboards, heatmaps) — those are Phase 2 anyway and can be lit up by a
-- later migration that converts the column to geography via
-- ST_GeomFromGeoJSON over the existing rows.
--
-- HOW TO APPLY:
--   Dashboard → SQL Editor → paste this whole file → Run.
--   Safe to re-run.
-- =============================================================================

-- Drop the old PostGIS column. The table is essentially empty (every prior
-- insert failed) so we don't lose anything user-visible. `if exists` guards
-- re-runs after the column is already gone.
alter table public.track_sessions drop column if exists path;

-- Re-add as plain jsonb. Holds a GeoJSON LineString like
--   {"type":"LineString","coordinates":[[lng,lat],[lng,lat],...]}
-- when the session had >=2 GPS fixes, or NULL for indoor/pedometer-only.
alter table public.track_sessions add column if not exists path jsonb;
