-- =============================================================================
-- Migration 0046: Per-user local daily battle windows + settlement RPC
-- =============================================================================
--
-- Prior daily-series behavior: `process_battle_lifecycle` used the
-- battles.end_time UTC stamp for settlement — same for every player.
-- That treated a user in India (IST) and a user in Germany (CET) as
-- ending their day at the same instant, which is unfair when the
-- battle window is meant to be "your local calendar day".
--
-- Also: spawn logic dropped stake_xp, preferred_name, and battle_avatar_id
-- when creating tomorrow's instance. And nothing charged the daily
-- stake on spawn — creator paid for day 1 but subsequent days went
-- through free.
--
-- This migration encodes the confirmed daily-series spec:
--   • Each participant scores on THEIR local calendar date (via
--     profiles.tz_offset_minutes from 0045).
--   • Settlement waits for MAX(each user's local 23:59) to pass.
--   • Winner = highest step_logs.step_count for their competing date;
--     tie → refund all stakes.
--   • On spawn, charges each still-active participant their stake;
--     anyone who can't afford is dropped. Series ends when active
--     count < 2.
--   • Late joiners (accept after day 1 already active) skip day 1 —
--     they enter fresh from their own local tomorrow.
--
-- HOW TO APPLY: Dashboard → SQL Editor → paste → Run. Idempotent.
--
-- NOTE: Migration 0047 later rewrote settle_daily_battle and
-- process_battle_lifecycle again — to route XP credits through
-- _credit_xp_admin (bypass the deployed credit_user_xp policy that
-- rejects cross-user writes) and to restore 0018's stake-payout branch
-- for non-daily 1v1/group battles that this migration accidentally
-- dropped. Applying 0046 → 0047 arrives at the current live state.
-- =============================================================================

-- 1. Schema additions ---------------------------------------------------------

-- Daily debit amount, needed by settlement to know how much to charge per day.
alter table public.battle_series
  add column if not exists stake_xp int default 0;

-- Roster status + spawn-input fields.
alter table public.battle_series_participants
  add column if not exists status text default 'active'
    check (status in ('pending_invite', 'active', 'dropped_out')),
  add column if not exists accepted_at timestamptz,
  add column if not exists dropped_at timestamptz,
  add column if not exists drop_reason text,
  add column if not exists preferred_name text,
  add column if not exists battle_avatar_id text default 'avatar_01';

-- Each daily-instance participant row records the LOCAL DATE (in that
-- participant's tz) that they were competing on. step_logs are looked up
-- by (user_id, date), so this is what settlement uses to grab their score.
-- Null for non-daily battles (they use shared start/end_time as before).
alter table public.battle_participants
  add column if not exists competing_date text;

-- 2. Helper: end of a given local date in UTC, using the user's tz_offset. ---
create or replace function public.user_local_end_utc(
  p_user_id        uuid,
  p_competing_date text     -- YYYY-MM-DD in user's local tz
) returns timestamptz
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_offset int;
  v_end_naive timestamp;
begin
  select coalesce(tz_offset_minutes, 330) into v_offset
    from public.profiles where id = p_user_id;
  if v_offset is null then v_offset := 330; end if;
  v_end_naive := (p_competing_date::date + interval '1 day' - interval '1 second');
  -- user_local = utc + offset  ⇒  utc = user_local - offset
  return (v_end_naive - make_interval(mins => v_offset)) at time zone 'UTC';
end;
$$;

grant execute on function public.user_local_end_utc(uuid, text) to authenticated;

-- 3. settle_daily_battle — first version (rewritten again in 0047) -----------
create or replace function public.settle_daily_battle(p_battle_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_battle          record;
  v_series          record;
  v_max_end_utc     timestamptz;
  v_p               record;
  v_winner_uid      uuid;
  v_winner_steps    int := -1;
  v_stake           int;
  v_pot             bigint := 0;
  v_active_tomorrow uuid[] := array[]::uuid[];
  v_sp              record;
  v_balance         bigint;
  v_new_battle_id   uuid;
  v_next_local_date text;
  v_tie             boolean := false;
begin
  select * into v_battle from public.battles where id = p_battle_id;
  if v_battle.id is null then return; end if;
  if v_battle.series_id is null then return; end if;
  if v_battle.status not in ('active', 'scheduled') then return; end if;

  select * into v_series from public.battle_series where id = v_battle.series_id;
  if v_series.id is null then return; end if;

  select max(public.user_local_end_utc(bp.user_id, bp.competing_date))
    into v_max_end_utc
    from public.battle_participants bp
   where bp.battle_id = p_battle_id
     and bp.invite_status = 'accepted'
     and bp.competing_date is not null;

  if v_max_end_utc is null then
    update public.battles set status = 'completed' where id = p_battle_id;
    return;
  end if;
  if now() < v_max_end_utc then return; end if;

  v_stake := coalesce(v_battle.stake_xp, coalesce(v_series.stake_xp, 0));

  for v_p in
    select bp.user_id, bp.competing_date, coalesce(bp.stake_paid, false) as paid
      from public.battle_participants bp
     where bp.battle_id = p_battle_id
       and bp.invite_status = 'accepted'
       and bp.competing_date is not null
  loop
    declare v_steps int;
    begin
      select coalesce(step_count, 0) into v_steps
        from public.step_logs
       where user_id = v_p.user_id and date = v_p.competing_date
       limit 1;
      v_steps := coalesce(v_steps, 0);

      update public.battle_participants
         set current_steps = v_steps
       where battle_id = p_battle_id and user_id = v_p.user_id;

      if v_steps > 0 then
        if v_steps > v_winner_steps then
          v_winner_steps := v_steps; v_winner_uid := v_p.user_id; v_tie := false;
        elsif v_steps = v_winner_steps then
          v_tie := true;
        end if;
      end if;
      if v_p.paid then v_pot := v_pot + v_stake; end if;
    end;
  end loop;

  if v_tie then v_winner_uid := null; end if;

  if v_winner_uid is not null and v_pot > 0 then
    perform public.credit_user_xp(
      v_winner_uid, v_pot::int, 'battle_win',
      jsonb_build_object('battle_id', p_battle_id, 'series_id', v_series.id)
    );
    update public.battle_participants
       set is_winner = true
     where battle_id = p_battle_id and user_id = v_winner_uid;
  elsif v_pot > 0 then
    for v_p in
      select user_id from public.battle_participants
       where battle_id = p_battle_id and stake_paid = true
    loop
      perform public.credit_user_xp(
        v_p.user_id, v_stake, 'battle_refund',
        jsonb_build_object('battle_id', p_battle_id, 'reason', 'daily_tie_or_no_winner')
      );
    end loop;
  end if;

  update public.battles
     set status = 'completed', winner_id = v_winner_uid
   where id = p_battle_id;

  insert into public.notifications (user_id, type, title, body, data)
  select bp.user_id, 'battle_result', 'Daily Battle Ended',
    case
      when v_winner_uid is null then 'Today''s daily battle ended in a tie'
      when bp.user_id = v_winner_uid then
        'You won today''s daily battle! +' || v_pot::int || ' XP'
      else 'You lost today''s daily battle. Better luck tomorrow!'
    end,
    jsonb_build_object('battle_id', p_battle_id, 'series_id', v_series.id,
                       'winner_id', v_winner_uid)
    from public.battle_participants bp
   where bp.battle_id = p_battle_id and bp.invite_status = 'accepted';

  if v_series.status <> 'active' then return; end if;

  for v_sp in
    select user_id from public.battle_series_participants
     where series_id = v_series.id and status = 'active'
  loop
    if v_stake > 0 then
      select coalesce(total_xp, 0) into v_balance
        from public.profiles where id = v_sp.user_id;
      if v_balance < v_stake then
        update public.battle_series_participants
           set status = 'dropped_out', dropped_at = now(),
               drop_reason = 'insufficient_xp'
         where series_id = v_series.id and user_id = v_sp.user_id;
        insert into public.notifications (user_id, type, title, body, data)
        values (v_sp.user_id, 'daily_series_dropped',
                'Daily Series Ended',
                'You ran out of XP to continue the daily series.',
                jsonb_build_object('series_id', v_series.id,
                                   'reason', 'insufficient_xp'));
        continue;
      end if;
    end if;
    v_active_tomorrow := array_append(v_active_tomorrow, v_sp.user_id);
  end loop;

  if coalesce(array_length(v_active_tomorrow, 1), 0) < 2 then
    update public.battle_series
       set status = 'stopped', stopped_at = now()
     where id = v_series.id;
    insert into public.notifications (user_id, type, title, body, data)
    select sp.user_id, 'daily_series_ended', 'Daily Series Ended',
           'Not enough active players to continue the series.',
           jsonb_build_object('series_id', v_series.id,
                              'reason', 'insufficient_participants')
      from public.battle_series_participants sp
     where sp.series_id = v_series.id and sp.status = 'active';
    return;
  end if;

  insert into public.battles (
    type, status, start_time, end_time, xp_reward, stake_xp,
    created_by, series_id, visibility, join_code
  ) values (
    v_battle.type, 'active', now(), now() + interval '48 hours',
    coalesce(v_battle.xp_reward, 0), v_stake,
    v_battle.created_by, v_battle.series_id,
    v_battle.visibility, v_battle.join_code
  )
  returning id into v_new_battle_id;

  for v_sp in
    select sp.user_id, sp.display_name, sp.preferred_name, sp.avatar_url,
           coalesce(sp.battle_avatar_id, 'avatar_01') as battle_avatar_id
      from public.battle_series_participants sp
     where sp.series_id = v_series.id
       and sp.user_id = ANY(v_active_tomorrow)
  loop
    v_next_local_date := (
      ((now() at time zone 'utc')
       + make_interval(mins => coalesce(
           (select tz_offset_minutes from public.profiles where id = v_sp.user_id),
           330)))::date + 1
    )::text;

    insert into public.battle_participants (
      battle_id, user_id, display_name, preferred_name, avatar_url,
      battle_avatar_id, current_steps, is_winner, invite_status,
      competing_date, stake_paid
    ) values (
      v_new_battle_id, v_sp.user_id, v_sp.display_name, v_sp.preferred_name,
      v_sp.avatar_url, v_sp.battle_avatar_id,
      0, false, 'accepted', v_next_local_date, false
    );

    if v_stake > 0 then
      perform public.credit_user_xp(
        v_sp.user_id, -v_stake, 'battle_stake',
        jsonb_build_object('battle_id', v_new_battle_id,
                           'series_id', v_series.id,
                           'day', v_next_local_date)
      );
      update public.battle_participants
         set stake_paid = true
       where battle_id = v_new_battle_id and user_id = v_sp.user_id;
    end if;
  end loop;
end;
$$;

revoke all on function public.settle_daily_battle(uuid) from public;
grant execute on function public.settle_daily_battle(uuid) to authenticated;

-- 4. process_battle_lifecycle — first version (rewritten in 0047).
--    Routes daily instances to settle_daily_battle. Non-daily flow
--    identical to the pre-0046 code except for the series_id filter
--    added to sections A and B.
--
--    NOTE: This version DROPPED 0018's stake-payout branch as a
--    regression — restored in 0047. Prefer applying 0046 → 0047
--    rather than stopping at 0046.
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
  v_winning_team    text;
  v_top_team_sum    bigint;
  v_team_tie        boolean;
  v_team_size       int;
  v_team_xp_per_member integer;
  v_today  text := to_char(now() at time zone 'utc', 'YYYY-MM-DD');
  v_week   text := to_char(
                     (now() at time zone 'utc')::date
                     - (extract(isodow from now() at time zone 'utc')::int - 1),
                     'YYYY-MM-DD');
begin
  if not pg_try_advisory_xact_lock(424242) then return; end if;

  begin
    select decrypted_secret into v_push_url
      from vault.decrypted_secrets where name = 'push_function_url';
    select decrypted_secret into v_push_secret
      from vault.decrypted_secrets where name = 'push_webhook_secret';
  exception when others then v_push_url := null;
  end;

  -- 0. Pre-end wake-up push (non-daily only).
  if v_push_url is not null and v_push_secret is not null then
    for b in
      select * from public.battles
      where status = 'active' and not wake_ping_sent
        and end_time > now() and end_time <= now() + interval '2 minutes'
        and series_id is null
    loop
      for p in
        select pr.fcm_token as token
        from public.battle_participants bp
        join public.profiles pr on pr.id = bp.user_id
        where bp.battle_id = b.id and bp.invite_status = 'accepted'
          and pr.fcm_token is not null and pr.fcm_token <> ''
      loop
        perform net.http_post(
          url := v_push_url,
          body := jsonb_build_object('token', p.token, 'silent', true,
            'data', jsonb_build_object('type', 'sync_wake', 'battle_id', b.id)),
          headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'x-webhook-secret', v_push_secret),
          timeout_milliseconds := 5000
        );
      end loop;
      update public.battles set wake_ping_sent = true where id = b.id;
    end loop;
  end if;

  -- 0.5 Daily-series settlement.
  for b in
    select id from public.battles
     where status = 'active' and series_id is not null
  loop
    perform public.settle_daily_battle(b.id);
  end loop;

  -- A. Activate scheduled non-daily battles.
  for b in
    select * from public.battles
    where status = 'scheduled' and start_time <= now()
      and series_id is null
  loop
    update public.battle_participants bp
    set start_steps_baseline = pr.total_steps_all_time, current_steps = 0
    from public.profiles pr
    where bp.battle_id = b.id and bp.user_id = pr.id
      and bp.invite_status = 'accepted';
    update public.battles set status = 'active' where id = b.id;
    insert into public.notifications (user_id, type, title, body, data)
    values (b.created_by, 'battle_started', 'Battle Live',
            'Your battle just started. Step it up!',
            jsonb_build_object('battle_id', b.id));
  end loop;

  -- B. Complete active non-daily battles by shared end_time (legacy
  --    free-play only; 0047 re-adds the stake branch on top).
  for b in
    select * from public.battles
    where status = 'active'
      and end_time < now() - interval '90 seconds'
      and series_id is null
  loop
    update public.battle_participants bp
    set current_steps = greatest(0,
          pr.total_steps_all_time
            - coalesce(bp.start_steps_baseline, pr.total_steps_all_time))
    from public.profiles pr
    where bp.battle_id = b.id and bp.user_id = pr.id;

    if b.type = 'team' then
      v_winning_team := null; v_top_team_sum := -1; v_team_tie := false;
      for p in
        select team_label, sum(current_steps) as team_sum
        from public.battle_participants
        where battle_id = b.id and invite_status = 'accepted'
          and team_label is not null
        group by team_label
      loop
        if p.team_sum > v_top_team_sum then
          v_top_team_sum := p.team_sum; v_winning_team := p.team_label; v_team_tie := false;
        elsif p.team_sum = v_top_team_sum then v_team_tie := true;
        end if;
      end loop;
      if v_team_tie or v_top_team_sum <= 0 then v_winning_team := null; end if;

      update public.battle_participants bp
      set end_steps_baseline = pr.total_steps_all_time,
          is_winner = (v_winning_team is not null and bp.team_label = v_winning_team)
      from public.profiles pr
      where bp.battle_id = b.id and bp.user_id = pr.id;
      update public.battles set status = 'completed', winner_id = null where id = b.id;

      if v_winning_team is not null then
        select count(*) into v_team_size
        from public.battle_participants
        where battle_id = b.id and invite_status = 'accepted' and team_label = v_winning_team;
        v_team_xp_per_member := b.xp_reward * v_team_size;
        for p in
          select user_id from public.battle_participants
          where battle_id = b.id and invite_status = 'accepted' and team_label = v_winning_team
        loop
          perform public.award_xp(p.user_id, v_team_xp_per_member);
        end loop;
      end if;
      insert into public.notifications (user_id, type, title, body, data)
      select bp.user_id, 'battle_result', 'Battle Ended',
        case when v_winning_team is null then 'Team battle ended in a tie'
             when bp.team_label = v_winning_team then 'Your team won! +' || v_team_xp_per_member || ' XP'
             else 'Team battle ended — better luck next time' end,
        jsonb_build_object('battle_id', b.id, 'winning_team', v_winning_team)
        from public.battle_participants bp
       where bp.battle_id = b.id and bp.invite_status = 'accepted';
      continue;
    end if;

    v_winner := null; v_top := -1; v_tie := false;
    for p in
      select user_id, current_steps from public.battle_participants
       where battle_id = b.id and invite_status = 'accepted'
    loop
      if p.current_steps > v_top then
        v_top := p.current_steps; v_winner := p.user_id; v_tie := false;
      elsif p.current_steps = v_top then v_tie := true;
      end if;
    end loop;
    if v_tie or v_top <= 0 then v_winner := null; end if;

    update public.battle_participants bp
    set end_steps_baseline = pr.total_steps_all_time,
        is_winner = (bp.user_id = v_winner)
    from public.profiles pr
    where bp.battle_id = b.id and bp.user_id = pr.id;
    update public.battles set status = 'completed', winner_id = v_winner where id = b.id;

    if v_winner is not null then
      perform public.award_xp(v_winner, b.xp_reward);
    end if;
    insert into public.notifications (user_id, type, title, body, data)
    select bp.user_id, 'battle_result', 'Battle Ended',
      case when v_winner is null then 'Battle ended in a tie'
           when bp.user_id = v_winner then 'You won the battle! +' || b.xp_reward || ' XP'
           else 'Battle ended — better luck next time' end,
      jsonb_build_object('battle_id', b.id, 'winner_id', v_winner)
      from public.battle_participants bp
     where bp.battle_id = b.id and bp.invite_status = 'accepted';
  end loop;
end;
$$;
