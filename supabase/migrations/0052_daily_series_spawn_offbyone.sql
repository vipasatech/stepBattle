-- =============================================================================
-- Migration 0052 — Fix daily-series spawn day-skip + backfill in-flight
-- battle #6cc9 to today's date.
--
-- BUG (found 2026-08-21 via probes on Laxmi's series a9014af0):
--   Every daily-series battle spawned via settle_daily_battle skipped one
--   day between rollovers:
--     Thu Aug 20 (competed) → Sat Aug 22 (next competing_date, SKIP Fri)
--   Blast radius today = only Laxmi's series (only one currently using
--   per-user-local scoring; other series are pre-schema). But every
--   future daily series would hit the same skip on every rollover.
--
-- ROOT CAUSE (in the deployed settle_daily_battle spawn block):
--   v_next_local_date := (
--     ((now() at time zone 'utc') + make_interval(mins => tz_offset))::date + 1
--   )::text;
--
--   At settle moment (00:00 IST Aug 21 = 18:30 UTC Aug 20):
--     now() UTC        = 2026-08-20 18:30
--     + 330 min        = 2026-08-21 00:00      -- already tomorrow local
--     ::date           = 2026-08-21 (Fri)      -- CORRECT next day
--     + 1              = 2026-08-22 (Sat)      -- DOUBLE-ADD, skip Fri
--
--   The `+ 1` is a leftover from a pre-`user_local_end_utc` era when
--   settle fired the day BEFORE the settled battle's competing_date
--   ended. In the current model, settle fires AT the boundary, so
--   `now()` is already at day N+1 in local time — no `+ 1` needed.
--
-- FIX:
--   A. Rewrite v_next_local_date to increment the JUST-SETTLED battle's
--      competing_date by 1 day per-participant (deterministic — doesn't
--      depend on when cron fires). Fallback to current local date (no
--      +1) if the participant has no prev row (new joiner edge case).
--
--   B. Change end_time from `now() + interval '48 hours'` to
--      `max(user_local_end_utc(uid, next_date))` across all next-day
--      participants. This aligns the physical end_time with the actual
--      logical settle moment, so client countdowns show honest hours
--      (fixes the "1d 22h left" for a daily battle bug).
--
--   C. Backfill in-flight battle #6cc9 (Laxmi's series):
--      • competing_date: 2026-08-22 (Sat) → 2026-08-21 (Fri, today)
--      • end_time recomputed from max user_local_end_utc
--      Safe because both participants have 0 Friday steps at time of
--      backfill (verified via probes — battle activated at 01:04:53
--      IST, user is applying this within hours).
--
-- IMPACT ANALYSIS (per the "impact-analysis first" principle):
--   Touched:
--     • settle_daily_battle SQL function — spawn block only
--     • #6cc9's battle_participants.competing_date + battles.end_time
--   Verified NOT touched:
--     • accept_daily_series_invite RPC (Probe C source: no `+ 1`,
--       correct logic) — untouched.
--     • Non-daily battles — this function bails out early when
--       series_id is null.
--     • Older daily series (e207c8a2, b670d9c9) — Probe B showed they
--       have NULL competing_date on all rows, so their scoring path
--       doesn't intersect this function's per-user-local logic.
--     • Client code — no client change needed; reads competing_date +
--       end_time as-is. Backfilled values render honestly.
--     • user_local_end_utc() function — read-only, unchanged.
--   Preserved byte-for-byte:
--     • Steps 1-14 of settle_daily_battle (guards, scoring, winner
--       picking, pot payout, tie refund, status = completed,
--       notifications, series stop-if-<2). Only step 15 (spawn) changed.
--
-- HOW TO APPLY:
--   Dashboard → SQL Editor → paste this file → Run.
--   Verify with the queries at the bottom.
-- =============================================================================

create or replace function public.settle_daily_battle(p_battle_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
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
  -- Steps 1-14 (guards through active-tomorrow filter) — byte-for-byte
  -- unchanged from the deployed version. Only the spawn block at the
  -- end differs.
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

      update public.battle_participants set current_steps = v_steps
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
    update public.battle_participants set is_winner = true
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

  update public.battles set status = 'completed', winner_id = v_winner_uid
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
    update public.battle_series set status = 'stopped', stopped_at = now()
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

  -- =========================================================================
  -- CHANGE 0052: Spawn block — fixes both the competing_date +1 double-add
  -- and the mismatched end_time. Rest of function unchanged from CHANGE 0059.
  -- =========================================================================
  begin
    declare
      v_max_next_end_utc   timestamptz;
      v_participant_dates  jsonb := '{}'::jsonb;
      v_computed_date      text;
      v_this_end_utc       timestamptz;
    begin
      -- Pre-loop: per participant, compute their next competing_date +
      -- their logical settle timestamp. Track the max across all — that
      -- becomes the battle's end_time (the moment the LAST participant's
      -- day rolls over, so nobody's local day is cut short).
      for v_sp in
        select sp.user_id
          from public.battle_series_participants sp
         where sp.series_id = v_series.id
           and sp.user_id = ANY(v_active_tomorrow)
      loop
        -- Fix A: prev competing_date + 1. Deterministic — doesn't rely
        -- on when cron fires. Fallback (no prev row): current local
        -- date, no +1 add.
        v_computed_date := coalesce(
          (select (bp.competing_date::date + interval '1 day')::date::text
             from public.battle_participants bp
            where bp.battle_id = p_battle_id
              and bp.user_id = v_sp.user_id
              and bp.competing_date is not null
            limit 1),
          ((now() at time zone 'utc') + make_interval(mins => coalesce(
             (select tz_offset_minutes from public.profiles where id = v_sp.user_id),
             330)))::date::text
        );

        v_participant_dates := v_participant_dates
          || jsonb_build_object(v_sp.user_id::text, v_computed_date);

        v_this_end_utc := public.user_local_end_utc(v_sp.user_id, v_computed_date);
        if v_max_next_end_utc is null or v_this_end_utc > v_max_next_end_utc then
          v_max_next_end_utc := v_this_end_utc;
        end if;
      end loop;

      -- Fix B: end_time = max logical settle time. Falls back to +48h if
      -- for any reason user_local_end_utc returned NULL for everyone
      -- (paranoia — shouldn't happen given the pre-loop).
      -- join_code = NULL preserved from CHANGE 0059.
      insert into public.battles (
        type, status, start_time, end_time, xp_reward, stake_xp,
        created_by, series_id, visibility, join_code
      ) values (
        v_battle.type, 'active', now(),
        coalesce(v_max_next_end_utc, now() + interval '48 hours'),
        coalesce(v_battle.xp_reward, 0), v_stake,
        v_battle.created_by, v_battle.series_id,
        v_battle.visibility, NULL
      )
      returning id into v_new_battle_id;

      for v_sp in
        select sp.user_id, sp.display_name, sp.preferred_name, sp.avatar_url,
               coalesce(sp.battle_avatar_id, 'avatar_01') as battle_avatar_id
          from public.battle_series_participants sp
         where sp.series_id = v_series.id
           and sp.user_id = ANY(v_active_tomorrow)
      loop
        v_next_local_date := v_participant_dates->>v_sp.user_id::text;

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
  exception when others then
    raise notice 'settle_daily_battle:spawnFailed battle=% series=% sqlstate=% error=%',
      p_battle_id, v_series.id, SQLSTATE, SQLERRM;
    raise;
  end;
end;
$function$;

-- =============================================================================
-- Backfill in-flight battle #6cc9 (Laxmi's series) — pull competing_date
-- from Aug 22 (Sat) back to Aug 21 (Fri), recompute end_time.
--
-- Safe because at time of authoring (~01:07 IST Fri Aug 21) both users
-- have 0 Friday steps, so no retroactive score shifts. User is applying
-- this within hours of the diagnosis window.
-- =============================================================================

update public.battle_participants
   set competing_date = '2026-08-21'
 where battle_id = '6cc9cce4-0d4c-4aca-a659-f25b30f88b88'
   and invite_status = 'accepted';

update public.battles
   set end_time = (
     select max(public.user_local_end_utc(bp.user_id, bp.competing_date))
       from public.battle_participants bp
      where bp.battle_id = '6cc9cce4-0d4c-4aca-a659-f25b30f88b88'
        and bp.invite_status = 'accepted'
        and bp.competing_date is not null
   )
 where id = '6cc9cce4-0d4c-4aca-a659-f25b30f88b88';

-- =============================================================================
-- Verify (paste each block separately after applying the migration):
--
-- 1. Confirm #6cc9 now has today's competing_date + honest end_time:
--    select bp.user_id, p.display_name, bp.competing_date, b.end_time,
--           round(extract(epoch from (b.end_time - now())) / 3600.0, 1)
--             as hours_left
--      from public.battles b
--      join public.battle_participants bp on bp.battle_id = b.id
--      join public.profiles p on p.id = bp.user_id
--     where b.id = '6cc9cce4-0d4c-4aca-a659-f25b30f88b88';
--    Expect: competing_date = 2026-08-21, hours_left ≈ 22
--
-- 2. Confirm the function has the fix. Search for "Fix A" comment:
--    select substring(pg_get_functiondef(
--        'public.settle_daily_battle(uuid)'::regprocedure
--      ) from 'Fix A[^\n]*') as fix_marker;
--    Expect: a string containing "Fix A: prev competing_date + 1"
--
-- 3. Manual smoke test after the current battle settles tonight
--    (~00:00 Sat IST): confirm the NEW next-day battle has
--    competing_date = 2026-08-22 (Sat) with no skip:
--      select bp.user_id, bp.competing_date, b.start_time, b.end_time
--        from public.battles b
--        join public.battle_participants bp on bp.battle_id = b.id
--       where b.series_id = (
--         select series_id from public.battles
--          where id = '6cc9cce4-0d4c-4aca-a659-f25b30f88b88'
--       )
--       order by b.start_time desc;
-- =============================================================================
