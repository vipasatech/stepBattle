-- =============================================================================
-- Migration 0063: Route BOTH signup-grant paths through _credit_xp_admin
-- =============================================================================
--
-- SYMPTOM (reported 2026-10-18, testers): new users receive no signup
-- bonus. Client log:
--
--   signupBonus:rpcFailed
--   PostgrestException(message: credit_user_xp: reason signup_grant
--   not allowed for client callers, code: 42501, details: Forbidden)
--
-- ROOT CAUSE. The DEPLOYED credit_user_xp (drifted from migration 0016 —
-- hardened live, never captured in a migration) permits exactly ONE
-- reason for non-service_role callers:
--
--     if v_role <> 'service_role' then
--       ...
--       if p_reason <> 'battle_stake' then
--         raise exception 'credit_user_xp: reason % not allowed for
--           client callers', p_reason using errcode = '42501';
--
-- SECURITY DEFINER does NOT rescue callers: auth.role() reads the JWT
-- request setting, not the function owner, so it stays 'authenticated'
-- all the way down the call stack. Migration 0047 documents this exact
-- trap (lines 16-24) and 0045 (lines 35-39) records the previous round
-- of it for daily_mission / streak_milestone.
--
-- This is the THIRD time this guard has silently broken an XP path.
-- battle_win/battle_refund were rerouted in 0047; daily_mission/
-- streak_milestone in 0048. signup_grant was simply never rerouted —
-- so BOTH grant paths have been failing:
--
--   1. grant_signup_xp()       — AFTER INSERT trigger on profiles
--                                (migration 0020, 100 XP)
--   2. award_signup_bonus_v2() — onboarding RPC called by the client
--                                (live-only, never in a migration, 500 XP)
--
-- FIX. Point both at public._credit_xp_admin (migration 0047) — the
-- server-only helper that writes profiles + xp_ledger directly and is
-- deliberately NOT granted to `authenticated`. Both functions are
-- SECURITY DEFINER and owned by the admin role, so they inherit EXECUTE
-- on it. Same proven pattern 0048 used.
--
-- AMOUNT RECONCILIATION. The legacy trigger granted 100 XP while the
-- client constant and award_signup_bonus_v2 both use 500. Because each
-- path short-circuits on "does a signup_grant row already exist", a
-- user whose trigger fired first would be permanently capped at 100 and
-- the RPC would return 0. Both are set to 500 here so whichever path
-- wins the race grants the SAME, CORRECT amount exactly once.
--
-- Idempotency on both paths is unchanged: guard on
-- `exists(xp_ledger where user_id = ... and reason = 'signup_grant')`.
--
-- NOT TOUCHED: credit_user_xp itself. Loosening its allowlist would
-- re-open the client-side XP-minting hole those guards exist to close.
-- Rerouting server paths around it is the correct direction.
--
-- xp_ledger.reason CHECK already permits 'signup_grant' (verified
-- 2026-10-29) — no constraint migration needed.
--
-- HOW TO APPLY: Dashboard → SQL Editor → paste → Run. Idempotent.
-- BACKFILL for the 102 users already missed: SEPARATE migration 0064.
--   Apply 0063 first, confirm a FRESH signup now receives 500, and only
--   then run 0064.
-- =============================================================================

-- 1. Onboarding RPC — the primary path the client calls ----------------------
create or replace function public.award_signup_bonus_v2()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_already_granted boolean;
begin
  if v_user_id is null then raise exception 'not_authorized'; end if;

  select exists (
    select 1 from public.xp_ledger
    where user_id = v_user_id and reason = 'signup_grant'
  ) into v_already_granted;
  if v_already_granted then
    return 0;
  end if;

  -- CHANGED (0063): was public.credit_user_xp(...) → 42501 for every
  -- client caller. _credit_xp_admin performs the identical
  -- profiles + xp_ledger write without the client-caller allowlist.
  perform public._credit_xp_admin(
    v_user_id,
    500,
    'signup_grant',
    jsonb_build_object('source', 'onboarding_rpc_v2')
  );
  return 500;
end;
$$;

revoke all on function public.award_signup_bonus_v2() from public;
grant execute on function public.award_signup_bonus_v2() to authenticated;

-- 2. Legacy profile-INSERT trigger — same reroute, amount 100 → 500 ----------
create or replace function public.grant_signup_xp()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_already_granted boolean;
begin
  select exists (
    select 1 from public.xp_ledger
    where user_id = new.id and reason = 'signup_grant'
  ) into v_already_granted;
  if v_already_granted then
    return new;
  end if;

  -- CHANGED (0063): credit_user_xp → _credit_xp_admin, and 100 → 500
  -- so both grant paths agree on the amount.
  perform public._credit_xp_admin(
    new.id,
    500,
    'signup_grant',
    jsonb_build_object('source', 'profile_insert_trigger')
  );
  return new;
end;
$$;

revoke all on function public.grant_signup_xp() from public;

-- Trigger itself is unchanged (migration 0020) — re-asserted for safety.
drop trigger if exists profiles_signup_grant on public.profiles;
create trigger profiles_signup_grant
  after insert on public.profiles
  for each row
  execute function public.grant_signup_xp();

-- =============================================================================
-- Verification
-- =============================================================================
--
-- 1. Both functions now CALL _credit_xp_admin and NOT credit_user_xp.
--
--   ⚠️ pg_get_functiondef() returns the body INCLUDING comments, and the
--   two `-- CHANGED (0063)` notes above both contain the literal string
--   "credit_user_xp". A naive `like '%credit_user_xp%'` therefore reports
--   a FALSE POSITIVE on a correctly-applied migration (hit 2026-10-30).
--   Strip comments before testing:
--
--   select proname,
--          regexp_replace(pg_get_functiondef(oid), '--[^\n]*', '', 'g')
--            ~ 'public\._credit_xp_admin'  as calls_admin,
--          regexp_replace(pg_get_functiondef(oid), '--[^\n]*', '', 'g')
--            ~ 'public\.credit_user_xp'    as calls_client
--   from pg_proc
--   where pronamespace = 'public'::regnamespace
--     and proname in ('award_signup_bonus_v2','grant_signup_xp');
--
--   Expect: calls_admin = true, calls_client = false, for BOTH rows.
--
-- 2. Live end-to-end check — sign up a brand-new account, complete
--    onboarding, then:
--
--   select user_id, delta, reason, balance_after, created_at
--   from public.xp_ledger
--   where reason = 'signup_grant'
--   order by created_at desc
--   limit 5;
--
--   Expect the new user with delta = 500. The client should log
--   `signupBonus:credited {xp: 500}` instead of `signupBonus:rpcFailed`.
--
-- =============================================================================
-- Rollback
-- =============================================================================
--
-- Restores the pre-0063 (broken) bodies. Only useful if _credit_xp_admin
-- itself turns out to be the problem — otherwise rolling back simply
-- re-breaks the signup bonus.
--
--   create or replace function public.award_signup_bonus_v2() ... as $$
--     ... perform public.credit_user_xp(v_user_id, 500, 'signup_grant', ...);
--   $$;
--   create or replace function public.grant_signup_xp() ... as $$
--     ... perform public.credit_user_xp(new.id, 100, 'signup_grant', ...);
--   $$;
--
-- No data is modified by 0063, so rollback is non-destructive.
-- =============================================================================
