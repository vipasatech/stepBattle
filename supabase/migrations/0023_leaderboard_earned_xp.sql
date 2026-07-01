-- =============================================================================
-- StepBattle — Leaderboard earned-XP view.
--
-- WHY: The Ranks screen currently sorts by `profiles.total_xp`, which
-- includes XP the user PURCHASED via Razorpay (see xp_purchases from
-- migration 0016). Per the redesign spec the leaderboard should rank by
-- "earned XP" only — i.e. `total_xp` minus the sum of every captured
-- purchase — so the board can't be climbed by opening a wallet.
--
-- WHAT:
--   `public.profile_earned_xp` — a VIEW over `profiles` that exposes
--   every column on `profiles` PLUS a computed `earned_xp` column:
--
--       earned_xp = total_xp − COALESCE(sum(captured xp_credited), 0)
--
--   Refunded / failed / created-but-not-captured purchases are excluded
--   from the subtraction (they never credited XP to the user), so
--   earned_xp = total_xp for anyone who hasn't successfully purchased.
--
-- HOW THE APP USES IT:
--   Client swaps `.from('profiles')` → `.from('profile_earned_xp')` on
--   the leaderboard queries and orders by `earned_xp` DESC instead of
--   `total_xp` DESC. Every other read path stays on `profiles`.
--
-- HOW TO APPLY:
--   Dashboard → SQL Editor → paste this file → Run.
--   Safe to re-run — the view is drop-then-create.
-- =============================================================================

-- Drop then create so re-runs pick up column changes on `profiles`.
drop view if exists public.profile_earned_xp;

create view public.profile_earned_xp
with (security_invoker = true) as
select
  p.*,
  greatest(
    0,
    p.total_xp - coalesce(x.purchased_xp, 0)
  ) as earned_xp
from public.profiles p
left join lateral (
  -- Per-user sum of every CAPTURED (i.e. money-received) purchase.
  -- Refunded / failed / created rows never credited XP so they must
  -- not be subtracted.
  select sum(xp_credited)::integer as purchased_xp
  from public.xp_purchases
  where user_id = p.id
    and status = 'captured'
) x on true;

-- `security_invoker = true` above makes the view honour the CALLER's
-- RLS on `profiles` and `xp_purchases`, so no separate GRANT / policy
-- work is needed here — reads through `profile_earned_xp` obey the
-- same "everyone can read profiles / only owner can read own
-- xp_purchases" rules the base tables already enforce.
