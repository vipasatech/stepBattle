-- =============================================================================
-- StepBattle — XP economy + new onboarding fields.
--
-- NEW CONCEPTS
--   • profiles.date_of_birth / gender / fitness_level
--       Captured in the redesigned mandatory onboarding. Drive the
--       personalized step-goal formula (see lib/services/goal_formula.dart).
--
--   • Streak recovery (one-shot per streak)
--       streak_recovery_started_at + streak_used_recovery_in_current_run
--       implement the "miss-1-day → make-up-next-2-days" rule. After a
--       recovery is consumed in the current streak run, the next miss
--       ends the streak immediately. A fresh streak (=1) resets the flag.
--
--   • last_streak_milestone_awarded
--       Tracks the highest streak length we've already credited a +100
--       milestone XP for. Milestones land at day 25, 50, 75, 100, … so
--       we only credit when current_streak crosses a 25-multiple AND
--       it's higher than last_streak_milestone_awarded.
--
--   • Battles now WAGER XP
--       battles.stake_xp is the per-participant XP cost to join. Each
--       participant's stake is deducted on accept and refunded on
--       cancel; the winning side splits the total pot.
--       battle_participants.stake_paid tracks deduction so a re-accept
--       doesn't double-charge.
--
--   • Clans have their own XP treasury (clans.clan_xp)
--       Funded by clan-battle winnings + a flat +100 per clan battle
--       played + captain-initiated Razorpay purchase. The captain stakes
--       FROM the treasury when creating a clan battle.
--
--   • Append-only XP ledgers (xp_ledger, clan_xp_ledger)
--       Audit trail of every XP delta. SECURITY DEFINER functions
--       (credit_user_xp / credit_clan_xp) are the only legitimate
--       writers — RLS prevents direct INSERT from the client.
--
--   • Razorpay purchases (xp_purchases, clan_xp_purchases)
--       Receipts created on order, captured by a Supabase Edge Function
--       after Razorpay webhook signature verification.
--
-- HOW TO APPLY: Dashboard → SQL Editor → paste this whole file → Run.
--               Safe to re-run (every statement uses IF NOT EXISTS or
--               CREATE OR REPLACE).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. profiles — onboarding survey fields + streak recovery state
-- -----------------------------------------------------------------------------
alter table public.profiles
  add column if not exists date_of_birth date,
  add column if not exists gender text,
  add column if not exists fitness_level text,
  add column if not exists streak_recovery_started_at date,
  add column if not exists streak_used_recovery_in_current_run boolean not null default false,
  add column if not exists last_streak_milestone_awarded integer not null default 0;

-- Add the check constraints separately so we can drop+add on re-run.
alter table public.profiles
  drop constraint if exists profiles_gender_check;
alter table public.profiles
  add constraint profiles_gender_check
  check (gender is null or gender in ('man','woman','non_binary','prefer_not_to_say'));

alter table public.profiles
  drop constraint if exists profiles_fitness_level_check;
alter table public.profiles
  add constraint profiles_fitness_level_check
  check (fitness_level is null or fitness_level in ('beginner','intermediate','advanced','pro'));

-- -----------------------------------------------------------------------------
-- 2. clans — separate Clan XP treasury
-- -----------------------------------------------------------------------------
alter table public.clans
  add column if not exists clan_xp bigint not null default 0;

-- Powers the Clan XP leaderboard (Ranks tab → Clans sub-toggle).
create index if not exists clans_clan_xp_idx on public.clans (clan_xp desc);

-- -----------------------------------------------------------------------------
-- 3. battles — per-participant XP stake
-- -----------------------------------------------------------------------------
alter table public.battles
  add column if not exists stake_xp integer not null default 0;

-- Tracks whether we've already deducted this participant's stake. Prevents
-- double-charging on re-accept / cron retry / network blip.
alter table public.battle_participants
  add column if not exists stake_paid boolean not null default false;

-- -----------------------------------------------------------------------------
-- 4. clan_battles — stake paid FROM the clan treasury, not from members
-- -----------------------------------------------------------------------------
alter table public.clan_battles
  add column if not exists stake_clan_xp integer not null default 0;

-- -----------------------------------------------------------------------------
-- 5. xp_ledger — append-only audit log of every XP delta
-- -----------------------------------------------------------------------------
create table if not exists public.xp_ledger (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users(id) on delete cascade,
  delta         integer not null,
  reason        text not null check (reason in (
                  'daily_mission',     -- +100 per met daily target
                  'streak_milestone',  -- +100 per 25-day streak milestone
                  'battle_stake',      -- -X on accept (deduction)
                  'battle_win',        -- +pot/winners on completion
                  'battle_refund',     -- +X on cancel
                  'purchase',          -- +X on Razorpay capture
                  'admin_adjust'       -- escape hatch for manual fixes
                )),
  context       jsonb,
  balance_after bigint not null,
  created_at    timestamptz not null default now()
);

create index if not exists xp_ledger_user_idx
  on public.xp_ledger (user_id, created_at desc);
create index if not exists xp_ledger_reason_idx
  on public.xp_ledger (reason, created_at desc);

alter table public.xp_ledger enable row level security;

drop policy if exists "xp_ledger_read_own" on public.xp_ledger;
create policy "xp_ledger_read_own"
  on public.xp_ledger for select to authenticated
  using (user_id = auth.uid());
-- No INSERT / UPDATE / DELETE policy for authenticated → only SECURITY
-- DEFINER functions below can write.

-- -----------------------------------------------------------------------------
-- 6. clan_xp_ledger — same shape, but scoped to clans
-- -----------------------------------------------------------------------------
create table if not exists public.clan_xp_ledger (
  id                    uuid primary key default gen_random_uuid(),
  clan_id               uuid not null references public.clans(id) on delete cascade,
  delta                 integer not null,
  reason                text not null check (reason in (
                          'battle_stake',
                          'battle_win',
                          'battle_played',  -- the +100 per member per battle (rolled up at clan level too)
                          'battle_refund',
                          'purchase',
                          'admin_adjust'
                        )),
  context               jsonb,
  balance_after         bigint not null,
  triggered_by_user_id  uuid references auth.users(id),
  created_at            timestamptz not null default now()
);

create index if not exists clan_xp_ledger_clan_idx
  on public.clan_xp_ledger (clan_id, created_at desc);

alter table public.clan_xp_ledger enable row level security;

drop policy if exists "clan_xp_ledger_read_members" on public.clan_xp_ledger;
create policy "clan_xp_ledger_read_members"
  on public.clan_xp_ledger for select to authenticated
  using (exists (
    select 1 from public.clan_members
    where clan_members.clan_id = clan_xp_ledger.clan_id
      and clan_members.user_id = auth.uid()
  ));

-- -----------------------------------------------------------------------------
-- 7. xp_purchases — Razorpay personal-XP receipts
-- -----------------------------------------------------------------------------
create table if not exists public.xp_purchases (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references auth.users(id) on delete cascade,
  amount_inr          integer not null check (amount_inr > 0),
  xp_credited         integer not null check (xp_credited >= 0),
  razorpay_order_id   text not null,
  razorpay_payment_id text,
  razorpay_signature  text,
  status              text not null default 'created'
                        check (status in ('created','captured','failed','refunded')),
  failure_reason      text,
  created_at          timestamptz not null default now(),
  captured_at         timestamptz,
  refunded_at         timestamptz
);

create unique index if not exists xp_purchases_razorpay_order_uniq
  on public.xp_purchases (razorpay_order_id);

alter table public.xp_purchases enable row level security;

drop policy if exists "xp_purchases_read_own" on public.xp_purchases;
create policy "xp_purchases_read_own"
  on public.xp_purchases for select to authenticated
  using (user_id = auth.uid());

drop policy if exists "xp_purchases_insert_own" on public.xp_purchases;
create policy "xp_purchases_insert_own"
  on public.xp_purchases for insert to authenticated
  with check (user_id = auth.uid() and status = 'created');
-- Status transitions (created → captured/failed/refunded) happen only via the
-- Edge Function, which uses the service role and bypasses RLS.

-- -----------------------------------------------------------------------------
-- 8. clan_xp_purchases — Razorpay clan-treasury top-ups
-- -----------------------------------------------------------------------------
create table if not exists public.clan_xp_purchases (
  id                  uuid primary key default gen_random_uuid(),
  clan_id             uuid not null references public.clans(id) on delete cascade,
  paid_by_user_id     uuid not null references auth.users(id),
  amount_inr          integer not null check (amount_inr > 0),
  clan_xp_credited    integer not null check (clan_xp_credited >= 0),
  razorpay_order_id   text not null,
  razorpay_payment_id text,
  razorpay_signature  text,
  status              text not null default 'created'
                        check (status in ('created','captured','failed','refunded')),
  failure_reason      text,
  created_at          timestamptz not null default now(),
  captured_at         timestamptz,
  refunded_at         timestamptz
);

create unique index if not exists clan_xp_purchases_razorpay_order_uniq
  on public.clan_xp_purchases (razorpay_order_id);

alter table public.clan_xp_purchases enable row level security;

drop policy if exists "clan_xp_purchases_read_members" on public.clan_xp_purchases;
create policy "clan_xp_purchases_read_members"
  on public.clan_xp_purchases for select to authenticated
  using (exists (
    select 1 from public.clan_members
    where clan_members.clan_id = clan_xp_purchases.clan_id
      and clan_members.user_id = auth.uid()
  ));

drop policy if exists "clan_xp_purchases_insert_captain" on public.clan_xp_purchases;
create policy "clan_xp_purchases_insert_captain"
  on public.clan_xp_purchases for insert to authenticated
  with check (
    paid_by_user_id = auth.uid()
    and status = 'created'
    and exists (
      select 1 from public.clans c
      where c.id = clan_id and c.captain_id = auth.uid()
    )
  );

-- -----------------------------------------------------------------------------
-- 9. credit_user_xp(...) — SECURITY DEFINER, only legitimate writer
--    of profiles.total_xp + xp_ledger. Clamps total_xp at 0 (no negatives
--    even on a buggy multi-call).
-- -----------------------------------------------------------------------------
create or replace function public.credit_user_xp(
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
  v_new_balance bigint;
begin
  update public.profiles
  set    total_xp = greatest(0, total_xp + p_delta)
  where  id = p_user_id
  returning total_xp into v_new_balance;

  if v_new_balance is null then
    raise exception 'credit_user_xp: user % not found', p_user_id;
  end if;

  insert into public.xp_ledger (user_id, delta, reason, context, balance_after)
  values (p_user_id, p_delta, p_reason, p_context, v_new_balance);

  return v_new_balance;
end;
$$;

revoke all on function public.credit_user_xp(uuid, integer, text, jsonb) from public;
grant execute on function public.credit_user_xp(uuid, integer, text, jsonb) to authenticated;

-- -----------------------------------------------------------------------------
-- 10. credit_clan_xp(...) — same pattern for the clan treasury.
--     Caller passes p_triggered_by_user_id so the ledger row carries the
--     human who caused it (captain who staked, member whose battle just
--     ended, etc.).
-- -----------------------------------------------------------------------------
create or replace function public.credit_clan_xp(
  p_clan_id              uuid,
  p_delta                integer,
  p_reason               text,
  p_context              jsonb default null,
  p_triggered_by_user_id uuid  default null
) returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_new_balance bigint;
begin
  update public.clans
  set    clan_xp = greatest(0, clan_xp + p_delta)
  where  id = p_clan_id
  returning clan_xp into v_new_balance;

  if v_new_balance is null then
    raise exception 'credit_clan_xp: clan % not found', p_clan_id;
  end if;

  insert into public.clan_xp_ledger
    (clan_id, delta, reason, context, balance_after, triggered_by_user_id)
  values
    (p_clan_id, p_delta, p_reason, p_context, v_new_balance, p_triggered_by_user_id);

  return v_new_balance;
end;
$$;

revoke all on function public.credit_clan_xp(uuid, integer, text, jsonb, uuid) from public;
grant execute on function public.credit_clan_xp(uuid, integer, text, jsonb, uuid) to authenticated;

-- =============================================================================
-- After applying:
--   • profiles → new columns visible; existing rows have NULL DOB/gender/fitness
--     (the "Complete your profile" sheet catches these on first launch).
--   • clans → all existing clans start with clan_xp = 0.
--   • Existing battles → stake_xp defaults to 0 (legacy battles are effectively
--     "free entry"). New battles created after the client update set stake_xp > 0.
--   • The cron `process_battle_lifecycle` will be updated in a follow-up migration
--     to call credit_user_xp / credit_clan_xp instead of awarding fixed XP.
-- =============================================================================
