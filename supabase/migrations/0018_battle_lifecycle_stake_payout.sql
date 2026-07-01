-- =============================================================================
-- StepBattle — Route process_battle_lifecycle through settle_stake_battle.
--
-- DEPENDS ON:
--   • migration 0016 (battles.stake_xp, battle_participants.stake_paid,
--     credit_user_xp).
--   • migration 0017 (settle_stake_battle).
--
-- WHAT CHANGES vs the existing function:
--   Section B (completion of `active` battles past their end_time + 90s grace)
--   now branches on stake_xp:
--
--     • stake_xp > 0  → delegate payout to settle_stake_battle(b.id), which
--                       picks winner(s), stamps is_winner, sets winner_id
--                       (for 1v1 / group only), and credits the XP ledger
--                       via credit_user_xp. We still freeze end_steps_baseline,
--                       flip status to 'completed', emit result notifications,
--                       and spawn the next series instance.
--
--     • stake_xp = 0  → exact legacy behaviour preserved. award_xp + mission
--                       bumping + tie handling unchanged so any pre-0016
--                       battles already in flight finish out cleanly.
--
-- NOTHING ELSE in the function changes — section 0 (wake pings), section A
-- (activate scheduled battles), and the daily-series spawn logic are byte-
-- for-byte the same as the pre-0018 version.
--
-- HOW TO APPLY: Dashboard → SQL Editor → paste → Run. Idempotent.
-- =============================================================================

create or replace function public.process_battle_lifecycle()
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
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
  v_series_status text;
  v_series_type   text;
  v_series_xp     integer;
  v_series_creator uuid;
  v_next_start    timestamptz;
  v_next_end      timestamptz;
  v_existing_next boolean;
  v_new_battle_id uuid;
  -- Team-battle scoring (migration 0015)
  v_winning_team    text;
  v_top_team_sum    bigint;
  v_team_tie        boolean;
  v_team_size       int;
  v_team_xp_per_member integer;
  -- Stake payout routing (migration 0018).
  v_stake               integer;
  v_winner_after_settle uuid;
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
      and end_time < now() - interval '90 seconds'
  loop
    -- Recompute each participant's score from total_steps_all_time so the
    -- result is correct even if the client never propagated current_steps.
    update public.battle_participants bp
    set current_steps = greatest(
          0,
          pr.total_steps_all_time
            - coalesce(bp.start_steps_baseline, pr.total_steps_all_time)
        )
    from public.profiles pr
    where bp.battle_id = b.id
      and bp.user_id = pr.id;

    v_stake := coalesce(b.stake_xp, 0);

    -- =========================================================================
    -- STAKE BATTLE BRANCH (migration 0018) — delegate to settle_stake_battle.
    -- =========================================================================
    if v_stake > 0 then
      -- Freeze end_steps_baseline. settle_stake_battle uses the
      -- just-recomputed current_steps; freezing AFTER that is fine.
      update public.battle_participants bp
      set end_steps_baseline = pr.total_steps_all_time
      from public.profiles pr
      where bp.battle_id = b.id
        and bp.user_id = pr.id;

      perform public.settle_stake_battle(b.id);

      update public.battles
      set status = 'completed'
      where id = b.id;

      -- Result notifications. For 1v1/group, settle_stake_battle stamps
      -- battles.winner_id. For team, it leaves winner_id null and uses
      -- battle_participants.is_winner per team member.
      select winner_id into v_winner_after_settle
        from public.battles where id = b.id;

      insert into public.notifications (user_id, type, title, body, data)
      select
        bp.user_id,
        'battle_result',
        'Battle Ended',
        case
          when bp.is_winner then 'You won! Pot credited to your XP.'
          else 'Battle ended — better luck next time'
        end,
        jsonb_build_object(
          'battle_id', b.id,
          'winner_id', v_winner_after_settle,
          'stake_xp', v_stake
        )
      from public.battle_participants bp
      where bp.battle_id = b.id
        and bp.invite_status = 'accepted';

      -- Daily-series recurrence (carry forward as before).
      if b.series_id is not null then
        select status, type, xp_reward, created_by
          into v_series_status, v_series_type, v_series_xp, v_series_creator
          from public.battle_series
          where id = b.series_id;

        if v_series_status = 'active' then
          v_next_start := b.end_time + interval '1 second';
          v_next_end   := v_next_start + interval '23 hours 59 minutes 59 seconds';

          select exists (
            select 1 from public.battles
            where series_id = b.series_id
              and start_time = v_next_start
          ) into v_existing_next;

          if not v_existing_next then
            -- Carry stake_xp forward so each daily instance is identical.
            insert into public.battles (
              type, status, start_time, end_time, xp_reward, created_by,
              series_id, stake_xp
            )
            values (
              v_series_type,
              'scheduled',
              v_next_start,
              v_next_end,
              v_series_xp,
              v_series_creator,
              b.series_id,
              v_stake
            )
            returning id into v_new_battle_id;

            insert into public.battle_participants (
              battle_id, user_id, display_name, avatar_url,
              current_steps, is_winner, invite_status
            )
            select
              v_new_battle_id,
              sp.user_id,
              sp.display_name,
              sp.avatar_url,
              0,
              false,
              'accepted'
            from public.battle_series_participants sp
            where sp.series_id = b.series_id;
          end if;
        end if;
      end if;

      -- Skip the legacy individual / team scoring path below.
      continue;
    end if;

    -- =========================================================================
    -- LEGACY (stake_xp = 0) — preserves pre-0018 behaviour byte-for-byte.
    -- =========================================================================

    -- ===========================================================================
    -- TEAM BATTLE BRANCH — winner is a TEAM_LABEL, not a single user.
    -- ===========================================================================
    if b.type = 'team' then
      v_winning_team := null;
      v_top_team_sum := -1;
      v_team_tie := false;

      for p in
        select team_label, sum(current_steps) as team_sum
        from public.battle_participants
        where battle_id = b.id
          and invite_status = 'accepted'
          and team_label is not null
        group by team_label
      loop
        if p.team_sum > v_top_team_sum then
          v_top_team_sum := p.team_sum;
          v_winning_team := p.team_label;
          v_team_tie := false;
        elsif p.team_sum = v_top_team_sum then
          v_team_tie := true;
        end if;
      end loop;
      if v_team_tie or v_top_team_sum <= 0 then
        v_winning_team := null;
      end if;

      update public.battle_participants bp
      set end_steps_baseline = pr.total_steps_all_time,
          is_winner = (v_winning_team is not null
                       and bp.team_label = v_winning_team)
      from public.profiles pr
      where bp.battle_id = b.id
        and bp.user_id = pr.id;

      update public.battles
      set status = 'completed', winner_id = null
      where id = b.id;

      if v_winning_team is not null then
        select count(*) into v_team_size
        from public.battle_participants
        where battle_id = b.id
          and invite_status = 'accepted'
          and team_label = v_winning_team;

        v_team_xp_per_member := b.xp_reward * v_team_size;

        for p in
          select user_id
          from public.battle_participants
          where battle_id = b.id
            and invite_status = 'accepted'
            and team_label = v_winning_team
        loop
          perform public.award_xp(p.user_id, v_team_xp_per_member);

          for m in select * from public.missions where category = 'battle' loop
            v_period := case when m.type = 'daily' then v_today else v_week end;

            select current_value, is_completed
            into v_prior, v_was
            from public.user_mission_progress
            where user_id = p.user_id
              and mission_id = m.id
              and period_start = v_period;

            v_prior := coalesce(v_prior, 0);
            v_was := coalesce(v_was, false);
            v_new := v_prior + 1;
            v_done := v_new >= m.target_value;

            insert into public.user_mission_progress
              (user_id, mission_id, period_start, current_value,
               target_value, is_completed, completed_at)
            values
              (p.user_id, m.id, v_period, v_new, m.target_value, v_done,
               case when v_done then now() else null end)
            on conflict (user_id, mission_id, period_start) do update
            set current_value = excluded.current_value,
                is_completed = public.user_mission_progress.is_completed
                               or excluded.is_completed,
                completed_at = coalesce(public.user_mission_progress.completed_at,
                                         excluded.completed_at);

            if v_done and not v_was then
              perform public.award_xp(p.user_id, m.xp_reward);
            end if;
          end loop;
        end loop;
      end if;

      insert into public.notifications (user_id, type, title, body, data)
      select
        bp.user_id,
        'battle_result',
        'Battle Ended',
        case
          when v_winning_team is null then 'Team battle ended in a tie'
          when bp.team_label = v_winning_team then
            'Your team won! +' || v_team_xp_per_member || ' XP'
          else 'Team battle ended — better luck next time'
        end,
        jsonb_build_object('battle_id', b.id,
                           'winning_team', v_winning_team)
      from public.battle_participants bp
      where bp.battle_id = b.id
        and bp.invite_status = 'accepted';

      continue;
    end if;

    -- ===========================================================================
    -- INDIVIDUAL BATTLE PATH (1v1 / group) — legacy free path.
    -- ===========================================================================
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
            is_completed = public.user_mission_progress.is_completed or excluded.is_completed,
            completed_at = coalesce(public.user_mission_progress.completed_at, excluded.completed_at);

        if v_done and not v_was then
          perform public.award_xp(v_winner, m.xp_reward);
        end if;
      end loop;
    end if;

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

    -- =========================================================================
    -- DAILY RECURRENCE — preserved from pre-0018 (legacy path).
    -- =========================================================================
    if b.series_id is not null then
      select status, type, xp_reward, created_by
        into v_series_status, v_series_type, v_series_xp, v_series_creator
        from public.battle_series
        where id = b.series_id;

      if v_series_status = 'active' then
        v_next_start := b.end_time + interval '1 second';
        v_next_end   := v_next_start + interval '23 hours 59 minutes 59 seconds';

        select exists (
          select 1 from public.battles
          where series_id = b.series_id
            and start_time = v_next_start
        ) into v_existing_next;

        if not v_existing_next then
          insert into public.battles (
            type, status, start_time, end_time, xp_reward, created_by, series_id
          )
          values (
            v_series_type,
            'scheduled',
            v_next_start,
            v_next_end,
            v_series_xp,
            v_series_creator,
            b.series_id
          )
          returning id into v_new_battle_id;

          insert into public.battle_participants (
            battle_id, user_id, display_name, avatar_url,
            current_steps, is_winner, invite_status
          )
          select
            v_new_battle_id,
            sp.user_id,
            sp.display_name,
            sp.avatar_url,
            0,
            false,
            'accepted'
          from public.battle_series_participants sp
          where sp.series_id = b.series_id;
        end if;
      end if;
    end if;
  end loop;
end;
$function$;

-- =============================================================================
-- After applying:
--   • New battles created via the updated app (which sets stake_xp ≥ 100) will
--     pay out through settle_stake_battle on completion — full pot split among
--     winners, refund on tie.
--   • Any battle still in flight with stake_xp = 0 (created before the client
--     update) continues to use award_xp + the missions bump exactly as before.
--   • The advisory lock is unchanged, so re-running this migration while a
--     lifecycle pass is in flight is safe.
-- =============================================================================
