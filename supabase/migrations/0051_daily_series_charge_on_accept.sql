-- =============================================================================
-- Migration 0051 — Auto-charge invitee stake on daily-series accept.
--
-- BUG (found 2026-08-20 by battle #9853):
--   • Laxmi created a daily-series 1v1 with 100 XP stake.
--   • Narsimlu accepted.
--   • Only Laxmi's stake was debited (pot = 100). Narsimlu's stake_paid
--     stayed false, so if he wins the settle_daily_battle payout hands
--     him only 100 XP (his stake was never in the pot) — he played for
--     free while Laxmi risked real XP.
--
-- ROOT CAUSE:
--   Client's acceptInvite in lib/services/battle_service.dart:502-512
--   returns EARLY on the daily-series branch after calling the RPC
--   accept_daily_series_invite, skipping the _chargeStake call that
--   fires on the non-daily-series branch. The RPC itself (deployed
--   from migration 0057, not in this repo) doesn't charge the invitee
--   either — hence stake_paid stays false forever.
--
-- FIX:
--   BEFORE-UPDATE trigger on battle_participants that catches ANY
--   invite_status transition to 'accepted' where the battle is a
--   daily-series battle with a positive stake AND the invitee hasn't
--   already paid. Trigger runs in the SAME transaction as whatever
--   updated invite_status (client OR RPC OR future admin path), so:
--     • no race window
--     • insufficient balance → RAISE EXCEPTION → whole accept aborts,
--       user sees clean "insufficient_xp" error, invite_status stays
--       pending
--     • RPC that already pre-charges the invitee → my trigger sees
--       stake_paid=true in NEW row and no-ops → no double-charge
--
--   Also backfills the current in-flight daily-series battles where an
--   invitee accepted but wasn't charged, so #9853 (and any others)
--   correct themselves at apply time.
--
-- HOW TO APPLY:
--   Dashboard → SQL Editor → paste → Run.
--   Verify with the queries at the end.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Trigger function.
-- -----------------------------------------------------------------------------
create or replace function public.daily_series_charge_on_accept()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_stake   int;
  v_balance bigint;
begin
  -- Fires when a battle_participants row transitions to invite_status =
  -- 'accepted' AND is unpaid. Passing the WHEN clause on the trigger
  -- itself already filters on invite_status change, so this body only
  -- runs for the interesting transitions.
  if TG_OP <> 'UPDATE' then return new; end if;
  if new.invite_status <> 'accepted' then return new; end if;
  if coalesce(old.invite_status, '') = 'accepted' then return new; end if;
  if coalesce(new.stake_paid, false) then return new; end if;

  -- Only for daily-series battles (b.series_id is not null) with a
  -- positive stake. Non-series stake battles use client-side
  -- _chargeStake — this trigger stays out of their way.
  select coalesce(b.stake_xp, 0) into v_stake
    from public.battles b
   where b.id = new.battle_id
     and b.series_id is not null
     and coalesce(b.stake_xp, 0) > 0;

  if v_stake is null or v_stake <= 0 then
    return new;  -- not a daily-series stake battle; nothing to do
  end if;

  -- Balance check. _credit_xp_admin's clamp-at-zero would silently
  -- eat a shortfall, so we enforce here and RAISE to abort the whole
  -- transaction (invite_status write rolls back too — user sees a
  -- clean error and stays in pending).
  select coalesce(total_xp, 0) into v_balance
    from public.profiles
   where id = new.user_id;

  if v_balance < v_stake then
    raise exception 'insufficient_xp: need % XP to accept daily-series battle, have %',
      v_stake, v_balance
      using errcode = 'P0001';
  end if;

  -- Charge the stake. _credit_xp_admin writes profiles.total_xp AND
  -- xp_ledger atomically (see migration 0047). Context payload
  -- includes the battle id so the ledger row is traceable.
  perform public._credit_xp_admin(
    new.user_id,
    -v_stake,
    'battle_stake',
    jsonb_build_object(
      'battle_id', new.battle_id,
      'via',       'daily_series_accept_trigger'
    )
  );

  -- Mark stake_paid inline — since this is a BEFORE trigger, the
  -- assignment lands in the row that gets persisted.
  new.stake_paid := true;

  return new;
end;
$$;

revoke all on function public.daily_series_charge_on_accept() from public;

drop trigger if exists daily_series_charge_on_accept_trigger
  on public.battle_participants;
create trigger daily_series_charge_on_accept_trigger
  before update on public.battle_participants
  for each row
  when (old.invite_status is distinct from new.invite_status)
  execute function public.daily_series_charge_on_accept();

-- -----------------------------------------------------------------------------
-- 2. One-shot backfill for battles already in flight where an invitee
-- accepted but wasn't charged. Fixes #9853 (Narsimlu) and any others
-- caught between the bug's existence and this migration.
--
-- Runs inline (not through the trigger) because these rows are ALREADY
-- invite_status=accepted, so a trigger wouldn't fire. Uses the same
-- balance-check + _credit_xp_admin path so behaviour is identical to
-- future accepts.
-- -----------------------------------------------------------------------------
do $$
declare
  bp_rec  record;
  v_stake int;
  v_balance bigint;
  v_charged int := 0;
  v_skipped int := 0;
begin
  for bp_rec in
    select bp.user_id, bp.battle_id, coalesce(b.stake_xp, 0) as stake
      from public.battle_participants bp
      join public.battles b on b.id = bp.battle_id
     where b.series_id is not null
       and b.status in ('active', 'scheduled')
       and coalesce(b.stake_xp, 0) > 0
       and bp.invite_status = 'accepted'
       and coalesce(bp.stake_paid, false) = false
  loop
    v_stake := bp_rec.stake;
    select coalesce(total_xp, 0) into v_balance
      from public.profiles where id = bp_rec.user_id;

    if v_balance >= v_stake then
      perform public._credit_xp_admin(
        bp_rec.user_id, -v_stake, 'battle_stake',
        jsonb_build_object(
          'battle_id', bp_rec.battle_id,
          'via',       'backfill_0051'
        )
      );
      update public.battle_participants
         set stake_paid = true
       where battle_id = bp_rec.battle_id and user_id = bp_rec.user_id;
      v_charged := v_charged + 1;
    else
      -- User doesn't have the balance to be retroactively charged. They
      -- get a free ride on THIS one battle; future accepts will fail
      -- cleanly via the trigger's RAISE. Log for the record.
      raise notice 'backfill: skipping uid=% battle=% (balance % < stake %)',
        bp_rec.user_id, bp_rec.battle_id, v_balance, v_stake;
      v_skipped := v_skipped + 1;
    end if;
  end loop;

  raise notice 'backfill 0051 done — charged=% skipped=%', v_charged, v_skipped;
end $$;

-- =============================================================================
-- Verify (run separately after the file above):
--
--   -- 1. Confirm the trigger is installed and enabled:
--        select tgname, tgtype, tgenabled
--          from pg_trigger
--         where tgname = 'daily_series_charge_on_accept_trigger';
--
--   -- 2. Confirm #9853's participants are both now stake_paid=true:
--        select bp.user_id, p.display_name, bp.stake_paid, bp.invite_status
--          from public.battle_participants bp
--          join public.profiles p on p.id = bp.user_id
--         where bp.battle_id = (
--           select id from public.battles
--            where series_id is not null and status = 'active'
--              and end_time > now() - interval '1 day'
--            order by created_at desc limit 1
--         );
--
--   -- 3. Confirm Narsimlu's ledger now has a battle_stake row:
--        select created_at, delta, reason, context, balance_after
--          from public.xp_ledger
--         where user_id = '73a6be48-0bc3-4def-99c6-af5e3ab7a454'
--           and reason = 'battle_stake'
--         order by created_at desc limit 1;
--
--   -- 4. Confirm future daily-series accepts will charge automatically:
--        (do this only from a fresh test daily-series invite + accept
--         with the client — the trigger will fire when the invitee's
--         invite_status flips to 'accepted'.)
-- =============================================================================
