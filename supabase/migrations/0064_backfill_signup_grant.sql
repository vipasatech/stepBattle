-- =============================================================================
-- Migration 0064: Backfill the signup bonus for users the 42501 bug skipped
-- =============================================================================
--
-- DEPENDS ON 0063. Do NOT run this until 0063 is applied AND a fresh
-- signup has been observed receiving 500 XP. If 0063 is wrong, this
-- migration multiplies the mistake across the whole user base.
--
-- SCOPE (measured 2026-10-29, before any fix):
--
--     total_users ... 140
--     got_bonus ....  38   (have a signup_grant ledger row)
--     owed_bonus ... 102   (have NO signup_grant row at all)
--
-- 102 of 140 users — 73% — never received the bonus they were promised,
-- because BOTH grant paths were raising 42501 (see 0063 for the full
-- root cause).
--
-- ⚠️ ECONOMIC IMPACT. 102 × 500 = 51,000 XP minted. XP is sold at
-- ₹1 = 1 XP (see Buy XP sheet), so this grants ~₹51,000 of in-app value
-- and WILL shift leaderboard standings, since profiles.total_xp drives
-- ranking. This is value users were already owed — but it is real, it is
-- irreversible in practice, and it should be a deliberate decision, not
-- an incidental side effect of a bug fix. Read section 1 before running
-- section 2.
--
-- HOW TO APPLY: Dashboard → SQL Editor. Run SECTION 1 (read-only) first
-- and eyeball the numbers. Only then run SECTION 2.
-- =============================================================================


-- =============================================================================
-- SECTION 1 — PRE-FLIGHT (read-only, changes nothing). RUN THIS FIRST.
-- =============================================================================

-- 1a. Cohort breakdown. The 38 "got_bonus" users are NOT uniform: the
--     legacy trigger granted 100 XP while the RPC grants 500, and each
--     path short-circuits on row EXISTENCE rather than amount. So some
--     users are sitting on a 100 XP grant that was meant to be 500.
select
  coalesce(l.delta, 0)  as grant_amount,
  count(*)              as users
from public.profiles p
left join public.xp_ledger l
  on l.user_id = p.id and l.reason = 'signup_grant'
group by coalesce(l.delta, 0)
order by grant_amount;

-- Expect roughly:
--     grant_amount |  users
--     -------------+-------
--                0 |   102   ← no grant at all   (SECTION 2a fixes)
--              100 |     n   ← legacy trigger    (SECTION 2b, OPTIONAL)
--              500 |     m   ← correct           (no action)
--   where n + m = 38.

-- 1b. Sanity: nobody should have MORE than one signup_grant row. If this
--     returns anything, STOP — the idempotency guards have been bypassed
--     somewhere and a backfill would compound it.
select user_id, count(*) as grant_rows, sum(delta) as total_granted
from public.xp_ledger
where reason = 'signup_grant'
group by user_id
having count(*) > 1;

-- Expect: zero rows.


-- =============================================================================
-- SECTION 2a — BACKFILL users with NO grant at all (the clear-cut 102)
-- =============================================================================
--
-- These users were promised 500 and received nothing. Idempotent: the
-- NOT EXISTS guard means re-running is a no-op. Uses _credit_xp_admin so
-- profiles.total_xp and xp_ledger stay consistent — never write one
-- without the other.

do $$
declare
  r record;
  v_count int := 0;
begin
  for r in
    select p.id
    from public.profiles p
    where not exists (
      select 1 from public.xp_ledger l
      where l.user_id = p.id and l.reason = 'signup_grant'
    )
  loop
    perform public._credit_xp_admin(
      r.id,
      500,
      'signup_grant',
      jsonb_build_object('source', 'backfill_0064')
    );
    v_count := v_count + 1;
  end loop;
  raise notice '0064 SECTION 2a: granted 500 XP to % users', v_count;
end $$;


-- =============================================================================
-- SECTION 2b — OPTIONAL top-up for legacy 100 XP grants
-- =============================================================================
--
-- ⚠️ POLICY DECISION, NOT A BUG FIX. Users credited by the pre-0063
-- trigger got 100 XP; the advertised bonus is 500. Topping them up to
-- parity costs 400 XP each and is arguably the fair outcome — but it is
-- a choice about your economy, so it is NOT run by default.
--
-- Leave this commented to ship parity-by-inaction; uncomment to equalise.
-- Writes reason 'signup_grant' so the idempotency guards keep holding,
-- with a distinct context source for auditability.

-- do $$
-- declare
--   r record;
--   v_count int := 0;
-- begin
--   for r in
--     select l.user_id
--     from public.xp_ledger l
--     where l.reason = 'signup_grant'
--     group by l.user_id
--     having sum(l.delta) = 100
--   loop
--     perform public._credit_xp_admin(
--       r.user_id,
--       400,
--       'signup_grant',
--       jsonb_build_object('source', 'backfill_0064_legacy_topup')
--     );
--     v_count := v_count + 1;
--   end loop;
--   raise notice '0064 SECTION 2b: topped up % legacy users by 400 XP', v_count;
-- end $$;


-- =============================================================================
-- Verification
-- =============================================================================
--
--   select
--     (select count(*) from public.profiles)                                as total_users,
--     (select count(*) from public.xp_ledger where reason = 'signup_grant') as grant_rows,
--     (select count(*) from public.profiles p
--        where not exists (select 1 from public.xp_ledger l
--                          where l.user_id = p.id and l.reason='signup_grant')) as still_owed;
--
--   Expect after 2a: still_owed = 0, grant_rows = total_users (140).
--
--   Ledger / balance consistency — every affected profile's total_xp must
--   match its ledger sum. Any row returned here is a real inconsistency:
--
--   select p.id, p.total_xp, coalesce(sum(l.delta),0) as ledger_sum
--   from public.profiles p
--   left join public.xp_ledger l on l.user_id = p.id
--   group by p.id, p.total_xp
--   having p.total_xp <> coalesce(sum(l.delta),0)
--   limit 20;
--
-- =============================================================================
-- Rollback
-- =============================================================================
--
-- Reverses ONLY this backfill, matched on the context source so genuine
-- grants are untouched. Debits total_xp by the same amount it credited.
--
--   do $$
--   declare r record;
--   begin
--     for r in
--       select user_id, delta from public.xp_ledger
--       where reason = 'signup_grant'
--         and context->>'source' in ('backfill_0064','backfill_0064_legacy_topup')
--     loop
--       update public.profiles
--          set total_xp = greatest(0, total_xp - r.delta)
--        where id = r.user_id;
--     end loop;
--     delete from public.xp_ledger
--      where reason = 'signup_grant'
--        and context->>'source' in ('backfill_0064','backfill_0064_legacy_topup');
--   end $$;
--
-- ⚠️ If users have already SPENT the backfilled XP on stakes or battles,
-- this clamps at 0 and their ledger will no longer reconcile. Rollback is
-- realistically only safe immediately after applying.
-- =============================================================================
