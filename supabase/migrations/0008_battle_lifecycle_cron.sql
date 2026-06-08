-- =============================================================================
-- StepBattle — server-side battle lifecycle (activation + completion)
--
-- Also handles a PRE-END WAKE-UP: ~2 min before a battle ends it sends each
-- participant a silent (data-only) FCM push so their device uploads fresh steps
-- before the freeze, and completion runs on a 90s grace delay so that late sync
-- has time to land. Requires push to be configured (migration 0009 + the
-- send-push Edge Function with silent support); if not, wake pings are skipped
-- and completion still works (just from whatever was last synced).
--
-- WHY THIS EXISTS:
--   Battle activation and completion used to run ONLY when a participant
--   opened the app (lib/screens/shell/main_shell.dart → activateScheduledBattles
--   / completeExpiredBattles). If both players kept the app terminated for the
--   whole battle, the battle never completed, no winner was picked, and no XP
--   was awarded until someone happened to launch the app.
--
--   This migration moves that logic onto the database so it runs on a schedule
--   regardless of whether any app is open, backgrounded, terminated, or the
--   phone is off. It is a faithful port of:
--     • BattleService.activateScheduledBattles / _activateBattle
--     • BattleService.completeExpiredBattles / _propagateBattleWinToMissions
--     • XPService.awardXP  (incl. level recompute + xp_earned_today rollover)
--
-- WHAT IT CANNOT DO:
--   It can only freeze whatever step data has already been synced into
--   `profiles.total_steps_all_time`. The phone's pedometer can only be read by
--   the device, so the client still has to push step data up (foreground, the
--   foreground service, or the WorkManager periodic task). This job guarantees
--   the battle RESOLVES on time; client background sync keeps the numbers fresh.
--
-- IDEMPOTENT / SAFE TO RE-RUN:
--   Every object uses CREATE OR REPLACE; the cron job is unscheduled before
--   being re-created.
--
-- TIMEZONE CAVEAT:
--   award_xp() stamps xp_earned_today_date and the weekly mission period_start
--   in UTC, whereas the Dart client uses the device's LOCAL date. At day/week
--   boundaries this can disagree with the client by a few hours. For the MVP
--   this is acceptable (xp_earned_today is cosmetic; battle-win missions are
--   low-volume). To make it exact later, store the user's tz/offset on
--   `profiles` and compute local dates here.
--
-- HOW TO APPLY:
--   1. Dashboard → Database → Extensions → enable `pg_cron` (one-time).
--   2. Dashboard → SQL Editor → paste this whole file → Run.
-- =============================================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;   -- pre-end "sync now" wake pushes

-- Tracks whether the pre-end silent wake push has been sent for a battle, so
-- it's sent at most once per battle.
alter table public.battles
  add column if not exists wake_ping_sent boolean not null default false;

-- -----------------------------------------------------------------------------
-- level_for_xp(xp) — mirror of AppConstants.levelThresholds (lib/config/constants.dart)
-- -----------------------------------------------------------------------------
create or replace function public.level_for_xp(p_xp integer)
returns integer
language sql
immutable
as $$
  select case
    when p_xp >= 75000 then 20
    when p_xp >= 70000 then 19
    when p_xp >= 60000 then 18
    when p_xp >= 50000 then 17
    when p_xp >= 40000 then 16
    when p_xp >= 35000 then 15
    when p_xp >= 32500 then 14
    when p_xp >= 30000 then 13
    when p_xp >= 25000 then 12
    when p_xp >= 20000 then 11
    when p_xp >= 15000 then 10
    when p_xp >= 11000 then 9
    when p_xp >= 8000  then 8
    when p_xp >= 6000  then 7
    when p_xp >= 4500  then 6
    when p_xp >= 3000  then 5
    when p_xp >= 2000  then 4
    when p_xp >= 1200  then 3
    when p_xp >= 500   then 2
    else 1
  end;
$$;

-- -----------------------------------------------------------------------------
-- award_xp(user, amount) — mirror of XPService.awardXP. Adds XP, recomputes
-- level, and rolls over the "xp earned today" counter. No-op for amount <= 0.
-- -----------------------------------------------------------------------------
create or replace function public.award_xp(p_user uuid, p_amount integer)
returns void
language plpgsql
as $$
declare
  v_today text := to_char(now() at time zone 'utc', 'YYYY-MM-DD');
begin
  if p_amount is null or p_amount <= 0 then
    return;
  end if;

  update public.profiles
  set total_xp = total_xp + p_amount,
      level    = public.level_for_xp(total_xp + p_amount),
      xp_earned_today = case
        when xp_earned_today_date = v_today then xp_earned_today + p_amount
        else p_amount
      end,
      xp_earned_today_date = v_today
  where id = p_user;
end;
$$;

-- -----------------------------------------------------------------------------
-- process_battle_lifecycle() — the scheduled worker.
--   A. scheduled → active when start_time arrives (snapshot baselines).
--   B. active → completed when end_time passes (freeze, pick winner, award).
-- Runs as the job owner (postgres) so it bypasses RLS for cross-user writes.
-- -----------------------------------------------------------------------------
create or replace function public.process_battle_lifecycle()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  b        record;
  p        record;
  m        record;
  v_winner uuid;
  v_top    integer;
  v_tie    boolean;
  v_prior  integer;
  v_was    boolean;
  v_new    integer;
  v_done   boolean;
  v_period text;
  v_push_url    text;
  v_push_secret text;
  v_today  text := to_char(now() at time zone 'utc', 'YYYY-MM-DD');
  v_week   text := to_char(
                     (now() at time zone 'utc')::date
                     - (extract(isodow from now() at time zone 'utc')::int - 1),
                     'YYYY-MM-DD');
begin
  -- Single-writer guard. A transaction-level advisory lock means that if a
  -- prior run is still in flight (or anything else calls this), this run exits
  -- immediately instead of double-processing a battle (double XP / duplicate
  -- notifications). Released automatically when this transaction ends.
  if not pg_try_advisory_xact_lock(424242) then
    return;
  end if;

  -- Push config (best-effort; null → push not configured, wake pings skipped).
  begin
    select decrypted_secret into v_push_url
      from vault.decrypted_secrets where name = 'push_function_url';
    select decrypted_secret into v_push_secret
      from vault.decrypted_secrets where name = 'push_webhook_secret';
  exception when others then
    v_push_url := null;
  end;

  -- ===========================================================================
  -- 0. PRE-END WAKE-UP. ~2 min before a battle ends, send each participant a
  --    SILENT (data-only) push so their device wakes and uploads fresh steps
  --    before the freeze. Guarded by wake_ping_sent → at most once per battle.
  --    The 90s completion grace (section B) gives the woken sync time to land.
  -- ===========================================================================
  if v_push_url is not null and v_push_secret is not null then
    for b in
      select * from public.battles
      where status = 'active'
        and not wake_ping_sent
        and end_time > now()
        and end_time <= now() + interval '2 minutes'
    loop
      for p in
        select pr.fcm_token as token
        from public.battle_participants bp
        join public.profiles pr on pr.id = bp.user_id
        where bp.battle_id = b.id
          and bp.invite_status = 'accepted'
          and pr.fcm_token is not null
          and pr.fcm_token <> ''
      loop
        perform net.http_post(
          url := v_push_url,
          body := jsonb_build_object(
            'token', p.token,
            'silent', true,
            'data', jsonb_build_object('type', 'sync_wake', 'battle_id', b.id)
          ),
          headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'x-webhook-secret', v_push_secret
          ),
          timeout_milliseconds := 5000
        );
      end loop;
      update public.battles set wake_ping_sent = true where id = b.id;
    end loop;
  end if;

  -- ===========================================================================
  -- A. ACTIVATE scheduled battles whose start_time has arrived.
  -- ===========================================================================
  for b in
    select * from public.battles
    where status = 'scheduled'
      and start_time <= now()
  loop
    -- Snapshot each accepted participant's lifetime counter as their baseline.
    update public.battle_participants bp
    set start_steps_baseline = pr.total_steps_all_time,
        current_steps = 0
    from public.profiles pr
    where bp.battle_id = b.id
      and bp.user_id = pr.id
      and bp.invite_status = 'accepted';

    update public.battles set status = 'active' where id = b.id;

    insert into public.notifications (user_id, type, title, body, data)
    values (
      b.created_by,
      'battle_started',
      'Battle Live',
      'Your battle just started. Step it up!',
      jsonb_build_object('battle_id', b.id)
    );
  end loop;

  -- ===========================================================================
  -- B. COMPLETE active battles whose end_time has passed.
  -- ===========================================================================
  for b in
    select * from public.battles
    where status = 'active'
      -- 90s grace after end_time: lets the pre-end wake-up sync (and a slow
      -- foreground final sync) upload before we freeze the score.
      and end_time < now() - interval '90 seconds'
  loop
    -- Recompute each participant's score straight from the source of truth
    -- (total_steps_all_time - baseline), so the result is correct even if the
    -- client never ran _propagateToActiveBattles to keep current_steps fresh.
    update public.battle_participants bp
    set current_steps = greatest(
          0,
          pr.total_steps_all_time
            - coalesce(bp.start_steps_baseline, pr.total_steps_all_time)
        )
    from public.profiles pr
    where bp.battle_id = b.id
      and bp.user_id = pr.id;

    -- Pick winner: highest current_steps. Ties or all-zero → no winner.
    v_winner := null;
    v_top := -1;
    v_tie := false;
    for p in
      select user_id, current_steps
      from public.battle_participants
      where battle_id = b.id
        and invite_status = 'accepted'
    loop
      if p.current_steps > v_top then
        v_top := p.current_steps;
        v_winner := p.user_id;
        v_tie := false;
      elsif p.current_steps = v_top then
        v_tie := true;
      end if;
    end loop;
    if v_tie or v_top <= 0 then
      v_winner := null;
    end if;

    -- Freeze every participant: stamp end_steps_baseline + is_winner.
    update public.battle_participants bp
    set end_steps_baseline = pr.total_steps_all_time,
        is_winner = (bp.user_id = v_winner)
    from public.profiles pr
    where bp.battle_id = b.id
      and bp.user_id = pr.id;

    update public.battles
    set status = 'completed',
        winner_id = v_winner
    where id = b.id;

    -- Award the winner battle XP + bump their battle-category missions.
    if v_winner is not null then
      perform public.award_xp(v_winner, b.xp_reward);

      for m in select * from public.missions where category = 'battle' loop
        v_period := case when m.type = 'daily' then v_today else v_week end;

        select current_value, is_completed
        into v_prior, v_was
        from public.user_mission_progress
        where user_id = v_winner
          and mission_id = m.id
          and period_start = v_period;

        v_prior := coalesce(v_prior, 0);
        v_was := coalesce(v_was, false);
        v_new := v_prior + 1;
        v_done := v_new >= m.target_value;

        insert into public.user_mission_progress
          (user_id, mission_id, period_start, current_value, target_value, is_completed, completed_at)
        values
          (v_winner, m.id, v_period, v_new, m.target_value, v_done,
           case when v_done then now() else null end)
        on conflict (user_id, mission_id, period_start) do update
        set current_value = excluded.current_value,
            -- monotonic-true completion, matching StepService._upsertProgress
            is_completed = public.user_mission_progress.is_completed or excluded.is_completed,
            completed_at = coalesce(public.user_mission_progress.completed_at, excluded.completed_at);

        if v_done and not v_was then
          perform public.award_xp(v_winner, m.xp_reward);
        end if;
      end loop;
    end if;

    -- Notify every participant of the result.
    insert into public.notifications (user_id, type, title, body, data)
    select
      bp.user_id,
      'battle_result',
      'Battle Ended',
      case
        when v_winner is null then 'Battle ended in a tie'
        when bp.user_id = v_winner then 'You won the battle! +' || b.xp_reward || ' XP'
        else 'Battle ended — better luck next time'
      end,
      jsonb_build_object('battle_id', b.id, 'winner_id', v_winner)
    from public.battle_participants bp
    where bp.battle_id = b.id
      and bp.invite_status = 'accepted';
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- Schedule it to run every minute (≤60s latency on activation/completion).
-- Unschedule first so re-running this file doesn't create duplicate jobs.
-- -----------------------------------------------------------------------------
do $$
begin
  perform cron.unschedule('battle-lifecycle');
exception
  when others then null;  -- job didn't exist yet
end $$;

select cron.schedule(
  'battle-lifecycle',
  '* * * * *',
  $$ select public.process_battle_lifecycle(); $$
);

-- =============================================================================
-- Inspect after applying:
--
--   -- the scheduled job
--   select jobid, schedule, jobname, active from cron.job;
--
--   -- recent runs (success/failure)
--   select jobid, status, return_message, start_time
--   from cron.job_run_details
--   order by start_time desc limit 20;
--
--   -- run it once manually
--   select public.process_battle_lifecycle();
-- =============================================================================
