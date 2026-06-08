-- =============================================================================
-- StepBattle — split distance accounting on track_sessions.
--
-- WHY: a hardware pedometer can't tell real walking apart from rhythmic
-- hand-shaking, bus jolts, or treadmill bounce. To keep the headline distance
-- honest without punishing users, we split each session's distance into:
--
--   • distance_meters_verified   — accumulated from GPS-haversine while the
--                                  device was actually moving (gold standard).
--   • distance_meters_estimated  — accumulated from pedometer × stride while
--                                  GPS was lost mid-session OR the session
--                                  was indoor with no GPS (still shown to the
--                                  user, but tagged so the detail screen can
--                                  surface a note).
--
-- We also track:
--
--   • unverified_steps           — steps the pedometer counted while GPS
--                                  fixes confirmed the user was stationary.
--                                  These are NOT added to distance; the detail
--                                  screen surfaces them as "X steps counted
--                                  without confirmed movement".
--
-- `distance_meters` stays as the user-facing total
-- (= verified + estimated). The split exists so the UI can tell the truth.
--
-- HOW TO APPLY:
--   Dashboard → SQL Editor → paste this whole file → Run.
--   Safe to re-run.
-- =============================================================================

alter table public.track_sessions
  add column if not exists distance_meters_verified  double precision not null default 0,
  add column if not exists distance_meters_estimated double precision not null default 0,
  add column if not exists unverified_steps          integer not null default 0;
