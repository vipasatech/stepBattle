-- =============================================================================
-- Migration 0049 — Add 'purchase_refund' to xp_ledger.reason CHECK constraint.
--
-- BUG: razorpay_webhook + stripe_webhook both call credit_user_xp with
-- p_reason='purchase_refund' when clawing back XP after a payment refund
-- (see supabase/functions/razorpay_webhook/index.ts line 275 and
-- supabase/functions/stripe_webhook/index.ts line 250). The CHECK
-- constraint on xp_ledger.reason from migration 0016 doesn't include
-- 'purchase_refund' — only 'battle_refund' for battle-side refunds. So
-- every payment refund fails at the ledger INSERT with a constraint
-- violation, the whole credit_user_xp transaction rolls back, and the
-- webhook returns 500. Razorpay/Stripe retry until they give up and
-- disable the webhook. Meanwhile the money HAS been refunded to the
-- user but their XP stays credited — free XP.
--
-- Never triggered in production because no live refunds have been
-- issued before 2026-08-19 (this migration is being applied on the day
-- Razorpay went live). Caught during first-ever refund testing.
--
-- FIX: drop and recreate the CHECK constraint with 'purchase_refund'
-- added. Safe:
--   • No existing xp_ledger row uses 'purchase_refund' (the bug meant
--     none could ever get inserted), so the recreate cannot fail on
--     legacy data.
--   • The constraint recreate is metadata-only + a full-scan validation
--     that completes in <100 ms even at 100 k rows.
--   • Naming assumption: the auto-generated constraint name is
--     xp_ledger_reason_check. If Supabase auto-assigned a different
--     name in your project, the DROP IF EXISTS is silent and the ADD
--     creates the new constraint alongside; both would apply the same
--     rule so behaviour is still correct. Clean it up post-apply if
--     you see duplicates in pg_constraint.
--
-- HOW TO APPLY: Dashboard → SQL Editor → paste → Run.
-- Idempotent: safe to re-run.
-- =============================================================================

alter table public.xp_ledger
  drop constraint if exists xp_ledger_reason_check;

alter table public.xp_ledger
  add constraint xp_ledger_reason_check
  check (reason in (
    'daily_mission',      -- +100 per met daily target
    'streak_milestone',   -- +100 per 25-day streak milestone
    'battle_stake',       -- -X on accept (deduction)
    'battle_win',         -- +pot/winners on completion
    'battle_refund',      -- +X on battle cancel / tie refund
    'purchase',           -- +X on Razorpay/Stripe capture
    'purchase_refund',    -- -X on Razorpay/Stripe refund  ← ADDED IN 0049
    'signup_grant',       -- +100 on new user signup (added in 0020)
    'admin_adjust'        -- escape hatch for manual fixes
  ));

-- =============================================================================
-- Verification queries (run separately after the ALTER commands above):
--
--   1. Confirm the constraint now includes purchase_refund:
--        select conname, pg_get_constraintdef(oid)
--        from pg_constraint
--        where conrelid = 'public.xp_ledger'::regclass
--          and contype = 'c';
--
--   2. Simulate the webhook path — expect success now, previously it
--      would have raised "new row for relation xp_ledger violates
--      check constraint xp_ledger_reason_check":
--        select public.credit_user_xp(
--          <your-test-uid>::uuid,
--          -100,
--          'purchase_refund',
--          jsonb_build_object('note', '0049 self-test')
--        );
--
--      If (2) works, delete the row it inserted to keep test data clean:
--        delete from public.xp_ledger
--         where reason = 'purchase_refund'
--           and context->>'note' = '0049 self-test';
--      -- and reverse the total_xp change manually if it mattered
--        select public.credit_user_xp(<your-test-uid>::uuid, 100,
--                                      'admin_adjust',
--                                      jsonb_build_object('note',
--                                        'reverse 0049 self-test'));
-- =============================================================================
