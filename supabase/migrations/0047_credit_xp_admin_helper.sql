-- =============================================================================
-- Migration 0047: Server-only XP credit helper + pipeline rewrites + backfill
-- =============================================================================
--
-- Two independent bugs surfaced at the same time — this migration
-- addresses both:
--
-- BUG 1 — stake payout regression from 0046. When 0046 rewrote
-- process_battle_lifecycle, it accidentally dropped 0018's stake-payout
-- branch. Non-daily 1v1 / group battles with stake_xp > 0 no longer
-- called settle_stake_battle, so winners never received the pot.
-- Their -100 XP stake was debited on accept, but the +200 XP battle_win
-- credit never landed. This migration re-inserts the stake branch on
-- top of 0046's daily-series routing.
--
-- BUG 2 — credit_user_xp policy blocks server writes. The deployed
-- credit_user_xp has two client-safety guards (reject battle_win /
-- battle_refund reasons from clients, reject any cross-user target).
-- Both fire even under SECURITY DEFINER because they read auth.uid().
-- Every pipeline function that credits a WINNER or refunds a
-- NON-CALLER is broken: settle_stake_battle, settle_daily_battle,
-- reject_battle_invite. Introduce _credit_xp_admin: writes profiles +
-- xp_ledger directly, bypasses credit_user_xp. Not granted to
-- authenticated — server-only helper.
--
-- BUG 3 — leave-lobby refund broken. refund_participant_stake (from
-- migration 0042) internally calls credit_user_xp('battle_refund') —
-- same policy block. Rewritten here to write direct.
--
-- Also includes a one-shot backfill: every completed stake battle whose
-- xp_ledger has no battle_win/battle_refund row gets re-run through
-- settle_stake_battle so pending winners retroactively receive pot.
--
-- HOW TO APPLY: Dashboard → SQL Editor → paste → Run. Idempotent.
-- =============================================================================

-- 1. Server-only XP credit helper --------------------------------------------
create or replace function public._credit_xp_admin(
  p_user_id uuid,
  p_delta   integer,
  p_reason  text,
  p_context jsonb default null
) returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_new_bal bigint;
begin
  update public.profiles
     set total_xp = greatest(0, coalesce(total_xp, 0) + p_delta)
   where id = p_user_id
   returning total_xp into v_new_bal;
  if v_new_bal is null then
    raise notice '_credit_xp_admin: profile % not found', p_user_id;
    return null;
  end if;
  insert into public.xp_ledger
    (user_id, delta, reason, context, balance_after)
  values (p_user_id, p_delta, p_reason, p_context, v_new_bal);
  return v_new_bal;
end;
$$;

revoke all on function public._credit_xp_admin(uuid, integer, text, jsonb) from public;
-- Deliberately NOT granted to authenticated — server-only.

-- 2. settle_stake_battle — reroute XP credits through _credit_xp_admin -------
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
  if v_battle.id is null then return; end if;
  v_stake := coalesce(v_battle.stake_xp, 0);

  select coalesce(sum(v_stake), 0) into v_total_pot
    from public.battle_participants
   where battle_id = p_battle_id
     and stake_paid = true
     and invite_status = 'accepted';

  if v_battle.type = 'team' then
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
             count(*) filter (
               where steps = (select max(steps) from team_totals)
             ) over () as tie_count
        from team_totals
    )
    select team_label into v_winning_team
      from ranked where rk = 1 and tie_count = 1 limit 1;

    if v_winning_team is null then
      for v_participant in
        select user_id from public.battle_participants
         where battle_id = p_battle_id and stake_paid = true
      loop
        perform public._credit_xp_admin(
          v_participant.user_id, v_stake, 'battle_refund',
          jsonb_build_object('battle_id', p_battle_id, 'reason', 'team_tie')
        );
      end loop;
      return;
    end if;

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
      perform public._credit_xp_admin(
        v_participant.user_id, v_share::integer, 'battle_win',
        jsonb_build_object('battle_id', p_battle_id, 'pot', v_total_pot,
                           'winning_team', v_winning_team)
      );
      update public.battle_participants
         set is_winner = true
       where battle_id = p_battle_id and user_id = v_participant.user_id;
    end loop;
  else
    with ranked as (
      select user_id, current_steps,
             rank() over (order by current_steps desc) as rk,
             count(*) over () as n
        from public.battle_participants
       where battle_id = p_battle_id
         and invite_status = 'accepted'
    ),
    top as (select user_id from ranked where rk = 1)
    select case
      when (select count(*) from top) = 1 then (select user_id from top)
      else null
    end into v_winner_user_id;

    if v_winner_user_id is null then
      for v_participant in
        select user_id from public.battle_participants
         where battle_id = p_battle_id and stake_paid = true
      loop
        perform public._credit_xp_admin(
          v_participant.user_id, v_stake, 'battle_refund',
          jsonb_build_object('battle_id', p_battle_id, 'reason', 'tie')
        );
      end loop;
      return;
    end if;

    perform public._credit_xp_admin(
      v_winner_user_id, v_total_pot::integer, 'battle_win',
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

-- 3. settle_daily_battle — same reroute -------------------------------------
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
    perform public._credit_xp_admin(
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
      perform public._credit_xp_admin(
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
      perform public._credit_xp_admin(
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

-- 4. reject_battle_invite — reroute the creator refund credit ---------------
create or replace function public.reject_battle_invite(
  p_battle_id uuid,
  p_user_id   uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_type          text;
  v_status        text;
  v_stake_xp      integer;
  v_created_by    uuid;
  v_my_status     text;
  r               record;
begin
  if auth.uid() is null or auth.uid() <> p_user_id then
    raise exception 'not_authorized: rejecter must match caller';
  end if;

  select b.type, b.status, coalesce(b.stake_xp, 0), b.created_by
    into v_type, v_status, v_stake_xp, v_created_by
    from public.battles b
   where b.id = p_battle_id;
  if v_type is null then raise exception 'battle_not_found: %', p_battle_id; end if;
  if v_status <> 'pending' then return; end if;

  select bp.invite_status into v_my_status
    from public.battle_participants bp
   where bp.battle_id = p_battle_id and bp.user_id = p_user_id;
  if v_my_status is null or v_my_status <> 'pending' then return; end if;

  update public.battle_participants
     set invite_status = 'rejected'
   where battle_id = p_battle_id and user_id = p_user_id;

  if v_type = '1v1' then
    update public.battles set status = 'cancelled' where id = p_battle_id;

    if v_stake_xp > 0 then
      for r in
        select user_id from public.battle_participants
         where battle_id = p_battle_id and stake_paid = true
      loop
        perform public._credit_xp_admin(
          r.user_id, v_stake_xp, 'battle_refund',
          jsonb_build_object('battle_id', p_battle_id, 'trigger', 'invitee_rejected')
        );
        update public.battle_participants
           set stake_paid = false
         where battle_id = p_battle_id and user_id = r.user_id;
      end loop;
    end if;

    if v_created_by <> p_user_id then
      insert into public.notifications (user_id, type, title, body, data)
      values (v_created_by, 'battle_rejected', 'Battle Declined',
              'Your opponent declined the battle',
              jsonb_build_object('battle_id', p_battle_id, 'from_user_id', p_user_id));
    end if;
  end if;
end;
$$;

revoke all on function public.reject_battle_invite(uuid, uuid) from public;
grant execute on function public.reject_battle_invite(uuid, uuid) to authenticated;

-- 5. process_battle_lifecycle — restore 0018's stake branch ------------------
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
  v_stake              integer;
  v_winner_after_settle uuid;
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

  for b in
    select id from public.battles
     where status = 'active' and series_id is not null
  loop
    perform public.settle_daily_battle(b.id);
  end loop;

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

    v_stake := coalesce(b.stake_xp, 0);

    -- STAKE BRANCH (restored from 0018) — delegate pot payout / refund.
    if v_stake > 0 then
      update public.battle_participants bp
      set end_steps_baseline = pr.total_steps_all_time
      from public.profiles pr
      where bp.battle_id = b.id and bp.user_id = pr.id;

      perform public.settle_stake_battle(b.id);
      update public.battles set status = 'completed' where id = b.id;

      select winner_id into v_winner_after_settle
        from public.battles where id = b.id;
      insert into public.notifications (user_id, type, title, body, data)
      select bp.user_id, 'battle_result', 'Battle Ended',
        case when bp.is_winner then 'You won! Pot credited to your XP.'
             else 'Battle ended — better luck next time' end,
        jsonb_build_object('battle_id', b.id, 'winner_id', v_winner_after_settle,
                           'stake_xp', v_stake)
        from public.battle_participants bp
       where bp.battle_id = b.id and bp.invite_status = 'accepted';
      continue;
    end if;

    -- Legacy free-play (stake_xp = 0) — award_xp path preserved.
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

-- 6. refund_participant_stake — write direct ---------------------------------
create or replace function public.refund_participant_stake(
  p_battle_id uuid, p_user_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_stake   int;
  v_paid    boolean;
  v_new_bal bigint;
begin
  if auth.uid() is null or auth.uid() <> p_user_id then
    raise exception 'not_authorized: caller must match participant';
  end if;

  select coalesce(b.stake_xp, 0), coalesce(bp.stake_paid, false)
    into v_stake, v_paid
    from public.battles b
    join public.battle_participants bp
      on bp.battle_id = b.id and bp.user_id = p_user_id
   where b.id = p_battle_id;
  if v_stake is null then raise exception 'battle_or_participant_not_found'; end if;

  update public.battle_participants
     set invite_status = 'rejected', stake_paid = false
   where battle_id = p_battle_id and user_id = p_user_id;

  if v_paid and v_stake > 0 then
    perform public._credit_xp_admin(
      p_user_id, v_stake, 'battle_refund',
      jsonb_build_object('battle_id', p_battle_id, 'reason', 'participant_left')
    );
  end if;

  update public.battle_series_participants sp
     set status = 'dropped_out', dropped_at = now(), drop_reason = 'user_left'
    from public.battles b
   where b.id = p_battle_id
     and sp.series_id = b.series_id
     and sp.user_id = p_user_id;
end;
$$;

revoke all on function public.refund_participant_stake(uuid, uuid) from public;
grant execute on function public.refund_participant_stake(uuid, uuid) to authenticated;

-- 7. Backfill — retroactively pay out every completed stake battle whose
--    winner never got their credit under the broken pipeline.
do $$
declare b_rec record;
begin
  for b_rec in
    select id from public.battles b
    where status = 'completed'
      and coalesce(stake_xp, 0) > 0
      and not exists (
        select 1 from public.xp_ledger l
        where l.reason in ('battle_win', 'battle_refund')
          and l.context->>'battle_id' = b.id::text
      )
  loop
    perform public.settle_stake_battle(b_rec.id);
  end loop;
end$$;
