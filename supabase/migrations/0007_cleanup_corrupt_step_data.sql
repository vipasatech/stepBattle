-- =============================================================================
-- StepBattle — one-time cleanup of step data corrupted by the native
-- pedometer baseline bug seen in logs/2026-05-26_15-15-42 (and earlier).
--
-- WHAT WAS WRONG:
--   • One or more rows in `step_logs` got written with `step_count`
--     between ~40k and ~85k on days the user actually walked a few
--     hundred steps. Source: a corrupt native pedometer baseline that
--     returned the device's lifetime cumulative count.
--   • `profiles.total_steps_all_time` was incremented by the bogus
--     per-day delta on each sync, so the lifetime counter ended up
--     ~85k instead of a few hundred. Battles snapshotting baselines
--     from this counter would still WORK (current − baseline cancels
--     out the inflation) but the UI shows wrong lifetime numbers.
--   • `profiles.last_step_xp_threshold` may have been pumped to ~40,
--     meaning XP awards for the next ~40 thousand-step thresholds got
--     "already done" — and the user wouldn't receive step XP until
--     they actually walked > the cap.
--
-- WHAT THIS DOES:
--   1. Deletes step_logs rows with step_count > 100_000 (we can't
--      recover the real value; zeroing is safer than guessing).
--   2. Recomputes profiles.total_steps_all_time = SUM(step_count) for
--      that user across remaining step_logs. The aggregator sanity
--      check (lib/services/step_source_aggregator.dart) prevents this
--      from happening again.
--   3. Resets last_step_xp_threshold and daily_goal_xp_awarded_date so
--      today's correct-value syncs can award XP normally.
--
-- WHY THIS IS SAFE:
--   • No active battles currently exist (per latest logs), so dropping
--     the lifetime counter doesn't make any in-flight battle compute
--     negative current_steps.
--   • Completed battles have end_steps_baseline frozen — recalculating
--     lifetime later doesn't affect their final scores.
--
-- HOW TO APPLY:
--   Supabase Dashboard → SQL Editor → New query → paste → Run.
--   Idempotent: re-running it produces the same result.
-- =============================================================================

-- 1. Drop corrupt day rows. Anything beyond 100k steps in a day is the
--    baseline-poisoning failure mode — humans don't walk that much.
delete from public.step_logs
where step_count > 100000;

-- 2. Recompute the lifetime counter from the surviving step_logs rows.
--    Users with no step_logs at all collapse to 0.
update public.profiles p
set total_steps_all_time = coalesce(
  (select sum(step_count)
   from public.step_logs
   where user_id = p.id),
  0
);

-- 3. Reset XP gate fields that may have been bumped by the bogus value.
--    These only track today's progress; the next legitimate sync will
--    rebuild them correctly from `total_steps_all_time`.
update public.profiles
set last_step_xp_threshold = 0
where last_step_xp_threshold > 100;

update public.profiles
set daily_goal_xp_awarded_date = null
where daily_goal_xp_awarded_date is not null;

-- =============================================================================
-- After running, inspect:
--
--   select id, display_name, total_steps_all_time, last_step_xp_threshold
--   from public.profiles
--   where id = '<your uid>';
--
--   select date, step_count
--   from public.step_logs
--   where user_id = '<your uid>'
--   order by date desc
--   limit 14;
-- =============================================================================
