# StepBattle — Complete Application Context

> **For Claude Code:** Read this file fully before reading the Stitch zip file.
> The zip file (`stitch_stepbattle__1_.zip`) in this folder contains 17 screen designs
> (HTML + PNG) that are the visual reference. This README is the functional and content
> specification. Use both together.

---

## 1. What Is StepBattle

StepBattle is a cross-platform mobile fitness gamification application. It reads
pedometer and step data from the user's device health APIs and turns that data into a
competitive social game.

**Core loop:**
1. User walks → steps are tracked in real time
2. Steps convert to XP → XP increases level and rank
3. Users challenge each other to step battles → winner earns bonus XP
4. Daily and weekly missions give structured goals
5. Clans let teams compete collectively
6. Leaderboard creates global and social competition
7. A Snapchat-style map shows who is leading nearby

**Platform targets:** iOS (primary) and Android  
**Health integrations:** Apple HealthKit (iOS), Google Health Connect (Android)  
**Real-time requirements:** Battle step counts sync live, leaderboard updates live

---

## 2. Application Architecture Overview

### Navigation Structure

The app has a **5-tab bottom navigation bar** that is persistent across all main screens.

```
[ Home ] [ Battles ] [ Missions ] [ Clan ] [ Leaderboard ]
```

The **Profile page** is a sub-page, not a tab. It is accessed by tapping the avatar
circle in the top-right corner of any main screen.

### Screen Inventory

**Main tab screens (5):**
- Home
- Battles
- Missions
- Clan (entry state OR dashboard state depending on membership)
- Leaderboard

**Sub-screens / Full screens (3):**
- Profile page
- Create Clan Battle screen
- Join Clan Battle screen
- Full-screen Map view

**Bottom sheets (9):**
- New Battle selection sheet
- 1v1 Battle setup sheet
- Group Battle setup sheet
- Mission detail sheet
- Set Goal sheet
- Create Clan sheet
- Join Clan sheet
- Add Friends sheet (reusable, called from multiple places)
- Public Profile card (from Leaderboard row tap)

---

## 3. Design System

> Full spec is in `titanium_velocity/DESIGN.md` inside the zip file.
> Summary below for quick reference.

### Colours

| Token | Hex | Usage |
|---|---|---|
| Background | `#0e0e10` | All screen backgrounds |
| Primary | `#1A73E8` | CTAs, progress bars, active states |
| Secondary / Accent | `#34A853` | Success, completed, won states |
| Danger | `#EA4335` | Errors, lost states, destructive actions |
| Amber | `#FBBC04` | Pending, in-progress, countdown timers |
| Surface low | `#1a1a1c` | Cards, bottom sheets |
| Surface mid | `#252528` | Nested cards |
| On-surface | `#FFFFFF` | Primary text |
| On-surface-variant | `#acaaad` | Secondary text, labels |

### Typography

- **Headlines / Display:** Space Grotesk — used for step counts, battle titles, level numbers
- **Body / Labels:** Manrope — used for descriptions, sub-labels, table data

### Component Rules

- **No 1px divider lines** — separation uses background colour shift only
- **Glassmorphism cards** — `surface-variant` at 60% opacity, `backdrop-blur` 20px,
  2px inner glow using primary at 20% opacity
- **Progress bars** — gradient fill from `#1A73E8` to lighter blue, spark/glow dot at
  leading edge
- **Battle cards** — `xl` corner radius, no dividers, `surface-container-highest` on
  active/winning state
- **Bottom sheets** — rounded top corners 28px, handle pill at top centre
- **Buttons primary** — gradient fill, `border-radius: full`, ambient glow on active
- **Buttons secondary** — `surface-container-high` background, no border
- **Buttons destructive** — red text, outlined style

---

## 4. Home Tab

### Purpose
The home tab is the daily dashboard. It shows the user's current step progress,
active battle, mission status, and a map preview at a glance.

### Navigation Bar
- **Top-left:** App name "StepBattle" with bolt lightning icon in primary blue
- **Top-right (first):** Streak badge — flame icon + current streak number (e.g. "7").
  Tapping opens a Streak History bottom sheet.
- **Top-right (second):** Profile avatar circle (user photo or initials).
  Tapping navigates to the Profile page.

### Section 1 — Overview Card

A prominent full-width glassmorphism card. It is the most important element on the screen.

**Contents:**
- **Level badge** (top-left inside card): pill label showing "Level 8". Updates on
  level-up with animation.
- **Step count** (centre, display-size font): today's total steps e.g. "6,000"
- **Sub-label:** "STEPS TODAY" in small caps below the number
- **XP delta line:** "+340 XP from Yesterday" with trending-up icon. Green if positive,
  red if negative.
- **Progress bar:** full-width bar showing % progress toward next level. Blue gradient
  fill with spark glow at leading edge.
- **Progress labels:** "LVL 9" (left) and "LVL 10" (right) above the bar.
  Below the bar: "2,400 steps to go" centred in grey.

**Below the card — Stat Pills Row (3 equal-width cards):**

| Pill | Value | Sub-label | On Tap |
|---|---|---|---|
| Calories | "400 kcal" | "Burnt Today" | No-op or health detail |
| Rank | "#3" | "Global Rank" | Navigate to Leaderboard tab |
| Missions | "2/3" | "Completed Today" | Navigate to Missions tab |

### Section 2 — Active Battle

**Section header:** "Active Battle" left-aligned + "● Live" green animated pill on right.

**State A — Active battle running:**
- Card content: opponent avatar, "You vs [Name]", "Day X of Y"
- Sub-line in primary blue: "You're leading by 1,200 steps" (or "You're behind by X steps")
- Button: "View Arena" pill button → opens that battle's bottom sheet in Battles tab

**State B — No active battle, show most recent completed:**
- Card content: "Last Battle · vs [Name]"
- Sub-line: "You won · +500 XP · 2 days ago" (or "You lost")
- Tap → opens battle recap in Battles tab

**State C — No battles at all:**
- Empty card with CTA button: "⚔️ Start a Battle"
- Sub-line: "Challenge a friend to a step battle"
- Tap → navigates to Battles tab

### Section 3 — Daily Missions

**Section header row:**
- Left: "Daily Missions" bold
- Right: chevron_right icon — tapping navigates to Missions tab

**Mission rows (3 rows, one per daily mission):**

Each row is a card containing:
- **Left icon** (40×40 rounded square): category icon (walk/fire/sword)
- **Mission title** (bold): e.g. "Walk 8,000 Steps"
- **XP reward** (right-aligned, green): e.g. "+100 XP"
- **Progress bar** (below, full width): animated fill showing current progress
- **Status:** "In Progress" amber / "Completed ✓" green / locked grey appearance

Default missions:
1. Walk 8,000 Steps — +100 XP — progress bar (e.g. 75% filled)
2. Burn 500 Calories — +75 XP — progress bar (e.g. 80% filled)
3. Complete a Battle — +150 XP — 0%, locked appearance if no battle started

**On tap any mission row:** opens Mission Detail bottom sheet for that mission.

**All missions complete banner:**
"✅ All missions complete! +150 XP earned today" — replaces the rows, green background.

### Section 4 — Map (Who's Leading Near You)

**Section header:** "Who's Leading Near You"

A map card showing a live fragment of the device map. User avatar pins are placed at
each active walker's location. The leading user pin has a gold ring. A sub-label shows
"👟 12 active walkers in your area".

**On tap:** Opens full-screen Snapchat-style map view (separate screen).

**Empty state (location permission denied):**
"Enable location to see who's leading near you" + "Enable Location" CTA button.

---

## 5. Battles Tab

### Purpose
Manages all step battles — active, scheduled, and completed. Also the entry point
for creating new battles.

### Navigation Bar
- **Title:** "Battles"
- **Top-right:** "+ New Battle" filled blue button → opens New Battle bottom sheet

### Section 1 — Active Battles

**Section header:** "Active Battles" + ">" chevron (expands full list)

**Battle card (one per active battle):**
- Battle ID chip: "BATTLE ID #8402" (small, top of card)
- Title: "⚔️ You vs [Opponent Name]"
- Status tag: "● Live" with animated green pulse dot
- Step counts row: "You: 6,820" and "[Opponent]: 9,100"
- **Dual-fill progress bar:** two-colour bar — your colour vs opponent colour,
  proportional to step delta
- Time remaining: "⏱ 8h left"
- Reward: "+200 XP on win"

**Tapping a card:** opens a battle detail bottom sheet showing live step sync.

**Empty state:** "No active battles right now" + "⚔️ Start a Battle" CTA.

### Section 2 — Scheduled Battles

**Section header:** "Scheduled Battles" + ">" chevron

**Battle card (one per scheduled battle):**
- Title: "⚔️ You vs [Name]"
- Status tag: "Pending" (amber pill)
- Start time: "Starts Saturday, 9:00 AM"
- Reward: "+150 XP on win"
- **Right-swipe gesture:** reveals "Cancel" destructive action with confirm dialog

**Empty state:** "No upcoming battles scheduled"

### Section 3 — Completed Battles

**Section header:** "Completed" + ">" chevron

**Battle card (one per completed battle):**
- Title: "⚔️ You vs [Name]"
- Result tag: "Won" (green pill) or "Lost" (red pill)
- Final step counts: "You: 15,000 · [Opponent]: 11,200"
- Frozen progress bar (non-interactive, final state)
- Completion info: "Completed yesterday"
- XP: "+200 XP earned" (if won) or "+0 XP" (if lost)

**Empty state:** "No completed battles yet — go win one!"

---

## 6. New Battle — Bottom Sheet Flow

### Trigger
Tapping "+ New Battle" in the Battles tab nav bar.

### Step 1 — New Battle Selection Sheet

**Sheet title:** "New Battle"
**Sub-label:** "Choose your battle format"

Two selectable cards side by side:
- **Card A:** 👤 icon, "1 vs 1", "Compete head-to-head with one friend"
- **Card B:** 👥 icon, "Group Battle", "Compete with multiple participants"

Selected card gets blue border + light blue fill. Unselected is grey outlined.

**"Continue" button** (full-width, blue): disabled until a card is selected.

### Step 2A — 1v1 Battle Setup Sheet

**Sheet title:** "1 vs 1"
**Battle ID:** "Battle ID: #A4X9" with copy-to-clipboard icon

**Player layout (horizontal):**
```
[ YOU — auto-filled, locked ]   vs   [ + Select Friend ]
```

The "Select Friend" slot is a dashed-border card. Tapping it opens the
Add Friends bottom sheet in single-select mode.

Below the layout:
- **Search field:** "Search by name or username"
- **Suggested Rivals list:** 3 rows each showing avatar, username, rank, avg steps, "+" button

**"Create Battle" button** (full-width, blue): disabled until Player 2 is selected.

**Note below button:** "Battle starts immediately after opponent accepts"

### Step 2B — Group Battle Setup Sheet

**Sheet title:** "GROUP BATTLE"
**Battle ID:** "Battle ID: #B7K2" with copy icon, settings icon top-right

**Participants section (full-width card):**
- Row 1: YOUR avatar + "YOU" label + "HOST" badge + "READY" green badge — locked
- Row 2: Dashed slot "+ Add Friend" — tappable → opens Add Friends sheet (multi-select)
- Row 3: Dashed slot "+ Add Friend" — tappable
- Caption: "ADD UP TO 10 PARTICIPANTS"

**Search field:** "Search by name or username"

**Suggested Friends list:** same as 1v1 list, multi-select

**"Invite Friends" button** (outlined, blue): shares Battle ID via system share sheet

**"Create Battle" button** (full-width, blue): disabled until at least 1 friend added

**Note:** "Battle starts when all participants accept"

---

## 7. Missions Tab

### Purpose
Tracks daily and weekly challenges. Missions reset on a timer. Completing missions
earns XP and motivates consistent daily activity.

### Navigation Bar
- **Title:** "Missions" (left)
- **Top-right:** "300 XP today" green pill badge (total XP earned today, tappable →
  XP breakdown sheet), flame icon + streak number, profile avatar

**Sub-header line:** "Daily missions reset in 4h 22m" — live countdown timer

### Section 1 — Daily Missions

**Section header:** "Daily"

**Mission card (one per daily mission):**
- **Left icon** (48×48 rounded, category-specific):
  - 👟 footprint for steps
  - ⚔️ sword for battle
  - 🔥 flame for streak
- **Mission title** (bold): e.g. "Walk 5,000 Steps"
- **Description** (grey, small): e.g. "Hit your daily step target"
- **XP reward** (right-aligned, green): "+100 XP"
- **Progress bar** (full-width, animated): fills proportionally
- **Progress label** (below bar): "3,200 / 5,000 steps" or "64%"
- **Status tag:**
  - "In Progress" — amber pill
  - "Completed ✓" — green pill
  - "Locked" — grey, dimmed card appearance

**On tap:** opens Mission Detail bottom sheet for that mission.

**Default daily missions:**
1. Walk 5,000 Steps — Hit your daily step target — +100 XP
2. Win a Battle — Defeat an opponent in a step battle — +150 XP
3. Keep Streak Alive — Log steps for another consecutive day — +50 XP

**All complete banner:** "✅ All daily missions complete! Come back tomorrow."

### Section 2 — Weekly Challenges

**Section header:** "Weekly"
**Sub-label:** "Resets Sunday at midnight"

**Challenge card:** same structure as daily mission card but taller.

**Default weekly challenges:**
1. Walk 50,000 Steps — Accumulate steps across the week — +500 XP — "32,000 / 50,000"
2. Win 3 Battles — Defeat 3 opponents this week — +400 XP — "1 / 3 battles"
3. Complete All Daily Missions 5 Days — Finish every daily mission 5 days in a row
   — +300 XP — "3 / 5 days"

---

## 8. Mission Detail Bottom Sheet

**Trigger:** Tapping any mission card in Missions tab or Home mission row.

### Contents

- **Sheet handle bar** at top centre
- **Large category icon** (60px glowing circle, centred)
- **Mission title** (large bold, Space Grotesk): e.g. "Walk 5,000 Steps"
- **Status badge:** "IN PROGRESS" (amber) or "COMPLETED ✓" (green)

**Progress card (full-width):**
- Label: "CURRENT PROGRESS"
- Value: "3,200 / 5,000 steps" (large, bold)
- Percentage: "64%" (right-aligned, primary blue)
- Progress bar: full-width, animated, gradient blue fill, spark at leading edge

**Detail grid (2-column rows):**
- XP Reward: "+100 XP on completion" (green)
- Resets In: "4h 22m" (amber, countdown)
- Category: "Daily Mission"
- Difficulty: "⭐ Easy"

**"How it works" section:**
Sub-heading + body text explaining how the mission is tracked, e.g.:
"StepBattle automatically tracks your movement using your device's pedometer.
You can also sync data from Apple Health or Google Fit to ensure every step
in your daily routine contributes to your competitive standing."

**CTA button (full-width):**
- Active state: blue filled "Go Walk Now" with walk icon
- Completed state: green filled "Completed ✓ · +100 XP Earned" (non-tappable)

---

## 9. Clan Tab

### Purpose
Lets users form teams (clans), manage members, and run clan vs clan step battles.

### State A — Entry Screen (user has no clan)

**Page title:** "Clan"

**Centre-aligned empty state:**
- Large shield illustration
- Heading: "Join the Battle Together"
- Sub-label: "Team up. Compete together. Dominate the leaderboard."

**Two full-width buttons (stacked):**
- "CREATE CLAN" — primary filled blue → opens Create Clan bottom sheet
- "JOIN CLAN" — secondary outlined → opens Join Clan bottom sheet

---

### Create Clan Bottom Sheet

**Sheet title:** "Create a Clan"
**Sub-label:** "Build your squad and dominate together"

**Fields:**
- **Clan Name input:**
  - Placeholder: "Enter clan name..."
  - Character counter right: "0 / 20"
  - Validation note: "3–20 characters, letters and numbers only"
- **Add Members section:**
  - Label: "ADD MEMBERS"
  - Button (outlined blue): "+ Add Friends" → opens Add Friends sheet (multi-select)
  - Sub-label: "Invite friends to join your clan"
  - **Selected members preview:** horizontal scroll row of avatar circles with name
    below each. Each avatar has a red "×" remove button top-right.

**Action buttons row:**
- "Cancel" (outlined, neutral) — dismisses sheet
- "Create" (filled blue, disabled until clan name is filled) — creates clan, navigates
  to Clan Dashboard

---

### Join Clan Bottom Sheet

**Sheet title:** "Join a Clan"
**Sub-label:** "Enter a Clan ID or search by name"

**Search / input field:**
- Placeholder: "Enter Clan ID (e.g. #CL7X9) or clan name"
- Search icon left, blue arrow-forward button right

**Clan result rows (after search):**
Each row: shield icon (unique clan colour), clan name bold, member count, clan XP,
"Join" pill button (blue).

**Empty state (before search):**
Shield icon + "Search for a clan above to get started"

**Bottom:**
"Cancel" full-width outlined button

---

### State B — Clan Dashboard (user is in a clan)

**Nav header:** "[Clan Name]" e.g. "TEAM ALPHA" + "5 / 10 members" sub-label
+ settings icon top-right

#### Sub-section 1 — Soldiers (Members)

**Section header:** "Soldiers"

**Member rows (one per member):**
- Avatar circle with initials or photo
- Display name (bold)
- Role badge: "Captain" (gold, creator only) or "Soldier" (grey)
- Steps today (right-aligned): "4,200 Steps"

**Bottom of list:**
- "+ Add Members" button row → opens Add Friends sheet (multi-select mode)
- **Clan ID chip:** "Clan ID: #CL7X9" with copy icon to clipboard

#### Sub-section 2 — Clan Battles

**Section header:** "Clan Battles"

**Active clan battle card (if battle running):**
- Matchup: "[Your Clan] ⚔️ vs [Opponent Clan]"
- Status: "● Live" green dot
- Step totals: "Your Clan: 42,000 · Night Runners: 38,500"
- Dual-fill progress bar
- "2 days left"
- Reward: "+300 XP per member on win"

**Action buttons row:**
- "⚔️ Create Battle" (filled blue) → opens Create Clan Battle screen
- "🔍 Join Battle" (outlined) → opens Join Clan Battle screen

---

## 10. Create Clan Battle Screen

**Nav:** Back arrow + "CREATE CLAN BATTLE" title

**Battle matchup hero card:**
```
[ Your Clan — OWNER badge ]    VS    [ SEARCH OPPONENT CLAN (dashed) ]
```
Tapping the dashed slot opens a search field.

**Search field:** "Find a rival clan..." with live results showing clan name, member
count, XP, "SELECT" button per row.

**Battle Configuration section:**

| Setting | Options |
|---|---|
| Duration | "1 Day" / "3 Days" (default selected) / "7 Days" |
| Battle Type | "Total Steps" / "Daily Average" — toggle |
| Reward Pool | "+300 XP" — auto-calculated, non-editable |

**Action buttons:**
- "CREATE BATTLE" (full-width, blue, disabled until opponent selected)
- "CANCEL" (full-width, outlined)

---

## 11. Join Clan Battle Screen

**Nav:** Back arrow + "BATTLE ARENA" / "Available Battles"

**Hero card:** "CLAN BATTLES" heading + "Join forces with your squad and dominate
the leaderboard." tagline

**Battle list (one card per available battle):**

Card A:
- Matchup: "Warriors vs Titans"
- Pills: "3-Day Battle" + "Starts Saturday 9AM"
- Urgency: "🟡 1 clan spot remaining" (amber)
- "JOIN" button (full-width, blue)

Card B:
- "Iron Walkers vs Storm Squad"
- "7-Day Battle · Starts Monday"
- "2 spots remaining"
- "JOIN" button

Card C (full):
- "Alpha vs Phantoms"
- "1-Day Battle · Live Now"
- "FULL" red tag — "JOIN" button disabled/greyed

**Empty state:** "No open clan battles right now" + "Create one instead →" CTA

**Bottom teaser:** "NEXT SEASON STARTS IN 48H" countdown

---

## 12. Leaderboard Tab

### Purpose
Shows XP-ranked lists globally and within the user's friend network.

### Navigation Bar
- **Title:** "LEADERBOARD"
- **Top-right:** Pill toggle "OVERALL | FRIENDS" — default: OVERALL

### Rank Table

**Column structure:** Rank · Avatar + Name · XP · ">" chevron

**Top 3 rows — special treatment:**
- Rank 1: 🥇 gold row highlight, larger avatar, bold name, "workspace_premium" badge
- Rank 2: 🥈 silver highlight
- Rank 3: 🥉 bronze highlight

**Ranks 4 onward:** standard list rows with rank number, avatar circle, name, XP, chevron.

**On tap any row:** opens Public Profile Card bottom sheet for that user.

### Friends Toggle
When "FRIENDS" is selected: same table structure but scoped to friends list only.

**Empty state (< 3 friends):** "Invite friends to see your ranking among them"
+ "Invite Friends" CTA

### Floating Your-Rank Card

**Always visible, pinned above the bottom tab bar while scrolling:**
- "#200" rank (large bold)
- "You ([Your Name])"
- "6,000 XP"
- "↑ 12 spots this week" (green, with trending-up icon)

### How to Earn More XP

**Trigger:** "?" help icon below the rank table

**Bottom sheet contents (table):**

| Action | XP Reward |
|---|---|
| Complete a daily mission | +50 XP |
| Win a 1 vs 1 battle | +200 XP |
| Maintain a 7-day streak | +100 XP |
| Reach daily step goal | +75 XP |
| Win a group battle | +300 XP |
| Complete all daily missions (bonus) | +150 XP |
| Win a clan battle (per member) | +300 XP |

---

## 13. Profile Page

### Access
Tapping the avatar circle in the top-right of any main screen.

### Navigation Bar
- **Title:** "Profile"
- **Top-right:** 🔥 + streak number (e.g. "9") — tappable → streak history sheet

### Section 1 — User Identity

- **Avatar circle** (large, centred): user photo or initials. Tappable → opens avatar
  picker sheet.
- **Username** + ✏️ edit icon: tapping opens rename bottom sheet.

**Stats strip (4 pills in a horizontal row):**

| Pill | Label | Example |
|---|---|---|
| 1 | Level | 8 |
| 2 | XP | 623 |
| 3 | Streak | 7 Day Streak |
| 4 | Rank | #3 |

### Section 2 — Set Goal

**Full-width button:** "Set Goal →" (outlined blue)

**On tap → Set Goal bottom sheet:**

- Sheet title: "Set Your Daily Step Goal"
- Sub-label: "Your current goal: 8,000 steps/day"
- **Large display number:** "8,000" (blue, display-size) + "STEPS PER DAY"
- **Delta pill:** "Same as yesterday" or "↑ 2,000 more than current"
- **Preset chips row (horizontal, scrollable):** "5K" | "8K" (selected) | "10K" | "15K"
  — tapping a chip updates the large number instantly
- **Custom input section:**
  - Label: "OR ENTER A CUSTOM GOAL"
  - Stepper: "−" | number input field "8000" | "+"
  - Each tap = ±500 steps
  - Min: 1,000 / Max: 50,000
- **Motivation card:** trophy icon + "Users who set a goal are 3× more likely to hit it."
- **Buttons:** "Cancel" (outlined) + "Save Goal" (filled blue, ambient glow)

### Section 3 — This Week Stats

**Section header:** "This Week" + 📅 calendar icon (right-aligned)

Calendar icon opens a date picker dialog — user selects a specific week to view.

**Stats table (label left, value right):**

| Label | Value |
|---|---|
| Total Steps | 3,000 |
| XP Earned | 200 XP |
| Battles Won | 2 / 3 |
| Missions Done | 7 / 10 |

### Section 4 — All Time Stats

**Section header:** "All Time"

| Label | Value |
|---|---|
| Total XP | 6,000 XP |
| Battles | 4 Won / 3 Lost |
| Best Streak | 21 Days |
| Total Steps | 2,01,500 |

### Section 5 — Account Details

**Section header:** "Account"

| Field | Value |
|---|---|
| Email | abc@gmail.com (non-editable) |
| Phone | +91 XXXXXXXXXX (editable) |
| Connected to | "Apple Health" / "Google Fit" — chip badge showing active integration |

### Section 6 — Sign Out

**Full-width button:** "Sign Out" — red text, outlined destructive style.

**On tap → Confirmation dialog:**
"Are you sure you want to sign out?"
Buttons: "Cancel" (dismiss) · "Sign Out" (red, confirm)

---

## 14. Add Friends Bottom Sheet (Reusable Component)

This is a **shared sheet** called from multiple places:
- Battles → 1v1 setup (single-select mode, label: "Select as Opponent")
- Battles → Group setup (multi-select mode, label: "Add to Battle")
- Clan → Create Clan (multi-select, label: "Add to Clan")
- Clan → Clan Dashboard → Add Members (multi-select, label: "Send Invite")
- Profile → Friends section → Add Friend

### Sheet Structure

**Title:** "Add Friends"

**Two-tab toggle:**
- Tab 1: "Friends List" (default selected, blue fill)
- Tab 2: "Search / User ID"

#### Tab 1 — Friends List

**Search bar:** "Search your friends..."

**Friend rows:**
- Avatar circle + display name (bold)
- Sub-label: "Level 8 · Rank #3 · 6.2k avg steps"
- Right button:
  - "+" (blue circle) — unselected state
  - "✓ Added" (green pill) — selected state

**Empty state:** "No friends yet. Use the Search tab to find people."

#### Tab 2 — Search / User ID

**Input field:** "Enter @username or User ID (e.g. #U4X92)"
Blue search button on right.

**Result rows:** same structure as friends list rows.
- If already friends: shows "✓ Friends" grey label instead of "+"
- If not friends: shows "Add Friend" button

**Bottom:**
- "Confirm Selection" (full-width, blue CTA)
- Note: "They'll receive an invite notification"

---

## 15. Public Profile Card Bottom Sheet

**Trigger:** Tapping any row in the Leaderboard table.

### Contents

- Avatar (large), display name, level badge, rank badge
- **Stats strip:** steps this week, battles won, best streak
- Two action buttons:
  - "+ Add Friend" → adds to friends list, button changes to "✓ Friends"
  - "⚔️ Challenge to Battle" → navigates to Battles tab, opens 1v1 setup with this
    user pre-filled as Player 2

---

## 16. Full-Screen Map View

**Trigger:** Tapping the map card in Home tab Section 4.

A Snapchat-style full-screen live map showing:
- User avatar pins at each active walker's location
- Step count bubble below each pin
- Leading user pin has gold ring
- Your own pin is highlighted in primary blue
- Tap any pin → shows that user's today step count + name card

**Bottom floating card:** "12 active walkers in your area"

---

## 17. XP & Levelling System

### XP Earn Events

| Action | XP | Condition |
|---|---|---|
| Every 1,000 steps | +10 XP | Continuous, auto-awarded |
| Reach daily step goal | +75 XP | Once per day |
| Complete a daily mission | +50–150 XP | Once per mission per day |
| Win a 1v1 battle | +200 XP | On battle conclusion |
| Win a group battle | +300 XP | On battle conclusion |
| Win a clan battle | +300 XP | Per member, on conclusion |
| Maintain 7-day streak | +100 XP | On 7th consecutive day |
| Complete all daily missions (bonus) | +150 XP | Once per day |
| Complete weekly challenge | +300–500 XP | Once per challenge per week |

### Level Thresholds

| Level | Cumulative XP | Unlock |
|---|---|---|
| 1 | 0 | App access |
| 2 | 500 | Battle invite |
| 3 | 1,200 | Group battles |
| 5 | 3,000 | Clan creation |
| 8 | 8,000 | Custom avatar frames |
| 10 | 15,000 | Elite leaderboard tier |
| 15 | 35,000 | Legendary badge |
| 20 | 75,000 | Hall of Fame |

---

## 18. Data Models

### User
```
userId: String
displayName: String
avatarURL: String?
email: String
phone: String?
level: Int
totalXP: Int
currentStreak: Int
bestStreak: Int
rank: Int
dailyStepGoal: Int          // default 8000
totalStepsAllTime: Int
friends: [String]           // list of userIds
clanId: String?
createdAt: Timestamp
```

### StepLog
```
logId: String
userId: String
date: Date                  // yyyy-MM-dd
stepCount: Int
calories: Int
source: String              // "healthkit" | "googlefit"
syncedAt: Timestamp
```

### Battle
```
battleId: String
type: String                // "1v1" | "group" | "clan"
status: String              // "pending" | "active" | "completed"
participants: [BattleParticipant]
  └── userId, displayName, avatarURL, currentSteps, isWinner
startTime: Timestamp
endTime: Timestamp
durationDays: Int
xpReward: Int
winnerId: String?
createdBy: String
```

### Mission
```
missionId: String
type: String                // "daily" | "weekly"
title: String
description: String
category: String            // "steps" | "battle" | "streak" | "calories"
targetValue: Int
xpReward: Int
difficulty: String          // "easy" | "medium" | "hard"
resetCycle: String          // "daily" | "weekly"
```

### UserMissionProgress
```
userId: String
missionId: String
currentValue: Int
targetValue: Int
isCompleted: Bool
completedAt: Timestamp?
periodStart: Date
```

### Clan
```
clanId: String
name: String
clanIdCode: String          // e.g. "#CL7X9" — public invite code
captainId: String
members: [ClanMember]
  └── userId, displayName, avatarURL, role ("captain"|"soldier"), stepsToday
totalClanXP: Int
activeBattleId: String?
createdAt: Timestamp
maxMembers: Int             // default 10
```

### ClanBattle
```
clanBattleId: String
status: String              // "pending" | "active" | "completed"
clanA: ClanBattleTeam
  └── clanId, clanName, totalSteps
clanB: ClanBattleTeam
startTime: Timestamp
endTime: Timestamp
durationDays: Int
battleType: String          // "total_steps" | "daily_average"
xpPerMember: Int
winnerClanId: String?
```

---

## 19. Functional Rules & Business Logic

### Step Tracking
- Steps are polled from HealthKit / Health Connect every 10 minutes in the background
- For active battles: step counts sync to Firestore every 5 minutes
- Steps are stored as daily logs (one document per user per day)
- Calories are derived from step count using a standard formula (steps × 0.04 kcal)

### Battle Rules
- A 1v1 battle starts when the opponent accepts the invite
- A group battle starts when the creator taps "Create Battle" (others can join within
  the first hour)
- Battle ends at `endTime` — whoever has more steps wins
- Ties go to the person with the higher step count in the final hour
- XP is awarded immediately on conclusion
- Battles cannot be cancelled once active

### Mission Reset Logic
- Daily missions reset at midnight in the user's local timezone
- Weekly missions reset at midnight Sunday in the user's local timezone
- If a mission is completed, it shows "Completed ✓" until reset, not locked

### Streak Logic
- Streak increments if the user logs ≥ 1 step on each consecutive day
- Streak breaks if a full calendar day passes with 0 steps synced
- Streak is maintained even if the daily goal is not reached
- Streak bonus XP (+100) is awarded on the 7th day and every 7th day thereafter

### Clan Rules
- Only users at Level 5+ can create a clan
- Clan capacity is 10 members by default
- The creator is automatically the Captain
- Only the Captain can create clan battles or remove members
- A clan can only have 1 active clan battle at a time

### Leaderboard Ranking
- Global rank is determined by total all-time XP descending
- Friends rank is the same but scoped to the user's friends list
- Ranks update every 15 minutes (not real-time)
- The user's own rank card is always pinned at the bottom, even if they are rank #1

---

## 20. Key UX Rules

### Navigation
- Bottom sheet overlays: all creation flows, detail views, and secondary interactions
  use bottom sheets — NOT full-screen pushes (except Map, Create Clan Battle,
  Join Clan Battle which are full screens)
- Back navigation: always available via back arrow or swipe-down on sheets
- Tab switching: any card/pill that navigates to another tab should also deep-link
  to the relevant section within that tab (e.g. Home missions row → Missions tab
  with that mission's sheet pre-opened)

### Empty States
- Every list section must have a defined empty state with a relevant CTA
- Empty states are never blank screens

### Loading States
- Step counts and leaderboard show shimmer skeleton loaders
- Battle cards show last-known data while refreshing (stale-while-revalidate)

### Error States
- Network error: "Could not sync steps — tap to retry" banner
- HealthKit permission denied: persistent banner with "Enable Health Access" CTA

### Haptics
- Light impact on all card taps
- Medium impact on battle win/XP earn animations
- Heavy impact on level-up

---

## 21. For Claude Code — Build Instructions

### Step 1 — Read the Visual Reference
Unzip `stitch_stepbattle__1_.zip`. For each folder, read `code.html` for the UI
structure and `screen.png` for the visual. The `titanium_velocity/DESIGN.md` file
contains the design system spec.

### Step 2 — Decide Tech Stack
This README does not mandate a specific framework. Evaluate and recommend:
- Flutter (preferred) vs React Native
- Firebase vs Supabase for backend
- State management approach
- Health data package
Present the recommendation before writing any application code.

### Step 3 — Confirm Before Proceeding
After presenting the tech stack, stop and wait for confirmation.

### Step 4 — Scaffold
Create the full project structure and configuration files first
(pubspec.yaml or package.json, theme, colours, typography, routing).

### Step 5 — Build in Order
1. Foundation (theme, colours, typography, routing, nav bar)
2. Data models
3. Services (auth, health, Firestore, notifications)
4. Home tab
5. Battles tab + all battle sheets
6. Missions tab + mission detail sheet
7. Clan tab + all clan flows
8. Leaderboard tab
9. Profile page + all profile sheets
10. Add Friends sheet (shared component)
11. Map screen
12. Polish (animations, haptics, empty states, error states)

### Step 6 — One Feature at a Time
Build one screen or one sheet completely (UI + logic + state) before moving to
the next. Do not scaffold empty files for all screens upfront.

---

*Last updated: April 2025*
*Visual reference: stitch_stepbattle__1_.zip (17 screens)*