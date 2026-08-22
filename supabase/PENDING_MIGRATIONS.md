# Pending Supabase migrations

Every SQL change I stage but don't apply lands here. You paste them into
the Supabase Dashboard → SQL Editor when you're ready. Order matters —
top to bottom.

Update this file whenever a migration is applied: strike through the
`Status: Pending` line and change it to `Status: Applied YYYY-MM-DD`.

---

## 0028 — Search + leaderboard indexes

**Status:** ~~Pending~~ **Applied 2026-07-13** ✅
**File:** [0028_search_leaderboard_indexes.sql](migrations/0028_search_leaderboard_indexes.sql)
**Why:** Makes `ILIKE 'foo%'` friend-search sub-10 ms and global
leaderboard `ORDER BY earned_xp DESC LIMIT N` walk an index instead of
sorting the whole table.
**Cost:** < 5 s to build at 50 k rows, no write blocking, adds ~2 MB to
DB size.
**How to apply:**
1. Dashboard → SQL Editor → paste the file contents → Run
2. Verify with:
   ```sql
   select indexname, pg_size_pretty(pg_relation_size(('public.'||indexname)::regclass)) as size
   from pg_indexes
   where schemaname='public'
     and indexname in ('profiles_display_name_trgm_idx','profiles_total_xp_desc_idx');
   ```
   Should return 2 rows.
3. Verify pg_trgm extension:
   ```sql
   select extname, extversion from pg_extension where extname='pg_trgm';
   ```
**Rollback:** `drop index if exists profiles_display_name_trgm_idx; drop index if exists profiles_total_xp_desc_idx;`

---

## 0049 — Add `purchase_refund` to xp_ledger.reason CHECK

**Status:** ~~Pending~~ **Applied 2026-08-20** ✅
**File:** [0049_purchase_refund_reason.sql](migrations/0049_purchase_refund_reason.sql)
**Why:** The `razorpay_webhook` and `stripe_webhook` edge functions both
call `credit_user_xp(..., 'purchase_refund')` when a payment is refunded,
but the `xp_ledger.reason` CHECK constraint from 0016 didn't list that
value. Also had to preserve `'signup_grant'` (added in 0020) — first
apply attempt failed because that value was accidentally dropped from
the whitelist.

---

## 0050 — Streak-at-risk + streak-broken push notifications

**Status:** ~~Pending~~ **Applied 2026-08-20** ✅ (both cron jobs verified active, 3 profile columns present)
**File:** [0050_streak_notifications.sql](migrations/0050_streak_notifications.sql)
**Why:** Ships two "wow, right moment" pushes:
- `streak_at_risk` at 7 PM local time on day-2 of recovery, only when user is <50% of daily goal. Personalised body: "Your 12-day streak needs 3,200 more steps by midnight. About a 30-min walk."
- `streak_broken` at 8 AM local time the morning after the streak breaks. Body: "Your 24-day streak just paused. Start a new one today."

Both dedup themselves (one per calendar day / one per broken streak). Both use existing pipeline — insert on `public.notifications` triggers `send-push` automatically via migration 0009.

**What the migration adds:**
- 3 nullable columns on `profiles` (streak_broken_notif_pending_at, streak_broken_notif_prior_streak, streak_at_risk_notif_last_date)
- BEFORE-UPDATE trigger on `profiles` that stamps the broken-tracking columns whenever `current_streak` goes >0 → 0 (race-free, works for ANY code path that breaks the streak)
- Two SECURITY DEFINER functions: `notify_streak_at_risk()`, `notify_streak_broken()`
- Two pg_cron hourly schedules (`notify_streak_at_risk_hourly`, `notify_streak_broken_hourly`)

**Cost:** <100 ms metadata + trigger add. Cron jobs consume ~2-3 ms per hour per job. Zero risk to existing code.

**How to apply:**
1. Dashboard → SQL Editor → paste `0050_streak_notifications.sql` → Run
2. Verify with the queries at the bottom of the migration file
3. Force-test both notification paths using the simulate blocks in the verify section

**Rollback:**
```sql
select cron.unschedule('notify_streak_at_risk_hourly');
select cron.unschedule('notify_streak_broken_hourly');
drop function if exists public.notify_streak_at_risk();
drop function if exists public.notify_streak_broken();
drop trigger if exists profiles_streak_zero_watch_trigger on public.profiles;
drop function if exists public.profiles_streak_zero_watch();
-- (Leave the profile columns — dropping columns is destructive; they're nullable so no cost keeping them.)
```

**Companion edge function change** (also part of this notification cycle, deployed separately from the SQL migration):
Purchase + refund pushes were added to `supabase/functions/razorpay_webhook/index.ts` (see the two `insert notifications` blocks in `handlePaymentCaptured` and `handleRefund`). Redeploy that function alongside applying 0050 for the full 3-notification set. Same pattern to be mirrored into `stripe_webhook/index.ts` once Stripe goes live — tracked separately.

---

## 0051 — Auto-charge invitee stake on daily-series accept

**Status:** ~~Pending~~ **Applied 2026-08-20** ✅ (trigger installed, backfill charged 1 invitee — Narsimlu on #985364d1, both stake_paid=true confirmed)
**File:** [0051_daily_series_charge_on_accept.sql](migrations/0051_daily_series_charge_on_accept.sql)
**Why:** Real-money-leak bug found on 2026-08-20 via battle #9853 (Laxmi vs Narsimlu):
- Laxmi's stake got debited (creator path charges via daily-series creation)
- Narsimlu accepted but was NEVER charged (client `acceptInvite` daily-series branch returns early skipping `_chargeStake`; the server RPC `accept_daily_series_invite` doesn't charge either)
- Result: pot = 100 (only creator's stake). Invitee played for free.

**What this fixes:**
- Adds a BEFORE-UPDATE trigger on `battle_participants` — fires when `invite_status` transitions to `'accepted'` for a daily-series battle with positive stake, checks balance, charges via `_credit_xp_admin('battle_stake')`, flips `stake_paid=true`. Race-free (same transaction), RPC-agnostic (works whether the RPC pre-charges or not — idempotent via stake_paid check).
- Insufficient balance → `RAISE EXCEPTION` → whole accept aborts → invite stays pending → user sees clean error.
- **One-shot backfill DO block** that retroactively charges any current active daily-series battle where an invitee accepted but wasn't charged. Fixes #9853 (Narsimlu) at apply time.

**Cost:** <100 ms migration + one-time backfill loop (only fires on the handful of active daily-series battles right now). Zero runtime overhead per accept — trigger only fires when invite_status changes.

**How to apply:**
1. Dashboard → SQL Editor → paste `0051_daily_series_charge_on_accept.sql` → Run
2. Verify with the queries at the bottom of the migration
3. Confirm #9853's Narsimlu row now has `stake_paid = true` and a fresh `battle_stake` ledger row

**Rollback:**
```sql
drop trigger if exists daily_series_charge_on_accept_trigger on public.battle_participants;
drop function if exists public.daily_series_charge_on_accept();
-- Backfilled ledger rows stay in place (they represent real transactions) — no need to undo them.
```

---

## 0052 — Daily-series spawn day-skip fix + in-flight backfill

**Status:** ~~Pending~~ **Applied 2026-08-21** ✅ (verified: #6cc9 competing_date → Aug 21 for both participants, end_time → Aug 21 18:29:59 UTC = midnight IST tonight, hours_left ≈ 10.5)
**File:** [0052_daily_series_spawn_offbyone.sql](migrations/0052_daily_series_spawn_offbyone.sql)
**Why:** The deployed `settle_daily_battle` spawn block computed `v_next_local_date := (now_local::date + 1)::text`. At settle moment `now_local` is already at day N+1 in local time, so the `+ 1` double-adds — skipping one competing day every rollover. Combined with `end_time = now() + 48h` (not aligned with actual settle moment), this produced the "1d 22h left for a daily battle" symptom observed on Laxmi's series a9014af0.

**What this fixes:**
1. `settle_daily_battle` spawn — `v_next_local_date` now = prev competing_date + 1 day per-participant (deterministic, cron-timing-independent). Fallback to current local date if participant has no prev row (new-joiner edge case).
2. `settle_daily_battle` spawn — `end_time` = `max(user_local_end_utc(uid, next_date))` across new-day participants, not `now() + 48h`. Client countdown now reads honestly.
3. Backfill in-flight battle `6cc9cce4-0d4c-4aca-a659-f25b30f88b88` — participants' `competing_date`: Aug 22 → Aug 21; `end_time` recomputed. Safe because probes verified both users had 0 Friday steps at authoring time.

**What this does NOT touch (verified via probes C & B):**
- `accept_daily_series_invite` — its `v_local_today` formula has no `+ 1`, already correct.
- Non-daily battles — function bails when `series_id is null`.
- Older daily series (e207c8a2, b670d9c9) — probe B showed NULL competing_date on all rows, they don't use the per-user-local path.
- Client-side code — reads `competing_date` + `end_time`, no assumption changes.

**Blast radius today:** just Laxmi's series (only one currently on the per-user-local scoring path). Future daily series would all hit the bug on every rollover without this fix.

**How to apply:** Dashboard → SQL Editor → paste `0052_daily_series_spawn_offbyone.sql` → Run. Verification queries at the bottom of the file.

**Rollback:** re-run migration 0047's `settle_daily_battle` (which contains the buggy `+ 1` version). Backfill can be reverted with `update public.battle_participants set competing_date = '2026-08-22' where battle_id = '6cc9cce4-0d4c-4aca-a659-f25b30f88b88' and invite_status = 'accepted';` — but no reason to; the backfill matches user expectation and is verified safe.
