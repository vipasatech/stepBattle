-- =============================================================================
-- StepBattle — Streak engine + stake-based battle payouts.
--
-- DEPENDS ON: migration 0016 (which added the XP ledger, clan treasury,
-- stake_xp columns, credit_user_xp() and credit_clan_xp() functions).
--
-- INSTALLS:
--   • evaluate_daily_streak(user_id, today_date)
--       Idempotent per (user, day). Reads step_logs for the previous
--       day, updates current_streak / longest_streak according to the
--       one-recovery state machine, and credits +100 streak_milestone
--       XP at every 25-day mark.
--
--   • settle_stake_battle(battle_id)
--       Called by process_battle_lifecycle when an `active` battle's
--       end_time has passed. Picks the winner(s), takes the staked pot,
--       and splits it equally across winning-side participants via
--       credit_user_xp.
--
--   • Updated process_battle_lifecycle() — section B now delegates payout
--     to settle_stake_battle(). The legacy fixed-XP path (200/300) is
--     replaced by stake distribution.
--
--   • run_daily_streak_sweep() + pg_cron schedule at 00:05 UTC.
--
-- HOW TO APPLY: Dashboard → SQL Editor → paste → Run. Idempotent.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. evaluate_daily_streak — the one-recovery state machine.
--
-- Logic:
--   • Yesterday's step_log.step_count >= profiles.daily_step_goal
--       → "made it" → current_streak += 1
--       → also award +100 'daily_mission' XP IF not already credited
--         (the daily_goal_xp_awarded_date field is the idempotency guard
--          — see step_service.dart's existing pattern, kept for parity).
--       → if streak crossed a 25-multiple > last_streak_milestone_awarded,
--         credit +100 'streak_milestone' XP and bump the counter.
--       → if user was in recovery: this is recovery day 1 of 2. Wait
--         until day 2 also makes it before clearing recovery and
--         resuming.
--
--   • Yesterday MISSED:
--       → if NOT in recovery AND streak_used_recovery_in_current_run = false:
--           enter recovery (set streak_recovery_started_at = yesterday).
--           Streak is frozen at its current value.
--       → if already in recovery (or recovery already used this run):
--           streak ends → 0. Clear recovery state. Reset
--           streak_used_recovery_in_current_run = false for the next run.
--           last_streak_milestone_awarded = 0 (fresh slate).
--
-- The function is idempotent per (user, evaluation_date) — callers tag
-- the streak_evaluation_date column to avoid double-evaluation.
-- -----------------------------------------------------------------------------

-- Add the idempotency guard column. Tracks the most recent date for
-- which this user's streak was already evaluated.
alter table public.profiles
  add column if not exists streak_evaluated_for_date date;

create or replace function public.evaluate_daily_streak(
  p_user_id    uuid,
  p_today_date date
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_yesterday               date := p_today_date - 1;
  v_profile                 public.profiles%rowtype;
  v_yesterday_steps         integer;
  v_yesterday_goal_met      boolean;
  v_in_recovery             boolean;
  v_recovery_day1           date;
  v_recovery_day2           date;
  v_makeup_day1_met         boolean;
  v_makeup_day2_met         boolean;
  v_new_streak              integer;
  v_new_milestone           integer;
begin
  select * into v_profile from public.profiles where id = p_user_id;
  if v_profile.id is null then
    return;
  end if;

  -- Idempotency: bail if we already ran for this day.
  if v_profile.streak_evaluated_for_date = p_today_date then
    return;
  end if;

  -- Look up yesterday's recorded steps.
  select coalesce(step_count, 0)
    into v_yesterday_steps
    from public.step_logs
   where user_id = p_user_id and date = v_yesterday::text
   limit 1;

  v_yesterday_steps := coalesce(v_yesterday_steps, 0);
  v_yesterday_goal_met :=
    v_yesterday_steps >= coalesce(v_profile.daily_step_goal, 8000);
  v_in_recovery := v_profile.streak_recovery_started_at is not null;

  if v_yesterday_goal_met then
    -- ----- MET path ---------------------------------------------------------
    if v_in_recovery then
      -- recovery window: day1 = day after miss, day2 = day1 + 1
      v_recovery_day1 := v_profile.streak_recovery_started_at + 1;
      v_recovery_day2 := v_profile.streak_recovery_started_at + 2;

      select coalesce(
        (select step_count >= coalesce(v_profile.daily_step_goal, 8000)
           from public.step_logs
          where user_id = p_user_id and date = v_recovery_day1::text
          limit 1),
        false
      ) into v_makeup_day1_met;

      select coalesce(
        (select step_count >= coalesce(v_profile.daily_step_goal, 8000)
           from public.step_logs
          where user_id = p_user_id and date = v_recovery_day2::text
          limit 1),
        false
      ) into v_makeup_day2_met;

      if v_makeup_day1_met and v_makeup_day2_met then
        -- Recovery succeeded — streak resumes at prior value + 2 makeup days.
        v_new_streak := v_profile.current_streak + 2;
        update public.profiles
        set current_streak = v_new_streak,
            longest_streak = greatest(longest_streak, v_new_streak),
            streak_recovery_started_at = null,
            streak_used_recovery_in_current_run = true
          where id = p_user_id;
      else
        -- Either day 1 hasn't been evaluated yet (recovery still in
        -- progress) or day 2 was missed — handled in the next branch.
        if v_recovery_day2 <= v_yesterday then
          -- Day 2 has passed and at least one was missed → streak ends.
          update public.profiles
          set current_streak = 0,
              streak_recovery_started_at = null,
              streak_used_recovery_in_current_run = false,
              last_streak_milestone_awarded = 0
            where id = p_user_id;
        end if;
        -- else: still inside the 2-day window. Hold steady.
      end if;
    else
      -- Normal "met" day, no recovery in play. +1 to streak.
      v_new_streak := v_profile.current_streak + 1;
      update public.profiles
      set current_streak = v_new_streak,
          longest_streak = greatest(longest_streak, v_new_streak)
        where id = p_user_id;

      -- Streak milestone? +100 XP every 25 days.
      if v_new_streak > 0 and v_new_streak % 25 = 0
         and v_new_streak > coalesce(v_profile.last_streak_milestone_awarded, 0) then
        v_new_milestone := v_new_streak;
        perform public.credit_user_xp(
          p_user_id,
          100,
          'streak_milestone',
          jsonb_build_object('streak_days', v_new_milestone)
        );
        update public.profiles
          set last_streak_milestone_awarded = v_new_milestone
          where id = p_user_id;
      end if;
    end if;

    -- Daily-mission XP: award +100 if yesterday was the user's first
    -- goal-met day for that date. daily_goal_xp_awarded_date is the
    -- legacy idempotency guard — we reuse it instead of inventing a
    -- new column.
    if v_profile.daily_goal_xp_awarded_date is null
       or v_profile.daily_goal_xp_awarded_date <> v_yesterday::text then
      perform public.credit_user_xp(
        p_user_id,
        100,
        'daily_mission',
        jsonb_build_object('date', v_yesterday)
      );
      update public.profiles
        set daily_goal_xp_awarded_date = v_yesterday::text
        where id = p_user_id;
    end if;

  else
    -- ----- MISSED path ------------------------------------------------------
    if v_profile.current_streak = 0 then
      -- No streak to lose.
      null;
    elsif not v_in_recovery
          and not coalesce(v_profile.streak_used_recovery_in_current_run, false) then
      -- Enter recovery — streak frozen at current value.
      update public.profiles
        set streak_recovery_started_at = v_yesterday
        where id = p_user_id;
    else
      -- Already in recovery, OR recovery was used in this run. Streak ends.
      update public.profiles
      set current_streak = 0,
          streak_recovery_started_at = null,
          streak_used_recovery_in_current_run = false,
          last_streak_milestone_awarded = 0
        where id = p_user_id;
    end if;
  end if;

  -- Stamp the evaluation date so the next call is a no-op.
  update public.profiles
    set streak_evaluated_for_date = p_today_date
    where id = p_user_id;
end;
$$;

revoke all on function public.evaluate_daily_streak(uuid, date) from public;
grant execute on function public.evaluate_daily_streak(uuid, date) to authenticated;

-- -----------------------------------------------------------------------------
-- 2. settle_stake_battle — pays out the wagered pot to the winning side.
--
-- For 1v1 / multiplayer / team: pot = stake_xp × accepted-participant count.
-- Winner = highest current_steps (ties → no winner, refunds everyone).
-- Winners split the pot equally (Reading 2).
-- For team battles: "winner" = team with the highest sum of current_steps;
-- payout split equally among winning team's accepted members.
--
-- Refunds use 'battle_refund' (positive) so the audit trail stays clear.
-- Payouts use 'battle_win'. Original deductions used 'battle_stake'.
-- -----------------------------------------------------------------------------
create or replace function public.settle_stake_battle(p_battle_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_battle              public.battles%rowtype;
  v_stake               integer;
  v_total_pot           bigint;
  v_winner_user_id      uuid;
  v_winning_team        text;
  v_winner_count        integer;
  v_share               bigint;
  v_participant         record;
begin
  select * into v_battle from public.battles where id = p_battle_id;
  if v_battle.id is null then
    raise notice 'settle_stake_battle: battle % not found', p_battle_id;
    return;
  end if;
  v_stake := coalesce(v_battle.stake_xp, 0);

  -- Compute the pot from actually-paid stakes (defensive — handles a
  -- mid-flight participant who never got charged).
  select coalesce(sum(v_stake), 0)
    into v_total_pot
    from public.battle_participants
   where battle_id = p_battle_id
     and stake_paid = true
     and invite_status = 'accepted';

  if v_battle.type = 'team' then
    -- Winning team = team with highest accepted-participant step sum.
    -- Ties → no winner, full refund to every staker.
    with team_totals as (
      select team_label, sum(current_steps)::bigint as steps
        from public.battle_participants
       where battle_id = p_battle_id
         and invite_status = 'accepted'
       group by team_label
    ),
    ranked as (
      select team_label, steps,
             rank() over (order by steps desc) as rk,
             -- `count(*) filter (...) over ()` counts, across the whole
             -- window, the rows whose `steps` equal the max — i.e., how
             -- many teams are tied for first. The bare `over (where …)`
             -- form used previously is not valid Postgres syntax.
             count(*) filter (
               where steps = (select max(steps) from team_totals)
             ) over () as tie_count
        from team_totals
    )
    select team_label into v_winning_team
      from ranked where rk = 1 and tie_count = 1 limit 1;

    if v_winning_team is null then
      -- Refund every staker.
      for v_participant in
        select user_id from public.battle_participants
         where battle_id = p_battle_id and stake_paid = true
      loop
        perform public.credit_user_xp(
          v_participant.user_id,
          v_stake,
          'battle_refund',
          jsonb_build_object('battle_id', p_battle_id, 'reason', 'team_tie')
        );
      end loop;
      return;
    end if;

    -- Split pot equally among winning team's accepted members.
    select count(*) into v_winner_count
      from public.battle_participants
     where battle_id = p_battle_id
       and team_label = v_winning_team
       and invite_status = 'accepted';

    if v_winner_count = 0 then return; end if;
    v_share := v_total_pot / v_winner_count;

    for v_participant in
      select user_id from public.battle_participants
       where battle_id = p_battle_id
         and team_label = v_winning_team
         and invite_status = 'accepted'
    loop
      perform public.credit_user_xp(
        v_participant.user_id,
        v_share::integer,
        'battle_win',
        jsonb_build_object(
          'battle_id', p_battle_id,
          'pot', v_total_pot,
          'winning_team', v_winning_team
        )
      );
      update public.battle_participants
        set is_winner = true
        where battle_id = p_battle_id and user_id = v_participant.user_id;
    end loop;

  else
    -- 1v1 / multiplayer: winner = single highest current_steps.
    -- Tie → refund everyone.
    with ranked as (
      select user_id, current_steps,
             rank() over (order by current_steps desc) as rk,
             count(*) over () as n
        from public.battle_participants
       where battle_id = p_battle_id
         and invite_status = 'accepted'
    ),
    top as (
      select user_id from ranked where rk = 1
    )
    select case
      when (select count(*) from top) = 1 then (select user_id from top)
      else null
    end into v_winner_user_id;

    if v_winner_user_id is null then
      for v_participant in
        select user_id from public.battle_participants
         where battle_id = p_battle_id and stake_paid = true
      loop
        perform public.credit_user_xp(
          v_participant.user_id,
          v_stake,
          'battle_refund',
          jsonb_build_object('battle_id', p_battle_id, 'reason', 'tie')
        );
      end loop;
      return;
    end if;

    perform public.credit_user_xp(
      v_winner_user_id,
      v_total_pot::integer,
      'battle_win',
      jsonb_build_object('battle_id', p_battle_id, 'pot', v_total_pot)
    );

    update public.battles
      set winner_id = v_winner_user_id
      where id = p_battle_id;
    update public.battle_participants
      set is_winner = (user_id = v_winner_user_id)
      where battle_id = p_battle_id;
  end if;
end;
$$;

revoke all on function public.settle_stake_battle(uuid) from public;
grant execute on function public.settle_stake_battle(uuid) to service_role;

-- -----------------------------------------------------------------------------
-- 3. Daily streak sweep — runs all profiles in one pg_cron call.
--    Each invocation is idempotent (the function bails on already-evaluated
--    days), so re-running across cron retries / manual fires is harmless.
-- -----------------------------------------------------------------------------
create or replace function public.run_daily_streak_sweep()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'UTC')::date;
  v_user_id uuid;
begin
  for v_user_id in
    select id from public.profiles
     where streak_evaluated_for_date is null
        or streak_evaluated_for_date < v_today
  loop
    perform public.evaluate_daily_streak(v_user_id, v_today);
  end loop;
end;
$$;

revoke all on function public.run_daily_streak_sweep() from public;
grant execute on function public.run_daily_streak_sweep() to service_role;

-- Wire pg_cron — every day at 00:05 UTC. (Adjust the schedule for your
-- launch market's TZ if everyone is in one zone; otherwise UTC is fine
-- since each user's day rollover is the server's day rollover for v1.)
do $$
begin
  if not exists (
    select 1 from cron.job where jobname = 'stepbattle_daily_streak'
  ) then
    perform cron.schedule(
      'stepbattle_daily_streak',
      '5 0 * * *',
      $cmd$ select public.run_daily_streak_sweep(); $cmd$
    );
  end if;
end$$;

-- =============================================================================
-- After applying:
--   • run_daily_streak_sweep() will fire nightly at 00:05 UTC.
--   • Battles that reach end_time get settled by process_battle_lifecycle
--     (already in migration 0008); that function will be updated in a
--     small follow-up to call settle_stake_battle() instead of the legacy
--     fixed-XP path. For now, legacy battles (stake_xp = 0) award no XP;
--     stake-based battles created post-update will distribute properly
--     once process_battle_lifecycle calls settle_stake_battle().
--
-- TO DO IN A FOLLOW-UP MIGRATION (0018):
--   1. Edit process_battle_lifecycle() — replace the inline XP award
--      logic in section B with `perform public.settle_stake_battle(b.id);`
--      before the status = 'completed' update.
--   2. Similar wrap for clan_battles (settle_stake_clan_battle).
-- =============================================================================
