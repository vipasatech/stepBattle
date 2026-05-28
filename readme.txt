# StepBattle — Application Functionality Reference

This document describes what the StepBattle app **actually does today**, derived from
the implemented code (not the original design spec). It is the source of truth for the
current feature set, data model, and business logic.

StepBattle is a mobile fitness gamification app: it reads the device's step data and
turns walking into a competitive social game — XP, levels, battles, missions, clans,
and geo-scoped leaderboards.

- **Platform targets:** Android (primary) and iOS
- **Backend:** Supabase (Postgres + Auth + Realtime + Row-Level Security)
- **Step sources:** Native pedometer (always-on), Google Health Connect / Apple HealthKit,
  and optional Google Fit — combined by an aggregator with corruption protection
- **Local persistence:** Hive (pedometer baseline, feature flags)
- **State management:** Riverpod; routing via GoRouter (StatefulShellRoute)
- **Push:** Firebase Cloud Messaging (token stored on profile); in-app notifications via
  a realtime `notifications` table

---

## 1. Core Loop

1. User walks → steps tracked continuously by the device pedometer + health APIs.
2. Steps convert to XP → XP raises level and rank.
3. Users challenge each other to step battles → winner earns bonus XP.
4. Daily and weekly missions provide structured goals.
5. Clans let teams compete collectively.
6. Geo-scoped leaderboards (district / state / country / friends) create competition.
7. An interactive map shows region rankings.

---

## 2. Navigation Structure

**5-tab bottom navigation** (glassmorphic, persistent), backed by a StatefulShellRoute
so each tab keeps its own state:

```
[ Home ] [ Battles ] [ Missions ] [ Clan ] [ Leaderboard ]
```

**Full-screen routes** (pushed over the shell, no bottom bar):
- `/profile` — Profile page (opened from the avatar in any tab header)
- `/profile/step-sources` — Step-source diagnostics screen
- `/profile/health-setup` — OEM-aware health/permission setup wizard
- `/battle-ground/:id` — Animated live battle arena
- `/map` — Full-screen interactive geo map

**Auth-gated redirects:**
- Not signed in → `/login`
- Signed in but onboarding incomplete → `/onboarding`
- Otherwise → `/home`

---

## 3. Authentication & Onboarding

### Login (`lib/screens/auth/login_screen.dart`)
Sign-in methods, all through Supabase Auth:
- **Google OAuth** (a dedicated Supabase Web OAuth client; separate from any Firebase client)
- **Apple OAuth** (iOS only)
- **Email / password** (toggle between sign-in and sign-up)

A new auth user automatically gets a `profiles` row via a Postgres trigger
(`on_auth_user_created`), seeded with name/avatar from the OAuth metadata.
A "no network" sheet with retry is shown on connection failure.

### Onboarding (`lib/screens/auth/onboarding_screen.dart`)
3-step flow: (1) choose a username (3–20 chars), (2) connect health, (3) set a daily
step goal (preset chips 5K/8K/10K/15K plus a ±500 stepper). Completion flips an
onboarding flag and routes to Home.

### Health Setup Wizard (`lib/screens/onboarding/health_setup_screen.dart`)
Detects the device manufacturer and renders **OEM-specific** instructions (Samsung,
Xiaomi, Realme, Motorola, stock Android, etc.) for enabling Health Connect / step
feeders, with conditional cards for installing Health Connect, the OEM health app, or
falling back to Google Fit. Auto-shown once after first permission grant (guarded by a
Hive flag); revisitable from Profile.

---

## 4. Step Tracking & Source Aggregation

This is the heart of the app and the most hardened subsystem.

### Sources
- **Native pedometer** (`native_step_service.dart`) — Android `TYPE_STEP_COUNTER` /
  iOS `CMPedometer`. Tracks a per-day baseline in Hive, detects device **reboots**
  (cumulative counter resets), and carries pre-reboot steps forward.
- **Health Connect / HealthKit** (`health_service.dart`) — unified via the `health`
  package; monotonic-within-day reads with a cached fallback for background-read limits.
- **Google Fit** (`google_fit_service.dart`) — REST API, **opt-in** from Profile →
  Step Sources (avoids an extra OAuth scope unless the user wants it).

### Aggregator policy (`step_source_aggregator.dart`)
1. **Sanity cap:** any source reporting > 100,000 steps/day is rejected as a corrupt
   baseline and logged (`aggregator:sourceRejected`).
2. **Health-Connect-preferred:** if HC/HealthKit is available it is treated as
   authoritative; the native pedometer is the fallback for fresh installs.
3. **Self-heal:** if native drifts above HC by > 10,000 steps, the native baseline is
   repaired from the trusted HC value (`repairBaselineFromTrustedSource`).

### Sync (`step_service.dart`)
On each sync: upsert the daily `step_logs` row, bump `profiles.total_steps_all_time`
(read-modify-write), and award step XP. A **per-sync delta cap of 100,000** rejects
absurd jumps so a bad reading can't poison the lifetime counter. Calories are derived
as `steps × 0.04`.

> Migration `0007` was a one-time cleanup for historical rows poisoned by an earlier
> native-baseline bug (delete `step_logs` > 100k, recompute lifetime totals, reset XP
> gate fields).

### Per-source forensics (`source_step_hourly_log_service.dart`)
Hourly per-source readings (native / HC / Fit), the winning source, per-source errors,
and a device fingerprint are written to `source_step_hourly` for debugging which OEMs
feed step data reliably.

---

## 5. Home Tab (`lib/screens/home/`)

Daily dashboard. Header shows the brand, a Friends button (badge for pending requests),
a notifications bell (unread badge), a streak flame badge (→ Streak History sheet), and
the profile avatar (→ Profile).

Sections, top to bottom:
1. **No-steps banner** — auto-appears when every step source fails for ~10+ minutes;
   tap → health-setup wizard; auto-dismisses when steps flow again.
2. **Overview card** — level badge, large today's-step count (shimmer while loading,
   "—" on error), XP-vs-yesterday delta, and a level-progress bar with "X XP to go".
3. **Stat pills** (3) — Calories burnt today; Global Rank (→ Leaderboard);
   Missions completed today (→ Missions).
4. **Active battle card** — three states: active battle (lead/behind delta + "Enter the
   Arena" → battle-ground), last completed battle (result + XP), or no battles
   ("Start a Battle" → Battles).
5. **Daily missions** — 2–3 mission rows with progress and XP; tap → Mission Detail sheet.
6. **Map preview** — if no home district set, a "Set your home" CTA; otherwise a
   "Who's Leading Near You" card → full map.

---

## 6. Battles

### Battles Tab (`lib/screens/battles/battles_screen.dart`)
Sectioned list with a "New Battle" action in the header. A slim **"Reconnecting…"** pill
appears at the top while the realtime stream is retrying. Sections:
- **Incoming invites** — Accept / Reject inline (inviter, type, duration, XP).
- **Active battles** — `BattleCard`: short ID, both step counts, dual-fill bar, time
  remaining, XP reward. Tap → battle arena.
- **Waiting for opponent** — scheduled/pending battles (chevron → Pending Battles screen).
- **Completed** — frozen bar, Won/Lost pill, XP earned.

Friendly error copy ("Could not load battles. Pull to retry.") instead of raw exceptions.

### Pending Battles (`pending_battles_screen.dart`)
Full list of pending/scheduled battles; the **creator** can delete (confirm dialog).

### Battle Arena (`lib/screens/battle_ground/`)
Immersive animated arena for an active battle, driven by a single shared `Ticker`:
- Runners positioned proportionally to steps; smooth tween to target positions.
- Time-of-day skybox (dawn/day/dusk/night), parallax painters, up to 6 lanes.
- Camera auto-follows the current user; drag to pan (auto-follow suspends ~3s),
  double-tap to recenter.
- Countdown ring (time remaining), leaderboard pill (standings + reward).
- Lead changes trigger a screen flash, haptic, and toast; on completion the winner
  badge plants on the leader and the scene freezes.

### Creating a battle (sheets)
1. **New Battle selection** — 1v1 or Group.
2. **1v1 setup** — pick a friend, choose duration (1/3/7 days), create.
3. **Group setup** — multi-select friends (up to 10), create.

Invites fan out as notifications; recipients accept/reject from the notifications sheet
or the battles tab.

### Battle scoring (lifetime-counter baseline model)
- A participant's live score is `profiles.total_steps_all_time − start_steps_baseline`.
- **Status lifecycle:** `pending → scheduled → active → completed` (or `cancelled`).
  - When all invitees accept: if start time has passed → **active** (baselines snapped
    immediately); if start time is future → **scheduled** until the window opens.
  - On **activation**, each participant's `start_steps_baseline` is snapshotted from their
    lifetime counter.
  - On **completion** (end time passed), `end_steps_baseline` is snapshotted, freezing the
    final score independent of future walking.
- **Winner:** highest score. Ties or non-positive scores → no winner, no XP.
- Reward: **+200 XP** (1v1) / **+300 XP** (group) to the winner.

---

## 7. Missions (`lib/screens/missions/`)

Daily and weekly challenges read from a `missions` catalog table (with hardcoded
defaults as a fallback). Progress is tracked per user, per mission, per period in
`user_mission_progress` and streamed live.

- **Reset countdown** to local midnight; weekly period keys off Monday.
- Mission cards: category icon, title, progress bar, XP reward, status (In progress /
  Completed / Locked). Tap → **Mission Detail sheet** (draggable, full progress + how-it-works).
- **Completion is monotonic** — once a mission is marked complete for the period it stays
  complete (prevents flicker and false repeat XP on transient step spikes).

**Seeded defaults:**
- Daily: Walk 5,000 steps (100 XP) · Win a battle (150 XP) · Keep streak alive (50 XP)
- Weekly: Walk 50,000 steps (500 XP) · Win 3 battles (400 XP) · All daily missions 5 days (300 XP)

---

## 8. Clans (`lib/screens/clan/`)

### Entry state (no clan)
Shows pending clan invites (accept/reject) plus "Create a Clan" and "Join a Clan" CTAs.

### Create / Join (sheets)
- **Create Clan** — name (3–20 chars), optionally invite friends; creator becomes captain.
- **Join Clan** — search by clan ID code or name; request/join.

### Dashboard state (in a clan)
Header shows clan name and member count with a settings gear → Clan Details. Lists members
(roles: captain / admin / soldier) with steps today, a copyable clan ID code, and clan
battle entry points.

### Clan battles
`create_clan_battle_screen.dart` / `join_clan_battle_screen.dart` plus schema and models
exist (teams A/B, duration, `xp_per_member` default 300, winner clan). Clan-battle
**scoring/step propagation is not yet wired** — see Implementation Status.

**Rules:** clan creation gated to Level 5+, max 10 members, only the captain manages the
clan / its battles, one active clan battle at a time.

---

## 9. Leaderboards (`lib/screens/leaderboard/`)

Geo-scoped, not a single global board. **4 tabs:** District · State · Country · Friends.

- **Geo tabs** require a **home district** to be set. If not set, a `NeedsLocationCard`
  prompts the user to set their home (Set Home sheet). Geo ranks are computed live from
  `profiles` ordered by `total_xp` (supported by per-region indexes).
- **Friends tab** ranks the user's accepted friends.
- Top 3 render as a **podium** (gold/silver/bronze); the rest as ranked rows.
- A **floating rank card** pins the user's own rank/XP above the tab bar while scrolling.
- Tapping a row opens that user's **Public Profile sheet** (stats + add-friend /
  challenge-to-battle).

> A `leaderboard_snapshots` table exists for precomputed global ranks but is **not yet
> populated** (awaits a scheduled job); current ranks are computed live.

---

## 10. Map (`lib/screens/map/`)

Full-screen interactive map (flutter_map) with snap zoom tiers (world → country → state
→ district). Region boundaries are loaded per tier and color-coded by leaderboard
standing; tapping a region drills into its leaderboard. Requires a home district to be set.

---

## 11. Profile (`lib/screens/profile/`)

- **Identity** — avatar, display name, copyable user code, edit.
- **Set Goal** → Set Goal sheet (presets + ±500 stepper, min 1,000 / max 50,000).
- **This Week** stats and **All Time** stats.
- **Account details** — email, connected step sources, link to "how my steps are tracked"
  (→ Step Sources diagnostics screen).
- **Sign out**.

**Step Sources screen** (`step_sources_screen.dart`) shows live native / Health Connect /
Google Fit readings, per-source errors, and permission status; this is where Google Fit
is toggled on/off.

---

## 12. Bottom Sheets (`lib/sheets/`)

- **new_battle_selection** — choose 1v1 vs group.
- **battle_1v1_setup / battle_group_setup** — opponent selection, duration, create.
- **add_friends** — search by name / user code, send friend requests; reused across
  battle/clan flows.
- **create_clan / join_clan** — clan creation and joining.
- **mission_detail** — full mission progress and explanation.
- **set_goal** — daily step goal editor.
- **set_home** — pick home district/state/country (enables geo leaderboards + map).
- **notifications** — unified inbox; actionable items (friend/battle/clan invites) sorted
  first with inline Accept/Reject; "Mark all read".
- **public_profile** — another user's stats + add-friend / challenge.
- **streak_history** — calendar of consecutive active days.
- **xp_breakdown** — today's XP by source.

---

## 13. Notifications

In-app notifications live in a realtime `notifications` table; the bell badge reflects
unread count. Types: `friendRequest`, `friendAccepted`, `battleInvite`, `battleStarted`,
`battleRejected`, `battleResult`, `clanInvite`, `levelUp`, `missionReset`, `other`.

Each notification carries a `data` jsonb payload (e.g. `battle_id`, `clan_id`,
`relationship_id`, `from_user_id`) in **snake_case** — accept/reject handlers read
snake_case with a camelCase fallback for legacy rows. An incoming friend request also
slides in a top toast (`friend_request_toast_host`). FCM push is supported via a token
stored on the profile.

---

## 14. XP & Levelling

XP values (`lib/config/constants.dart`):

| Event | XP |
|---|---|
| Per 1,000 steps | +10 (gated per day so it can't double-award) |
| Reach daily step goal | +75 (once/day) |
| Complete a daily mission | +50 to +150 |
| Complete a weekly challenge | +300 to +500 |
| Win a 1v1 battle | +200 |
| Win a group battle | +300 |
| Win a clan battle (per member) | +300 |
| 7-day streak | +100 |
| All daily missions bonus | +150 |

**Step-XP gating:** `last_step_xp_threshold` / `last_step_xp_date` on the profile track
how many thousand-step thresholds have already been paid today; on a new day the threshold
resets. Daily-goal bonus is gated by `daily_goal_xp_awarded_date`.

**Level thresholds (cumulative XP):**

| Lvl | XP | Lvl | XP | Lvl | XP | Lvl | XP |
|----|------|----|-------|----|-------|----|-------|
| 1 | 0 | 6 | 4,500 | 11 | 20,000 | 16 | 40,000 |
| 2 | 500 | 7 | 6,000 | 12 | 25,000 | 17 | 50,000 |
| 3 | 1,200 | 8 | 8,000 | 13 | 30,000 | 18 | 60,000 |
| 4 | 2,000 | 9 | 11,000 | 14 | 32,500 | 19 | 70,000 |
| 5 | 3,000 | 10 | 15,000 | 15 | 35,000 | 20 | 75,000 |

Other key constants: default goal 8,000 (min 1,000 / max 50,000, ±500 step); background
sync ~15 min, active-battle sync ~5 min; max group/clan members 10; clan creation Level 5+.

---

## 15. Backend Schema (Supabase / Postgres)

All user-data tables have Row-Level Security and are published to Supabase Realtime.

**Tables:**
- `profiles` — account, level, `total_xp`, streaks, `daily_step_goal`,
  `total_steps_all_time` (battle baseline source), XP-gate fields, FCM token, geo/home
  fields, `clan_id`.
- `step_logs` — one row per user per day (`step_count`, `calories`, `source`).
- `source_step_hourly` — per-source hourly forensics + device fingerprint.
- `missions` — admin-seeded catalog. `user_mission_progress` — per user/mission/period.
- `battles` — type (`1v1`/`group`), status (`pending`/`scheduled`/`active`/`completed`/
  `cancelled`), window, reward, winner. `battle_participants` — baselines, `current_steps`,
  `invite_status`, `is_winner`.
- `clans`, `clan_members` (roles), `clan_invites`.
- `clan_battles`, `clan_battle_teams` (teams A/B).
- `friend_relationships` — directed edges; friendship = `status='accepted'`.
- `notifications` — in-app inbox (jsonb `data`).
- `leaderboard_snapshots` — precomputed ranks (not yet populated).

**Migrations:** `0001` init (tables + RLS + auth trigger + mission seeds) · `0002`
hourly forensics columns · `0003` clan/clan-battle extras · `0004` realtime publication ·
`0005` relaxed RLS for co-participant / captain multi-row writes · `0006` `scheduled`
battle status · `0007` one-time corrupt step-data cleanup.

> Migrations are applied manually via the Supabase SQL editor for this project (the
> Supabase MCP is intentionally not used here).

---

## 16. Realtime & Resilience

Riverpod StreamProviders wrap Supabase realtime streams for battles, invites, missions,
notifications, and profile. Battle streams are wrapped with `retryingRealtimeStream`
(exponential backoff 2s→30s) so transient `RealtimeSubscribeException(timedOut)` errors
auto-recover instead of surfacing raw; a `battlesReconnectingProvider` flag drives the UI
"Reconnecting…" pill. Loading states use shimmer skeletons; every list has a defined
empty state; errors show friendly copy.

---

## 17. Design System

- **Brand:** deep violet `#7C3AED` (primary), vivid violet `#A855F7` (accent), lavender
  `#D8B4FE` (tertiary).
- **Background:** near-black `#0E0E10`. Semantic: success `#34A853`, error `#FF716C`,
  amber `#FBBC04`.
- **Surfaces:** layered container tints; **glassmorphism** cards (≈60% surface-variant,
  20px backdrop blur, subtle primary glow, thin border).
- **Type:** Space Grotesk for headlines/step counts; Manrope for body/labels.
- **Conventions:** dark theme only, no divider lines (spacing/colour shift instead),
  bottom sheets with 28px rounded tops + handle pill, stadium-shaped filled buttons.

---

## 18. Implementation Status (honest notes)

Fully working: auth + profiles, step tracking/aggregation + XP drip, missions catalog &
progress, battle create/accept/reject/activate/complete + scoring, friends, in-app
notifications, clan structure & membership, geo leaderboards, map, permissions.

Not yet wired / partial:
- Step→battle, step→mission, and step→clan **live propagation** hooks in `step_service.dart`
  are stubs (battle/mission/clan step counts don't yet update from each sync).
- **Clan battle** scoring/step aggregation (schema + screens exist; logic pending).
- **Streak** increment/break logic (columns exist; automation pending).
- **leaderboard_snapshots** population job (ranks currently computed live).
- Multi-row writes trust the client (RLS relaxed in `0005`) as an MVP tradeoff; intended
  to move to Edge Functions later.

---

*Reflects the implemented codebase as of 2026-05-28. Backend: Supabase project
`egdmatrypvewrzkislmo`. Original visual spec lives in `stitch_stepbattle__1_.zip`.*
