-- =============================================================================
-- StepBattle — Monthly leaderboard top-1 XP awards.
--
-- Once a month, every user ranked #1 in any leaderboard scope (district,
-- state, country, worldwide) earns a bonus XP grant. The cron runs on
-- the 1st of every month at 00:10 UTC, evaluating the leaderboard as it
-- stood at the moment of the previous month's close.
--
-- Awards per user spec:
--   • Worldwide #1 → +500 XP
--   • Country  #1 → +250 XP
--   • State    #1 → +100 XP
--   • District #1 →  +50 XP
--
-- Tie handling: if two users are tied for #1 (same total_xp), BOTH
-- receive the full award. This matches the user's explicit request
-- ("both get full XP").
--
-- A user who tops MULTIPLE scopes (e.g. #1 in their district AND in the
-- country AND worldwide) receives all four awards stacked — 500 + 250 +
-- 100 + 50 = 900 XP for that month. Top dog wins big.
--
-- IDEMPOTENCY: a single `leaderboard_top` ledger entry per scope per
-- month per user. Re-running for the same period is a no-op. The
-- (user_id, reason, context->>'period') combination is checked before
-- crediting.
--
-- DEPENDS ON: migration 0016 (credit_user_xp), migration 0020
-- (which already adds 'leaderboard_top' to xp_ledger.reason check).
-- HOW TO APPLY: Dashboard → SQL Editor → paste → Run. Idempotent.
-- =============================================================================

-- 1. Award a single user for a single scope. Idempotent per
--    (user, scope, period). Returns true if credited, false if
--    skipped due to existing grant.
create or replace function public.award_leaderboard_top(
  p_user_id uuid,
  p_scope   text,         -- 'worldwide' | 'country' | 'state' | 'district'
  p_period  text,         -- 'YYYY-MM' for the month closed (e.g. '2026-06')
  p_xp      integer,
  p_context jsonb default null
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing boolean;
begin
  -- Already credited for this user/scope/period?
  select exists (
    select 1 from public.xp_ledger
    where user_id = p_user_id
      and reason = 'leaderboard_top'
      and context->>'period' = p_period
      and context->>'scope'  = p_scope
  ) into v_existing;
  if v_existing then return false; end if;

  perform public.credit_user_xp(
    p_user_id,
    p_xp,
    'leaderboard_top',
    coalesce(p_context, '{}'::jsonb)
      || jsonb_build_object(
        'scope',  p_scope,
        'period', p_period
      )
  );
  return true;
end;
$$;

revoke all on function public.award_leaderboard_top(uuid, text, text, integer, jsonb) from public;
grant execute on function public.award_leaderboard_top(uuid, text, text, integer, jsonb) to service_role;

-- 2. Monthly sweep — runs once per month from pg_cron. For each scope,
--    finds the top total_xp value and credits every user tied at that
--    value. Tie-aware (multiple #1 users all win).
create or replace function public.run_monthly_leaderboard_sweep()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now    timestamptz := now() at time zone 'UTC';
  -- The PREVIOUS month — sweep grants the month that just closed.
  v_period text := to_char(v_now - interval '1 month', 'YYYY-MM');
  v_top_xp bigint;
  v_user_id uuid;
  v_district text;
  v_state text;
  v_country text;
begin
  -- ────────────────────────── Worldwide (+500) ──────────────────────────
  select max(total_xp) into v_top_xp from public.profiles where total_xp > 0;
  if v_top_xp is not null and v_top_xp > 0 then
    for v_user_id in
      select id from public.profiles where total_xp = v_top_xp
    loop
      perform public.award_leaderboard_top(
        v_user_id, 'worldwide', v_period, 500, null
      );
    end loop;
  end if;

  -- ────────────────────────── Per-country (+250) ────────────────────────
  for v_country in
    select distinct country_code
      from public.profiles
     where country_code is not null and country_code <> ''
  loop
    select max(total_xp) into v_top_xp
      from public.profiles
     where country_code = v_country and total_xp > 0;
    if v_top_xp is null or v_top_xp <= 0 then continue; end if;
    for v_user_id in
      select id from public.profiles
       where country_code = v_country and total_xp = v_top_xp
    loop
      perform public.award_leaderboard_top(
        v_user_id, 'country', v_period, 250,
        jsonb_build_object('country_code', v_country)
      );
    end loop;
  end loop;

  -- ────────────────────────── Per-state (+100) ──────────────────────────
  for v_state in
    select distinct state_name
      from public.profiles
     where state_name is not null and state_name <> ''
  loop
    select max(total_xp) into v_top_xp
      from public.profiles
     where state_name = v_state and total_xp > 0;
    if v_top_xp is null or v_top_xp <= 0 then continue; end if;
    for v_user_id in
      select id from public.profiles
       where state_name = v_state and total_xp = v_top_xp
    loop
      perform public.award_leaderboard_top(
        v_user_id, 'state', v_period, 100,
        jsonb_build_object('state_name', v_state)
      );
    end loop;
  end loop;

  -- ────────────────────────── Per-district (+50) ────────────────────────
  for v_district in
    select distinct district_name
      from public.profiles
     where district_name is not null and district_name <> ''
  loop
    select max(total_xp) into v_top_xp
      from public.profiles
     where district_name = v_district and total_xp > 0;
    if v_top_xp is null or v_top_xp <= 0 then continue; end if;
    for v_user_id in
      select id from public.profiles
       where district_name = v_district and total_xp = v_top_xp
    loop
      perform public.award_leaderboard_top(
        v_user_id, 'district', v_period, 50,
        jsonb_build_object('district_name', v_district)
      );
    end loop;
  end loop;
end;
$$;

revoke all on function public.run_monthly_leaderboard_sweep() from public;
grant execute on function public.run_monthly_leaderboard_sweep() to service_role;

-- 3. Schedule the monthly sweep — 1st of every month at 00:10 UTC.
do $$
begin
  if not exists (
    select 1 from cron.job where jobname = 'stepbattle_monthly_leaderboard'
  ) then
    perform cron.schedule(
      'stepbattle_monthly_leaderboard',
      '10 0 1 * *',
      $cmd$ select public.run_monthly_leaderboard_sweep(); $cmd$
    );
  end if;
end$$;

-- =============================================================================
-- After applying:
--   • On the 1st of every month at 00:10 UTC, top-1 users in each scope
--     receive their bonus XP.
--   • Tied users all receive the full award.
--   • A user topping multiple scopes stacks awards (worldwide + country
--     + state + district = up to 900 XP).
--   • The notification system should pick up the ledger entries and
--     surface "+500 XP — #1 worldwide!" toasts to users on their next
--     app open. (Notification fanout from xp_ledger is a follow-up.)
-- =============================================================================
