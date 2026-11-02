# Pending Migrations

Apply on Supabase (Dashboard → SQL Editor → paste → Run) IN ORDER. All additive / idempotent.

---

**🎉 Nothing else pending — every open migration is applied.**

**Already applied (verified 2026-08-10):** 0049, 0050, 0051 — removed from this file.
**Already applied (verified 2026-08-11):** 0052, 0053, 0055, 0056 — removed from this file.
**Already applied (verified 2026-08-13):** 0054, 0057, 0058 — removed from this file.
**Already applied (verified 2026-08-17):** 0059 (part 1 only — settle_daily_battle spawn fix; backfill for b85813df was intentionally skipped), 0060 (streak drift fix: `=`→`≥` + per-user exception handling + backfill stale evals) — removed from this file.
**Already deployed (verified 2026-09-04):** Edge Functions `subscription_create_order` + `subscription_verify` — both live in Supabase Dashboard → Edge Functions (7 functions total). Native subscription SDK flow unblocked for 1.1.6+37.
**Already applied (verified 2026-09-25):** 0061 (`battles.name` — one row, `text` / nullable), 0062 (`profiles.has_completed_tour` — `boolean` / default false / NOT NULL, backfill confirmed: grandfathered 117, will_see_tour 0) — removed from this file. Both ship in 1.1.7+39.

---

*New migrations get appended below this line when staged. Follow the pattern in git history: a `## NNNN — Title` section with **Why**, the SQL fenced as `sql`, a **Verification** query, and a **Rollback** block.*

---
