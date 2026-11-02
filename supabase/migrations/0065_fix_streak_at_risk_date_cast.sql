-- =============================================================================
-- Migration 0065: Fix notify_streak_at_risk — text/date comparison
-- =============================================================================
--
-- SYMPTOM. cron.job_run_details for `notify_streak_at_risk_hourly`:
--
--   ERROR:  operator does not exist: text = date
--   LINE 2:  where user_id = v_user.id and date = v_today_local
--   HINT:   No operator matches the given name and argument types.
--   CONTEXT: PL/pgSQL function notify_streak_at_risk() line 36
--
-- ROOT CAUSE. `public.step_logs.date` is **text** (`yyyy-MM-dd`, local —
-- see migration 0001 line 123), but 0050 declared `v_today_local date`
-- (line 97) and compared the two directly at line 131. Postgres has no
-- implicit text = date operator, so the statement raises 42883.
--
-- WHY IT LOOKED HEALTHY. PL/pgSQL only plans a statement when it
-- actually executes. Line 131 sits inside a loop body guarded by:
--   • `streak_recovery_started_at is not null` and `current_streak > 0`
--     and a non-empty `fcm_token`           (line 111-113)
--   • user's LOCAL hour must be exactly 19  (line 120)
--   • not already notified today            (line 126)
--
-- On any hour where no user cleared all four gates, the loop body never
-- ran, nothing was planned, and the job reported success. That is why
-- the run history shows 159 "succeeded" against only 9 "failed".
--
-- Those 159 successes are NOT 159 working runs — they are 159 no-ops.
-- Every run that had actual work to do failed. Streak-at-risk
-- notifications have NEVER been delivered since 0050 shipped
-- (2026-08-20).
--
-- FIX. Compare on text by formatting the date, rather than casting the
-- column. `date::date = v_today_local` would also type-check, but
-- casting the COLUMN makes the comparison non-sargable and abandons the
-- `unique (user_id, date)` index from 0001 line 128. Formatting the
-- VARIABLE keeps the index usable:
--
--     where user_id = v_user.id
--       and date = to_char(v_today_local, 'YYYY-MM-DD')
--
-- `to_char(date, 'YYYY-MM-DD')` emits zero-padded yyyy-MM-dd, which is
-- exactly the shape the client writes (see StepService step_logs upsert).
--
-- Everything else in the function is unchanged — gates, copy, dedup
-- write, and the 50%-of-goal threshold are all preserved verbatim.
--
-- SIBLING CHECKED, NOT AFFECTED. notify_streak_broken() never touches
-- step_logs (it reads profiles.streak_broken_notif_pending_at only), so
-- its 168/168 successes are genuine. No change needed there.
--
-- HOW TO APPLY: Dashboard → SQL Editor → paste → Run. Idempotent.
-- =============================================================================

create or replace function public.notify_streak_at_risk()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user record;
  v_today_local date;
  v_local_hour  int;
  v_today_steps int;
  v_goal        int;
  v_needed      int;
  v_walk_min    int;
begin
  for v_user in
    select p.id,
           p.current_streak,
           coalesce(p.daily_step_goal, 8000) as daily_step_goal,
           coalesce(p.tz_offset_minutes, 330) as tz_offset_minutes,
           coalesce(p.streak_at_risk_notif_last_date, '2000-01-01'::date) as last_sent
      from public.profiles p
     where p.streak_recovery_started_at is not null
       and p.current_streak > 0
       and p.fcm_token is not null and p.fcm_token <> ''
  loop
    v_local_hour := extract(hour from (
      now() + make_interval(mins => v_user.tz_offset_minutes)
    ))::int;
    -- Fire only at local hour 19 (7 PM). Cron runs hourly so we hit
    -- each timezone's 7 PM window exactly once per day.
    if v_local_hour <> 19 then continue; end if;

    v_today_local := (
      now() + make_interval(mins => v_user.tz_offset_minutes)
    )::date;
    -- Dedup — one at-risk notification per user per local calendar day.
    -- (streak_at_risk_notif_last_date IS a date column, so this
    -- comparison is correctly typed and was never the problem.)
    if v_user.last_sent = v_today_local then continue; end if;

    -- Read today's step count for this user.
    -- CHANGED (0065): step_logs.date is TEXT (yyyy-MM-dd). Format the
    -- variable rather than casting the column, so the
    -- unique (user_id, date) index stays usable.
    select coalesce(step_count, 0) into v_today_steps
      from public.step_logs
     where user_id = v_user.id
       and date = to_char(v_today_local, 'YYYY-MM-DD')
     limit 1;
    v_today_steps := coalesce(v_today_steps, 0);
    v_goal := v_user.daily_step_goal;

    -- Only nudge if user is materially behind — under 50% of goal.
    -- Above that, the natural evening walk is likely enough; no need
    -- to alarm.
    if v_today_steps >= v_goal / 2 then continue; end if;

    v_needed   := greatest(1, v_goal - v_today_steps);
    v_walk_min := greatest(1, v_needed / 100);  -- ~100 steps/min avg pace

    insert into public.notifications (user_id, type, title, body, data)
    values (
      v_user.id,
      'streak_at_risk',
      '🔥 Streak at risk',
      format(
        'Your %s-day streak needs %s more steps by midnight. About a %s-min walk.',
        v_user.current_streak,
        to_char(v_needed, 'FM999,999,999'),
        v_walk_min
      ),
      jsonb_build_object(
        'streak',         v_user.current_streak,
        'daily_goal',     v_goal,
        'today_steps',    v_today_steps,
        'steps_needed',   v_needed,
        'walk_minutes',   v_walk_min
      )
    );

    update public.profiles
       set streak_at_risk_notif_last_date = v_today_local
     where id = v_user.id;
  end loop;
end;
$$;

revoke all on function public.notify_streak_at_risk() from public;
grant execute on function public.notify_streak_at_risk() to service_role;

-- =============================================================================
-- Verification
-- =============================================================================
--
-- 1. The bad comparison is gone and the cast is in place:
--
--   select pg_get_functiondef(oid) like '%to_char(v_today_local%' as fixed
--   from pg_proc
--   where pronamespace = 'public'::regnamespace
--     and proname = 'notify_streak_at_risk';
--
--   Expect: fixed = true.
--
-- 2. Force an immediate run (does not wait for the hourly cron). Safe:
--    the local-hour-19 gate means most runs are still no-ops, but this
--    proves the statement PLANS without the 42883.
--
--   select public.notify_streak_at_risk();
--
--   Expect: completes without error.
--
-- 3. Prove the query itself type-checks against real data:
--
--   select user_id, date, step_count
--   from public.step_logs
--   where date = to_char(current_date, 'YYYY-MM-DD')
--   limit 5;
--
-- 4. After the next few hourly ticks, confirm no new failures:
--
--   select status, count(*), max(start_time)
--   from cron.job_run_details d
--   join cron.job j on j.jobid = d.jobid
--   where j.jobname = 'notify_streak_at_risk_hourly'
--     and d.start_time > now() - interval '1 day'
--   group by status;
--
--   Expect: no 'failed' rows appearing after this migration's timestamp.
--   Note a 'succeeded' row still mostly means "no user hit local 7 PM
--   in that hour" — the real proof is a row landing in
--   public.notifications with type = 'streak_at_risk'.
--
-- =============================================================================
-- Rollback
-- =============================================================================
--
-- Restore 0050's body (re-introduces the bug). No data is modified by
-- this migration, so rollback is non-destructive — but there is no
-- reason to: the current behaviour is a hard error on every run that
-- has work to do.
-- =============================================================================
