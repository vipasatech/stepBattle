-- =============================================================================
-- StepBattle — Default 100 XP grant on signup.
--
-- Every user who completes onboarding (or just signs in for the first time)
-- gets seeded with 100 XP so the Buy XP / battle-stake UI isn't a hard wall
-- on first run. The amount is intentionally enough to enter one minimum-
-- stake (100 XP) battle.
--
-- IMPLEMENTATION:
--   • A trigger on `public.profiles AFTER INSERT` that fires
--     `credit_user_xp(NEW.id, 100, 'signup_grant', null)`.
--   • This runs inside the SECURITY DEFINER function so it bypasses RLS
--     and applies for every new profile regardless of how the row was
--     inserted (auth trigger, manual seed, admin import).
--   • Idempotent guard: we add `signup_grant` to the credit_user_xp
--     `p_reason` enum and check the xp_ledger for an existing
--     `signup_grant` row for that user before crediting — so re-running
--     the trigger (e.g. profile re-insert during migration replay) does
--     not double-credit.
--
-- BACKFILL: also credits 100 XP to every EXISTING user who has no prior
-- signup_grant ledger entry. Run-once safe — the guard skips users who
-- already received their grant.
--
-- DEPENDS ON: migration 0016 (which created credit_user_xp + xp_ledger).
-- HOW TO APPLY: Dashboard → SQL Editor → paste → Run. Idempotent.
-- =============================================================================

-- 1. Extend the xp_ledger.reason check to include 'signup_grant'. We
--    swap the constraint rather than alter it in-place because Postgres
--    can't ALTER an existing CHECK to widen its allowed set without
--    a drop-and-add.
alter table public.xp_ledger
  drop constraint if exists xp_ledger_reason_check;
alter table public.xp_ledger
  add constraint xp_ledger_reason_check
  check (reason in (
    'daily_mission',
    'streak_milestone',
    'battle_stake',
    'battle_win',
    'battle_refund',
    'purchase',
    'admin_adjust',
    'signup_grant',
    'leaderboard_top'  -- forward-compat for migration 0021 (monthly XP)
  ));

-- 2. The trigger function: credits 100 XP via the existing
--    credit_user_xp SECURITY DEFINER function. Idempotency check
--    ensures one grant per user, even if the profile row is re-inserted.
create or replace function public.grant_signup_xp()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_already_granted boolean;
begin
  -- Idempotency: skip if this user already has a signup_grant entry.
  select exists (
    select 1 from public.xp_ledger
    where user_id = new.id and reason = 'signup_grant'
  ) into v_already_granted;
  if v_already_granted then
    return new;
  end if;

  perform public.credit_user_xp(
    new.id,
    100,
    'signup_grant',
    jsonb_build_object('source', 'profile_insert_trigger')
  );
  return new;
end;
$$;

revoke all on function public.grant_signup_xp() from public;

-- 3. Attach the trigger. AFTER INSERT so the profile row exists before
--    we credit (credit_user_xp updates profiles.total_xp via UPDATE,
--    which requires the row to exist).
drop trigger if exists profiles_signup_grant on public.profiles;
create trigger profiles_signup_grant
  after insert on public.profiles
  for each row
  execute function public.grant_signup_xp();

-- 4. BACKFILL — give 100 XP to existing users who don't have a
--    signup_grant entry yet. Run-once safe via the same guard.
do $$
declare
  v_user_id uuid;
begin
  for v_user_id in
    select p.id
    from public.profiles p
    where not exists (
      select 1 from public.xp_ledger l
      where l.user_id = p.id and l.reason = 'signup_grant'
    )
  loop
    perform public.credit_user_xp(
      v_user_id,
      100,
      'signup_grant',
      jsonb_build_object('source', 'backfill_0020')
    );
  end loop;
end$$;
