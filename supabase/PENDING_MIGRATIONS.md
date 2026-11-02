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

---

## 0061 — Optional user-provided battle name

**Status:** ~~Pending~~ **Applied 2026-09-25** ✅ (verified: `information_schema.columns` returns exactly one row — `battles / name / text / YES`. Note `battle_series.name` was NOT part of this migration; it's deferred to the 0063 follow-up below.)
**File:** [0061_battle_name.sql](migrations/0061_battle_name.sql)
**Why:** 1.1.6+39 ships the `BattleNameField` widget in every setup sheet — 1v1, Multi, Team — so users can name a battle ("🌅 Morning Warriors", "Revenge match", …). The name renders on Discover cards, Battle-Ground headers, and Day-Summary tiles in place of the auto-generated `"$type battle by $creator"`.

**Client state today (already shipped):**
- `BattleModel.name : String?` (lib/models/battle_model.dart:221) — reads `d['name']` as trimmed String, NULL when blank.
- `BattleNameField` wired into `battle_1v1_setup_sheet.dart`, `battle_group_setup_sheet.dart`, `battle_team_setup_sheet.dart`.
- `BattleService.createBattle(name: name)` passes it through to the RPC.

Column doesn't exist server-side yet — every insert with a non-null name would fail with `column "name" of relation "battles" does not exist`. This migration adds it. Existing battles carry NULL → client falls back to the auto-generated label. No backfill needed.

**Cost:** < 100 ms metadata-only ADD COLUMN. Nullable + no default → no full-table rewrite.

**How to apply:** Dashboard → SQL Editor → paste `0061_battle_name.sql` → Run. Verification queries at the bottom of the file.

**Rollback:** `alter table public.battles drop column if exists name;` — loses any user-set names, irreversible.

---

## 0062 — Server-side "has completed tour" flag

**Status:** ~~Pending~~ **Applied 2026-09-25** ✅ (verified: column is `boolean / default false / NOT NULL`, and the grandfather backfill ran — `grandfathered = 117`, `will_see_tour = 0`, so no existing user gets the tour retro-fired.)
**File:** [0062_has_completed_tour.sql](migrations/0062_has_completed_tour.sql)
**Why:** 1.1.6+39 ships the new-user tour (`OnboardingTourOverlay` in lib/features/onboarding_tour/). Fire gate needs a durable server-side "user has seen the tour" bit so the overlay doesn't re-fire on every install / device switch / cache clear.

**Client state today (already shipped):**
- `UserModel.hasCompletedTour : bool` (lib/models/user_model.dart:240) — reads `d['has_completed_tour']`, defaults to `true` when the column is absent so today's release doesn't fire the tour retroactively.
- `TourService.syncFromServer / markCompleted / resetForReplay` (lib/services/tour_service.dart) mirrors it into `CrossIsolateKV.tour_completed_local`.
- `TourService.shouldFire` gates first-fire on both source == not-completed AND local mirror == not-completed.
- On skip / finish, client writes `.update({'has_completed_tour': true})` on `profiles`.

Today those writes soft-fail with **PGRST204** — visible in session logs as `tour:server:markCompletedFailed` because the column doesn't exist. Local mirror still gets set (so the tour won't re-fire on THIS device), but the flag doesn't sync across devices.

**Schema:** `profiles.has_completed_tour boolean not null default false`.

**Backfill (critical):** every existing row is set to `true` in the same migration. Existing users are grandfathered so they don't get retro-fired the tour on their next open. New sign-ups after this migration get the column default (`false`) and correctly see the tour on first Home visit.

**Cost:** ~50 ms at today's ~200-profile size (ADD COLUMN NOT NULL DEFAULT false is one storage rewrite pass; the follow-up backfill UPDATE is another single pass). Well under 1 s total.

**How to apply:** Dashboard → SQL Editor → paste `0062_has_completed_tour.sql` → Run. Verification queries at the bottom of the file.

**Rollback:** `alter table public.profiles drop column if exists has_completed_tour;` — loses per-user tour-completion history, irreversible.

---

## 0063 — Fix signup bonus (route both grant paths through `_credit_xp_admin`)

**Status:** ~~Pending~~ **Applied 2026-11-02** ✅ (verified end-to-end on three fresh signups — `logs/2026-11-02_12-34-08/xp.log`: `signupBonus:credited {xp: 500}` → `signupBonus:xpVerified {totalXp: 500}` → `xpDelta:reason {reason: "signup_grant", context: {"source": "onboarding_rpc_v2"}}`. The `onboarding_rpc_v2` source proves the RPC path ran and no longer raises 42501.)
**File:** [0063_fix_signup_grant_admin_route.sql](migrations/0063_fix_signup_grant_admin_route.sql)
**Priority:** 🔴 HIGH — every new signup is currently losing their 500 XP bonus.

**Why:** Testers reported missing signup bonuses (2026-10-18). Client log:
`credit_user_xp: reason signup_grant not allowed for client callers, code 42501`.

The DEPLOYED `credit_user_xp` (drifted from 0016 — hardened live, never captured in a
migration) allows exactly ONE reason for non-`service_role` callers: `battle_stake`.
`SECURITY DEFINER` does not rescue callers because `auth.role()` reads the JWT request
setting, not the function owner — the trap documented in 0047 (lines 16-24) and 0045
(lines 35-39).

**This is the third occurrence of this guard silently breaking an XP path.** `battle_win`
/ `battle_refund` were rerouted in 0047; `daily_mission` / `streak_milestone` in 0048.
`signup_grant` was never rerouted, so BOTH paths have been failing:
- `grant_signup_xp()` — AFTER INSERT trigger on `profiles` (0020, 100 XP)
- `award_signup_bonus_v2()` — onboarding RPC the client calls (live-only, 500 XP)

**What it changes:** both now call `public._credit_xp_admin` (0047). Legacy trigger's
amount goes 100 → 500 so the two paths agree — otherwise whichever fires first wins and
the other no-ops on the existence guard, permanently capping that user at 100.

`credit_user_xp` itself is deliberately NOT loosened — that would reopen the client-side
XP-minting hole its guards exist to close.

**Cost:** two `CREATE OR REPLACE FUNCTION` + one trigger re-assert. No data touched.

**How to apply:** Dashboard → SQL Editor → paste → Run. Then sign up a fresh account and
confirm `signupBonus:credited {xp: 500}` before applying 0064.

**Rollback:** restore the previous bodies (in the file). Non-destructive — no data change.

---

## 0064 — Backfill signup bonus for the 102 users the bug skipped

**Status:** Pending — **apply ONLY after 0063 is verified on a live signup**
**File:** [0064_backfill_signup_grant.sql](migrations/0064_backfill_signup_grant.sql)
**Priority:** 🔴 HIGH — but gated behind 0063.

**Why:** measured 2026-10-29, before any fix:

| metric | value |
|---|---|
| total_users | 140 |
| got_bonus | 38 |
| **owed_bonus** | **102** |

73% of the user base never received the bonus they were promised.

**⚠️ Economic impact:** 102 × 500 = **51,000 XP minted**. At the ₹1 = 1 XP sale rate
that's ~₹51,000 of in-app value, and it WILL shift leaderboard standings since
`profiles.total_xp` drives ranking. This is value users were already owed, but it is real
and irreversible in practice — a deliberate decision, not a side effect.

**Structure:** the file is split so nothing fires by accident.
- **SECTION 1** — read-only pre-flight. Cohort breakdown (how many at 0 / 100 / 500 XP)
  plus a duplicate-grant sanity check. Run first, eyeball the numbers.
- **SECTION 2a** — backfills the 102 with no grant at all. Idempotent via `NOT EXISTS`.
- **SECTION 2b** — **commented out.** Optional 400 XP top-up for users the legacy trigger
  gave 100. That's a policy call about your economy, not a bug fix, so it does not run
  by default.

**How to apply:** Dashboard → SQL Editor. SECTION 1 first, read output, then SECTION 2a.

**Rollback:** in-file, matched on `context->>'source' = 'backfill_0064'` so genuine grants
are untouched. ⚠️ Only realistically safe immediately after applying — once users spend
the XP the debit clamps at 0 and ledgers stop reconciling.

---

## 0065 — Fix `notify_streak_at_risk` text/date comparison

**Status:** Pending
**File:** [0065_fix_streak_at_risk_date_cast.sql](migrations/0065_fix_streak_at_risk_date_cast.sql)
**Priority:** 🟠 MEDIUM — streak-at-risk pushes have never been delivered, but nothing is corrupted.

**Why:** `cron.job_run_details` shows `notify_streak_at_risk_hourly` failing with
`operator does not exist: text = date`. `step_logs.date` is **text** (`yyyy-MM-dd`, 0001
line 123) but 0050 declared `v_today_local date` and compared them directly (0050 line 131).

**The run history is misleading.** 159 "succeeded" vs 9 "failed" looks like an intermittent
glitch. It isn't — PL/pgSQL only plans a statement when it executes, and the failing line
sits behind four gates (recovery-started, streak > 0, fcm_token set, **local hour == 19**,
not already notified today). Hours where nobody cleared all of them never reached the
statement and reported success. **Every run with actual work to do has failed.** Zero
streak-at-risk notifications have been sent since 0050 shipped 2026-08-20.

**Fix:** compare on text — `date = to_char(v_today_local, 'YYYY-MM-DD')`. Casting the
column (`date::date`) would also type-check but goes non-sargable and abandons the
`unique (user_id, date)` index from 0001. Formatting the variable keeps the index.

Everything else in the function is byte-identical: gates, copy, dedup write, 50%-of-goal
threshold.

**Checked, not affected:** `notify_streak_broken` never reads `step_logs`, so its 168/168
successes are genuine.

**Cost:** one `CREATE OR REPLACE FUNCTION`. No data touched.

**How to apply:** Dashboard → SQL Editor → paste → Run, then `select public.notify_streak_at_risk();`
to confirm it plans without error.

**Rollback:** restore 0050's body. Non-destructive — but it only re-introduces the bug.

---

## 0066 — Drop `profiles_signup_grant` trigger (restore the celebration popup)

**Status:** ~~Pending~~ **Applied 2026-11-02** ✅ (verified: the grant arrives with `source = "onboarding_rpc_v2"`, never `profile_insert_trigger` — if the trigger were still attached it would pre-credit during profile INSERT, the client's `currentTotalXp == 0` gate would skip the RPC, and no `signupBonus:credited` line would exist at all. The +500 celebration overlay also fires, which is only reachable via the RPC path.)
**File:** [0066_drop_signup_grant_trigger.sql](migrations/0066_drop_signup_grant_trigger.sql)
**Priority:** 🟠 MEDIUM — corrects an over-correction in 0063.

**Why:** 0063 re-asserted the AFTER INSERT trigger from 0020. That was wrong on three counts:

1. **It suppresses the celebration popup.** The client gates the RPC on
   `shouldAwardSignUpBonus = currentTotalXp == 0` (supabase_auth_service.dart:419). If the
   trigger already credited 500 during profile INSERT, that read returns 500, the gate is
   false, the RPC never runs — and the `XPCelebrationBus.enqueue()` added alongside this
   migration never fires.
2. **It erases the 0 → 500 transition.** A profile born at 500 XP paints Level 2 on frame 1.
   Animations need a change to interpolate from.
3. **It puts a credit operation inside profile INSERT.** An exception in an AFTER INSERT
   trigger aborts the insert. Pre-0063 the trigger called `credit_user_xp` → 42501, so any
   INSERT reaching it would have failed. Since 140 signups demonstrably worked, the trigger
   was already absent live before 0063 re-added it.

**Trade-off:** a user who abandons onboarding gets no bonus. Correct — they have no usable
profile, and the RPC is idempotent so it lands in full whenever they finish.

The `grant_signup_xp()` **function** is left in place (still rerouted via `_credit_xp_admin`),
so rollback is one line.

**Pairs with a client change** in `supabase_auth_service.dart` — enqueues
`XPAwardEvent(amount: credited, reason: 'Sign-up bonus')` on a non-zero RPC result. The
celebration overlay and bus were never deleted (`xp_celebration.dart`, mounted in
`main_shell.dart:44`); migration 0055 just moved the grant off `XPService.awardXP()`, which
was the only caller of `enqueue()`. **Ship both together** — the trigger drop alone restores
the transition; the client change alone does nothing while the trigger wins the race.

⚠️ **The client half needs a new build.** Server-only testing will show the ledger row but
no popup until the app is rebuilt.

**Cost:** one `DROP TRIGGER`. No data touched.

**How to apply:** Dashboard → SQL Editor → paste → Run.

**Rollback:** re-create the trigger (in the file). Non-destructive, but re-introduces all three problems.
