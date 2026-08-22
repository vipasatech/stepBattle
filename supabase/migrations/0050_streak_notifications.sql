-- =============================================================================
-- Migration 0050 — Streak-at-risk + streak-broken push notifications.
--
-- Adds two "wow, right moment" pushes to the streak lifecycle. Both
-- deliver via the existing pipeline — INSERT on public.notifications
-- fires migration 0009's trigger which calls send-push → FCM.
--
-- 1. streak_at_risk — fires at 7 PM local time on day-2 of recovery
--    IF the user is still below 50% of their daily step goal. Body is
--    personalised: "Your 12-day streak needs 3,200 more steps by
--    midnight. About a 30-min walk."
--
-- 2. streak_broken — fires at 8 AM local time the morning AFTER the
--    streak actually broke. Body carries the prior streak length so
--    the message lands with emotional weight: "Your 24-day streak
--    just paused. Start a new one today — every step counts."
--
-- WHY the timing: 7 PM leaves time to squeeze in a walk before
-- midnight; 8 AM lands right as the user's first look-at-phone
-- moment. Neither timing is arbitrary.
--
-- DEDUP DISCIPLINE:
--   • at-risk: max 1 per user per calendar day (tracked in
--     profiles.streak_at_risk_notif_last_date)
--   • broken:  max 1 per broken streak (tracked in
--     profiles.streak_broken_notif_pending_at, cleared on delivery)
--
-- AUTO-CAPTURE (streak-broken side):
--   Streak breaks happen inside evaluate_daily_streak (migration 0017).
--   Rather than modifying that function, this migration adds a
--   BEFORE-UPDATE trigger on profiles.current_streak that catches
--   ANY code path setting current_streak from >0 to 0 and stamps the
--   tracking columns. Cleaner, race-free, works for future code paths
--   we might add.
--
-- HOW TO APPLY:
--   Dashboard → SQL Editor → paste this file → Run.
--   Verify with the "-- Verify" queries at the bottom.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Profile tracking columns. All nullable — populated only on relevant
-- events, cleared on delivery.
-- -----------------------------------------------------------------------------
alter table public.profiles
  add column if not exists streak_broken_notif_pending_at   timestamptz,
  add column if not exists streak_broken_notif_prior_streak integer,
  add column if not exists streak_at_risk_notif_last_date   date;

-- -----------------------------------------------------------------------------
-- 2. Auto-capture: BEFORE-UPDATE trigger on profiles. When any code path
-- sets current_streak from >0 to 0, stamp the tracking columns so the
-- morning cron can pick this user up. Runs in the SAME transaction as
-- the caller so there's no race window.
-- -----------------------------------------------------------------------------
create or replace function public.profiles_streak_zero_watch()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if TG_OP = 'UPDATE'
     and coalesce(old.current_streak, 0) > 0
     and new.current_streak = 0
     -- Don't re-stamp if a fresh pending is already <2 days old (avoid
     -- churn if evaluate_daily_streak runs multiple times).
     and (old.streak_broken_notif_pending_at is null
          or old.streak_broken_notif_pending_at < now() - interval '2 days') then
    new.streak_broken_notif_pending_at   := now();
    new.streak_broken_notif_prior_streak := old.current_streak;
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_streak_zero_watch_trigger on public.profiles;
create trigger profiles_streak_zero_watch_trigger
  before update on public.profiles
  for each row
  when (old.current_streak is distinct from new.current_streak)
  execute function public.profiles_streak_zero_watch();

-- -----------------------------------------------------------------------------
-- 3. notify_streak_at_risk — hourly cron; fires at user local hour 19,
-- once per calendar day, only when the user is materially behind on
-- their step goal. Recovery-mode users only (streak already at risk).
-- -----------------------------------------------------------------------------
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
    if v_user.last_sent = v_today_local then continue; end if;

    -- Read today's step count for this user.
    select coalesce(step_count, 0) into v_today_steps
      from public.step_logs
     where user_id = v_user.id and date = v_today_local
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

-- -----------------------------------------------------------------------------
-- 4. notify_streak_broken — hourly cron; fires at user local hour 8,
-- for any user whose streak broke since the last delivery. Clears the
-- tracking columns on send so it only fires once per broken streak.
-- Expires pendings older than 2 days so we never send a stale "your
-- streak broke!" from a week ago.
-- -----------------------------------------------------------------------------
create or replace function public.notify_streak_broken()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user record;
  v_local_hour int;
begin
  -- Expire stale pendings (older than 2 days).
  update public.profiles
     set streak_broken_notif_pending_at = null,
         streak_broken_notif_prior_streak = null
   where streak_broken_notif_pending_at is not null
     and streak_broken_notif_pending_at < now() - interval '2 days';

  for v_user in
    select p.id,
           coalesce(p.streak_broken_notif_prior_streak, 1) as prior_streak,
           coalesce(p.tz_offset_minutes, 330) as tz_offset_minutes
      from public.profiles p
     where p.streak_broken_notif_pending_at is not null
       and p.fcm_token is not null and p.fcm_token <> ''
  loop
    v_local_hour := extract(hour from (
      now() + make_interval(mins => v_user.tz_offset_minutes)
    ))::int;
    if v_local_hour <> 8 then continue; end if;

    insert into public.notifications (user_id, type, title, body, data)
    values (
      v_user.id,
      'streak_broken',
      'Your streak paused',
      format(
        'Your %s-day streak just paused. Start a new one today — every step counts.',
        v_user.prior_streak
      ),
      jsonb_build_object('prior_streak', v_user.prior_streak)
    );

    update public.profiles
       set streak_broken_notif_pending_at   = null,
           streak_broken_notif_prior_streak = null
     where id = v_user.id;
  end loop;
end;
$$;

revoke all on function public.notify_streak_broken() from public;
grant execute on function public.notify_streak_broken() to service_role;

-- -----------------------------------------------------------------------------
-- 5. pg_cron schedules — both hourly on the top of the hour. The
-- functions gate on user local hour internally, so hitting each hour
-- catches each timezone's target window (19:00 for at-risk, 08:00 for
-- broken) exactly once per day per user.
--
-- Idempotent: cron.schedule with the SAME jobname replaces the prior
-- schedule (pg_cron 1.5+). If your Supabase is on older pg_cron, the
-- second run will raise "job already exists" — safe to ignore or drop
-- first with cron.unschedule('name').
-- -----------------------------------------------------------------------------
select cron.schedule(
  'notify_streak_at_risk_hourly',
  '0 * * * *',
  $$select public.notify_streak_at_risk();$$
);
select cron.schedule(
  'notify_streak_broken_hourly',
  '0 * * * *',
  $$select public.notify_streak_broken();$$
);

-- =============================================================================
-- Verify (run separately after the file above):
--
--   -- 1. Confirm the two cron jobs are registered + active:
--        select jobid, jobname, schedule, active, command
--          from cron.job
--         where jobname like 'notify_streak_%'
--         order by jobid desc;
--
--   -- 2. Confirm the three tracking columns exist on profiles:
--        select column_name, data_type
--          from information_schema.columns
--         where table_schema = 'public' and table_name = 'profiles'
--           and column_name like 'streak_%_notif%';
--
--   -- 3. Force-test at-risk (simulate: pretend you're at 7 PM local and
--        haven't hit goal). Run against your own uid:
--        update public.profiles
--          set streak_recovery_started_at = current_date - 1,
--              current_streak = 12,
--              streak_at_risk_notif_last_date = null
--         where id = '<your-uid>';
--        select public.notify_streak_at_risk();
--        select body from public.notifications
--         where user_id = '<your-uid>' and type = 'streak_at_risk'
--         order by created_at desc limit 1;
--
--   -- 4. Force-test broken (simulate a break just now).
--        update public.profiles
--          set streak_broken_notif_pending_at   = now() - interval '1 hour',
--              streak_broken_notif_prior_streak = 24
--         where id = '<your-uid>';
--        select public.notify_streak_broken();
--        select body from public.notifications
--         where user_id = '<your-uid>' and type = 'streak_broken'
--         order by created_at desc limit 1;
--
--   -- Cleanup after test:
--        delete from public.notifications
--         where user_id = '<your-uid>'
--           and type in ('streak_at_risk', 'streak_broken')
--           and created_at > now() - interval '5 minutes';
-- =============================================================================
