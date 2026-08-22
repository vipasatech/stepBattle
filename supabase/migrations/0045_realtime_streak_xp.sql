-- =============================================================================
-- Migration 0045: Real-time streak & XP credit + new recovery rule
-- =============================================================================
--
-- Prior behavior: `daily_mission` +100 XP and streak advance both waited
-- for the nightly `run_daily_streak_sweep` at 00:05 UTC. Users hitting
-- their goal at 6 PM local didn't see any XP / streak change until the
-- next morning.
--
-- This migration adds a client-triggered path so both credits land the
-- instant `steps >= goal`:
--
--   • profiles.tz_offset_minutes — per-user local timezone (minutes E of
--     UTC). Client pushes on session start via update_tz_offset.
--   • profiles.streak_awarded_for_date — idempotency guard: date the
--     streak was last advanced. Both the RPC and the cron backstop
--     check this before crediting.
--
--   • RPC update_tz_offset(uid, minutes) — client sets its tz.
--   • RPC advance_daily_progress(uid, local_date, current_steps) — atomic
--     streak+1, +100 XP daily_mission, +100 XP streak_milestone on 25-day
--     multiples, clear recovery if in play.
--   • Rewrote evaluate_daily_streak (cron backstop) with:
--       - per-user local yesterday (via tz_offset_minutes)
--       - new 1-of-2 recovery rule (miss both = reset; meet either = survive)
--       - respects the client's streak_awarded_for_date stamp
--
-- The recovery rule differs from the pre-0045 world: previously users
-- had to meet BOTH make-up days to save a streak. New rule: meet
-- EITHER day 1 or day 2 of the recovery window to survive; miss both
-- to reset.
--
-- HOW TO APPLY: Dashboard → SQL Editor → paste → Run. Idempotent.
--
-- NOTE: Migration 0048 later rerouted advance_daily_progress and
-- evaluate_daily_streak through _credit_xp_admin (added in 0047)
-- because the deployed credit_user_xp policy started rejecting the
-- daily_mission / streak_milestone reasons for client callers.
-- Applying 0045 → 0046 → 0047 → 0048 in order arrives at the live state.
-- =============================================================================

-- 1. Schema additions ---------------------------------------------------------
alter table public.profiles
  add column if not exists tz_offset_minutes int,
  add column if not exists streak_awarded_for_date text;

-- Backfill: existing users default to IST (+330 minutes east of UTC).
-- Client will overwrite on next session start via update_tz_offset.
update public.profiles
   set tz_offset_minutes = 330
 where tz_offset_minutes is null;

-- 2. update_tz_offset ---------------------------------------------------------
create or replace function public.update_tz_offset(
  p_user_id        uuid,
  p_offset_minutes int
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or auth.uid() <> p_user_id then
    raise exception 'not_authorized';
  end if;
  if p_offset_minutes < -720 or p_offset_minutes > 840 then
    raise exception 'invalid_offset';
  end if;
  update public.profiles
     set tz_offset_minutes = p_offset_minutes
   where id = p_user_id;
end;
$$;
revoke all on function public.update_tz_offset(uuid, int) from public;
grant execute on function public.update_tz_offset(uuid, int) to authenticated;

-- 3. advance_daily_progress ---------------------------------------------------
-- Client calls this the moment today's step count crosses the goal.
-- Idempotent per (user, local_date) via streak_awarded_for_date.
--
-- Returns a jsonb payload the client uses to drive the tick-up
-- animation on Home + Profile.
create or replace function public.advance_daily_progress(
  p_user_id        uuid,
  p_local_date     text,   -- YYYY-MM-DD in user's local tz
  p_current_steps  int     -- defense-in-depth: must be >= daily_step_goal
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today            date;
  v_profile          public.profiles%rowtype;
  v_est_server_local date;
  v_goal             int;
  v_streak_before    int;
  v_new_streak       int;
  v_recovered        boolean := false;
  v_milestone_xp     int := 0;
  v_daily_xp         int := 0;
begin
  if auth.uid() is null or auth.uid() <> p_user_id then
    raise exception 'not_authorized';
  end if;

  begin
    v_today := p_local_date::date;
  exception when others then
    raise exception 'invalid_date_format';
  end;

  select * into v_profile from public.profiles where id = p_user_id;
  if v_profile.id is null then
    raise exception 'profile_not_found';
  end if;

  -- ±1 day drift check against server-estimated user-local date
  v_est_server_local := (
    (now() at time zone 'utc')
    + make_interval(mins => coalesce(v_profile.tz_offset_minutes, 330))
  )::date;
  if abs(v_today - v_est_server_local) > 1 then
    raise exception 'date_out_of_range';
  end if;

  v_goal := coalesce(v_profile.daily_step_goal, 8000);
  if p_current_steps < v_goal then
    raise exception 'goal_not_met';
  end if;

  -- Idempotency
  if v_profile.streak_awarded_for_date = p_local_date then
    return jsonb_build_object(
      'credited', false,
      'streak',   coalesce(v_profile.current_streak, 0)
    );
  end if;

  v_streak_before := coalesce(v_profile.current_streak, 0);

  -- New recovery rule: any 1 of the 2 recovery days met = streak survives.
  if v_profile.streak_recovery_started_at is not null
     and (v_today = v_profile.streak_recovery_started_at + 1
          or v_today = v_profile.streak_recovery_started_at + 2) then
    v_new_streak := v_streak_before + 1;
    v_recovered  := true;
  else
    v_new_streak := v_streak_before + 1;
  end if;

  -- Streak milestone (+100 XP every 25 days)
  if v_new_streak > 0
     and v_new_streak % 25 = 0
     and v_new_streak > coalesce(v_profile.last_streak_milestone_awarded, 0) then
    perform public.credit_user_xp(
      p_user_id, 100, 'streak_milestone',
      jsonb_build_object('streak_days', v_new_streak, 'source', 'client_realtime')
    );
    v_milestone_xp := 100;
  end if;

  -- Daily-mission XP
  if v_profile.daily_goal_xp_awarded_date is null
     or v_profile.daily_goal_xp_awarded_date <> p_local_date then
    perform public.credit_user_xp(
      p_user_id, 100, 'daily_mission',
      jsonb_build_object('date', p_local_date, 'source', 'client_realtime')
    );
    v_daily_xp := 100;
  end if;

  update public.profiles
     set current_streak                     = v_new_streak,
         longest_streak                     = greatest(coalesce(longest_streak, 0), v_new_streak),
         streak_awarded_for_date            = p_local_date,
         daily_goal_xp_awarded_date         = p_local_date,
         streak_recovery_started_at         = case when v_recovered then null else streak_recovery_started_at end,
         streak_used_recovery_in_current_run = case when v_recovered then false else streak_used_recovery_in_current_run end,
         last_streak_milestone_awarded      = case when v_milestone_xp > 0 then v_new_streak else last_streak_milestone_awarded end
   where id = p_user_id;

  return jsonb_build_object(
    'credited',      true,
    'streak_before', v_streak_before,
    'streak',        v_new_streak,
    'xp_credited',   v_daily_xp + v_milestone_xp,
    'recovered',     v_recovered,
    'milestone',     v_milestone_xp > 0
  );
end;
$$;

revoke all on function public.advance_daily_progress(uuid, text, int) from public;
grant execute on function public.advance_daily_progress(uuid, text, int) to authenticated;

-- 4. evaluate_daily_streak — cron backstop, rewritten for new rule + per-user tz
create or replace function public.evaluate_daily_streak(
  p_user_id    uuid,
  p_today_date date
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile              public.profiles%rowtype;
  v_user_local_today     date;
  v_user_local_yesterday date;
  v_yesterday_steps      int;
  v_goal                 int;
  v_yesterday_met        boolean;
  v_streak_before        int;
  v_new_streak           int;
  v_recovered            boolean;
begin
  select * into v_profile from public.profiles where id = p_user_id;
  if v_profile.id is null then return; end if;
  if v_profile.streak_evaluated_for_date = p_today_date then return; end if;

  v_user_local_today := (
    (now() at time zone 'utc')
    + make_interval(mins => coalesce(v_profile.tz_offset_minutes, 330))
  )::date;
  v_user_local_yesterday := v_user_local_today - 1;

  select coalesce(step_count, 0) into v_yesterday_steps
    from public.step_logs
   where user_id = p_user_id and date = v_user_local_yesterday::text
   limit 1;
  v_yesterday_steps := coalesce(v_yesterday_steps, 0);
  v_goal := coalesce(v_profile.daily_step_goal, 8000);
  v_yesterday_met := v_yesterday_steps >= v_goal;

  if v_yesterday_met then
    -- Backstop MET credit if client didn't already stamp it.
    if v_profile.streak_awarded_for_date is null
       or v_profile.streak_awarded_for_date::date < v_user_local_yesterday then
      v_streak_before := coalesce(v_profile.current_streak, 0);
      v_recovered := false;
      if v_profile.streak_recovery_started_at is not null
         and (v_user_local_yesterday = v_profile.streak_recovery_started_at + 1
              or v_user_local_yesterday = v_profile.streak_recovery_started_at + 2) then
        v_new_streak := v_streak_before + 1;
        v_recovered  := true;
      else
        v_new_streak := v_streak_before + 1;
      end if;

      if v_new_streak > 0
         and v_new_streak % 25 = 0
         and v_new_streak > coalesce(v_profile.last_streak_milestone_awarded, 0) then
        perform public.credit_user_xp(
          p_user_id, 100, 'streak_milestone',
          jsonb_build_object('streak_days', v_new_streak, 'source', 'cron_backstop')
        );
      end if;

      if v_profile.daily_goal_xp_awarded_date is null
         or v_profile.daily_goal_xp_awarded_date <> v_user_local_yesterday::text then
        perform public.credit_user_xp(
          p_user_id, 100, 'daily_mission',
          jsonb_build_object('date', v_user_local_yesterday, 'source', 'cron_backstop')
        );
      end if;

      update public.profiles
         set current_streak                     = v_new_streak,
             longest_streak                     = greatest(coalesce(longest_streak, 0), v_new_streak),
             streak_awarded_for_date            = v_user_local_yesterday::text,
             daily_goal_xp_awarded_date         = v_user_local_yesterday::text,
             streak_recovery_started_at         = case when v_recovered then null else streak_recovery_started_at end,
             streak_used_recovery_in_current_run = case when v_recovered then false else streak_used_recovery_in_current_run end,
             last_streak_milestone_awarded      = case
                                                    when v_new_streak % 25 = 0
                                                         and v_new_streak > coalesce(last_streak_milestone_awarded, 0)
                                                    then v_new_streak
                                                    else last_streak_milestone_awarded
                                                  end
       where id = p_user_id;
    end if;
  else
    -- MISS path
    if coalesce(v_profile.current_streak, 0) = 0 then
      null;
    elsif v_profile.streak_recovery_started_at is null then
      update public.profiles
         set streak_recovery_started_at = v_user_local_yesterday
       where id = p_user_id;
    elsif v_user_local_yesterday = v_profile.streak_recovery_started_at + 2 then
      update public.profiles
         set current_streak                     = 0,
             streak_recovery_started_at         = null,
             streak_used_recovery_in_current_run = false,
             last_streak_milestone_awarded      = 0
       where id = p_user_id;
    end if;
  end if;

  update public.profiles
     set streak_evaluated_for_date = p_today_date
   where id = p_user_id;
end;
$$;

revoke all on function public.evaluate_daily_streak(uuid, date) from public;
grant execute on function public.evaluate_daily_streak(uuid, date) to authenticated;

-- run_daily_streak_sweep and the pg_cron schedule from 0017 already call
-- evaluate_daily_streak(uuid, date) with the right shape — no changes there.
