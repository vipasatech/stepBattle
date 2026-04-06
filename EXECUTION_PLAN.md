# StepBattle — Complete Technical Execution Plan

---

## SECTION 1 — Tech Stack Decision

### 1.1 Frontend Framework: Flutter

| Factor | Flutter | React Native |
|---|---|---|
| HealthKit/Health Connect | `health` package — mature, unified API for both platforms | `react-native-health` (iOS) + `react-native-health-connect` (Android) — two separate packages |
| Real-time battle step sync | Dart Streams + Riverpod map naturally to live Firestore listeners | Achievable but requires more glue code (useEffect + subscriptions) |
| Map rendering | `google_maps_flutter` — first-party Google plugin, performant | `react-native-maps` — solid, but bridge overhead on heavy pin updates |
| Bottom sheet complexity | 9 bottom sheets with glassmorphism — Flutter's `showModalBottomSheet` + `BackdropFilter` is native and performant | `@gorhom/bottom-sheet` works but glassmorphism/blur is GPU-expensive through the bridge |
| Animations (XP earn, level-up) | Built-in `AnimationController`, Rive, Lottie — all first-class | Reanimated 3 is powerful but debugging is harder |
| Single codebase | True single codebase — same rendering engine on both platforms | Native components differ per platform, more divergence |
| Typography/design precision | Pixel-perfect control via `CustomPainter`, no platform deviations | Platform-specific text rendering can cause inconsistencies |

**Recommendation: Flutter.** The combination of glassmorphism-heavy UI, dual health platform integration, real-time battle sync, and heavy animation requirements all favour Flutter's rendering engine and unified API approach.

### 1.2 Language: Dart

Dart follows directly from Flutter. It's type-safe, null-safe, and async/await is first-class — ideal for handling Firestore streams and health data callbacks.

### 1.3 State Management: Riverpod

| Option | Fit for StepBattle |
|---|---|
| **Riverpod** | StreamProvider maps directly to Firestore real-time listeners (battle sync, leaderboard). FutureProvider for one-time fetches (profile, stats). StateNotifier for local UI state (bottom sheet forms). Compile-safe, testable, no BuildContext dependency. |
| BLoC | More boilerplate for this app's needs. Events/States pattern is overkill for simple data streams. |
| Provider | Riverpod is its successor. Provider lacks auto-dispose and compile-time safety. |

**Recommendation: Riverpod (with code generation via `riverpod_annotation`).**

### 1.4 Navigation / Routing: GoRouter

| Option | Fit |
|---|---|
| **go_router** | Declarative, supports deep linking (push notification → specific battle), shell routes for the 5-tab layout, maintained by the Flutter team |
| auto_route | More code generation overhead; deep linking support is comparable |
| Navigator 2.0 raw | Too low-level for a 5-tab app with 9+ sheets |

**Recommendation: go_router.** `StatefulShellRoute` handles the 5-tab persistent bottom nav perfectly. Deep linking (e.g., notification → `/battles/8402`) is built-in.

### 1.5 Backend: Firebase

| Factor | Firebase | Supabase |
|---|---|---|
| Real-time battle leaderboards | Firestore real-time listeners — purpose-built for this | Supabase Realtime works but is newer, less battle-tested |
| Push notifications | FCM is deeply integrated with Firebase | Requires separate push service |
| Auth | Firebase Auth — Google, Apple, Email all built-in | Supabase Auth — equivalent |
| Cloud Functions | Cloud Functions for Firebase — Firestore triggers, scheduled functions | Edge Functions — less mature ecosystem |
| Offline support | Firestore has built-in offline persistence | Supabase offline is manual |

**Recommendation: Firebase.** Real-time Firestore listeners are the core of battle sync and leaderboard. FCM integration for push. Cloud Functions for battle conclusion logic. Offline persistence is critical for step tracking.

### 1.6 Health Data

| Platform | Package | Notes |
|---|---|---|
| Both | `health: ^10.x` | Unified API for Apple HealthKit + Google Health Connect. Read steps, calories, activity. |

**Background sync strategy:**
- Use `workmanager` package for periodic background tasks (every 15 minutes)
- On each background task: read step count from `health` package, write delta to local cache (Hive), attempt Firestore sync
- During active battles: increase sync frequency to every 5 minutes using a foreground isolate
- iOS: Register for HealthKit background delivery for step count updates
- Android: Use Health Connect's change notifications

### 1.7 Maps: google_maps_flutter

Google Maps supports custom dark styling via JSON, is the most performant Flutter map plugin, and has the widest coverage.

### 1.8 Push Notifications

| Layer | Choice |
|---|---|
| Service | Firebase Cloud Messaging (FCM) |
| Flutter package | `firebase_messaging` + `flutter_local_notifications` |

Handles: battle invites, mission reset reminders, level-up alerts, clan battle results.

### 1.9 Animations

| Package | Usage |
|---|---|
| `rive` or `lottie` | XP earn animation, level-up celebration |
| Flutter built-in `AnimatedBuilder` / `AnimationController` | Progress bar fills, number counting animations, pulse effects |
| `confetti_widget` | Level-up confetti burst |

### 1.10 Local Storage

| Data | Package | Reason |
|---|---|---|
| Step log cache, user profile, mission state | `hive` + `hive_flutter` | Fast key-value store, no native bridge overhead, works offline |
| Secure tokens | `flutter_secure_storage` | Encrypted storage for auth tokens |
| Firestore offline | Built-in Firestore persistence | Automatically caches Firestore documents |

### Final Tech Stack Table

| Layer | Choice | Package(s) | Reason |
|---|---|---|---|
| Framework | Flutter | `flutter` | Pixel-perfect glassmorphism UI, single codebase, best health integration |
| Language | Dart | — | Type-safe, null-safe, async-first |
| State Management | Riverpod | `flutter_riverpod`, `riverpod_annotation` | Stream-first for real-time battles, auto-dispose, compile-safe |
| Routing | GoRouter | `go_router` | StatefulShellRoute for 5 tabs, deep linking for push notifications |
| Backend | Firebase | `firebase_core`, `cloud_firestore`, `firebase_auth` | Real-time listeners, offline persistence, FCM, Cloud Functions |
| Auth | Firebase Auth | `firebase_auth`, `google_sign_in`, `sign_in_with_apple` | Google + Apple + Email sign-in |
| Health Data | Health package | `health` | Unified HealthKit + Health Connect API |
| Background Tasks | Workmanager | `workmanager` | Periodic step sync in background |
| Maps | Google Maps | `google_maps_flutter` | Dark-styled map, avatar pins, best Flutter support |
| Push Notifications | FCM | `firebase_messaging`, `flutter_local_notifications` | Battle invites, mission reminders, level-up alerts |
| Animations | Rive + Flutter built-in | `rive`, `confetti_widget` | XP/level-up animations, progress bar fills |
| Local Storage | Hive | `hive`, `hive_flutter` | Offline step cache, mission state |
| Secure Storage | Flutter Secure Storage | `flutter_secure_storage` | Auth tokens |
| Location | Geolocator | `geolocator`, `geocoding` | Map feature, nearby users |
| Icons | Material Symbols | `material_symbols_icons` | Matches Stitch prototype icon system |

---

## SECTION 2 — Project Structure

```
stepbattle/
├── android/                          # Android native configuration
├── ios/                              # iOS native configuration (HealthKit entitlement)
├── lib/
│   ├── main.dart                     # App entry point, Firebase init, ProviderScope
│   ├── app.dart                      # MaterialApp.router, GoRouter setup, theme
│   │
│   ├── config/
│   │   ├── theme.dart                # ThemeData: colours, typography, component themes
│   │   ├── colors.dart               # All design tokens from DESIGN.md
│   │   ├── typography.dart           # Space Grotesk + Manrope text styles
│   │   ├── routes.dart               # GoRouter route definitions + deep link config
│   │   └── constants.dart            # XP thresholds, level table, mission defaults, timing
│   │
│   ├── models/
│   │   ├── user_model.dart           # User data model
│   │   ├── step_log_model.dart       # StepLog data model
│   │   ├── battle_model.dart         # Battle + BattleParticipant data model
│   │   ├── mission_model.dart        # Mission definition data model
│   │   ├── user_mission_progress_model.dart  # User progress on missions
│   │   ├── clan_model.dart           # Clan + ClanMember data model
│   │   ├── clan_battle_model.dart    # ClanBattle + ClanBattleTeam data model
│   │   ├── friend_relationship_model.dart    # Friend request/relationship
│   │   ├── notification_model.dart   # Push notification payload model
│   │   └── leaderboard_entry_model.dart      # Rank + XP snapshot
│   │
│   ├── services/
│   │   ├── auth_service.dart         # Firebase Auth: signIn, signOut, onAuthStateChanged
│   │   ├── health_service.dart       # HealthKit/Health Connect: permissions, steps, calories, bg sync
│   │   ├── step_service.dart         # Sync steps to Firestore, get history, daily total
│   │   ├── battle_service.dart       # CRUD battles, real-time listener, conclude
│   │   ├── mission_service.dart      # Get missions, listen to progress, claim reward
│   │   ├── clan_service.dart         # Create/join clan, members, clan battles
│   │   ├── leaderboard_service.dart  # Global ranks, friends ranks, my rank
│   │   ├── friend_service.dart       # Search, send/accept requests, get friends list
│   │   ├── notification_service.dart # FCM: request permission, subscribe, handle
│   │   ├── map_service.dart          # Nearby users, location updates
│   │   └── xp_service.dart           # XP calculation, level-up detection
│   │
│   ├── providers/
│   │   ├── auth_provider.dart        # Riverpod providers for auth state
│   │   ├── user_provider.dart        # Current user data provider
│   │   ├── step_provider.dart        # Today's steps, step history streams
│   │   ├── battle_provider.dart      # Active battles stream, battle detail
│   │   ├── mission_provider.dart     # Daily/weekly missions + progress streams
│   │   ├── clan_provider.dart        # Clan data, members, clan battle stream
│   │   ├── leaderboard_provider.dart # Ranked list providers (global + friends)
│   │   ├── friend_provider.dart      # Friends list, search results
│   │   ├── map_provider.dart         # Nearby users, location state
│   │   └── notification_provider.dart # Notification state
│   │
│   ├── screens/
│   │   ├── shell/
│   │   │   └── main_shell.dart       # Scaffold with persistent BottomNavigationBar (5 tabs)
│   │   │
│   │   ├── home/
│   │   │   ├── home_screen.dart      # Home tab: overview card, stats, active battle, missions, map
│   │   │   └── widgets/
│   │   │       ├── overview_card.dart
│   │   │       ├── stat_pills_row.dart
│   │   │       ├── active_battle_card.dart
│   │   │       ├── daily_missions_section.dart
│   │   │       └── map_preview_card.dart
│   │   │
│   │   ├── battles/
│   │   │   ├── battles_screen.dart
│   │   │   └── widgets/
│   │   │       ├── active_battle_card.dart
│   │   │       ├── scheduled_battle_card.dart
│   │   │       └── completed_battle_card.dart
│   │   │
│   │   ├── missions/
│   │   │   ├── missions_screen.dart
│   │   │   └── widgets/
│   │   │       ├── daily_mission_card.dart
│   │   │       └── weekly_challenge_card.dart
│   │   │
│   │   ├── clan/
│   │   │   ├── clan_screen.dart
│   │   │   ├── clan_entry_view.dart
│   │   │   ├── clan_dashboard_view.dart
│   │   │   └── widgets/
│   │   │       ├── member_row.dart
│   │   │       └── clan_battle_card.dart
│   │   │
│   │   ├── leaderboard/
│   │   │   ├── leaderboard_screen.dart
│   │   │   └── widgets/
│   │   │       ├── podium_section.dart
│   │   │       ├── rank_row.dart
│   │   │       └── floating_rank_card.dart
│   │   │
│   │   ├── profile/
│   │   │   ├── profile_screen.dart
│   │   │   └── widgets/
│   │   │       ├── user_identity_section.dart
│   │   │       ├── this_week_stats.dart
│   │   │       ├── all_time_stats.dart
│   │   │       └── account_details.dart
│   │   │
│   │   ├── map/
│   │   │   └── full_map_screen.dart
│   │   │
│   │   ├── clan_battle/
│   │   │   ├── create_clan_battle_screen.dart
│   │   │   └── join_clan_battle_screen.dart
│   │   │
│   │   └── auth/
│   │       ├── login_screen.dart
│   │       └── onboarding_screen.dart
│   │
│   ├── sheets/
│   │   ├── new_battle_selection_sheet.dart
│   │   ├── battle_1v1_setup_sheet.dart
│   │   ├── battle_group_setup_sheet.dart
│   │   ├── mission_detail_sheet.dart
│   │   ├── set_goal_sheet.dart
│   │   ├── create_clan_sheet.dart
│   │   ├── join_clan_sheet.dart
│   │   ├── add_friends_sheet.dart
│   │   ├── public_profile_sheet.dart
│   │   ├── xp_breakdown_sheet.dart
│   │   └── streak_history_sheet.dart
│   │
│   └── widgets/
│       ├── glass_card.dart
│       ├── progress_bar.dart
│       ├── dual_fill_bar.dart
│       ├── status_pill.dart
│       ├── shimmer_loader.dart
│       ├── empty_state.dart
│       ├── avatar_circle.dart
│       └── bottom_sheet_handle.dart
│
├── functions/                         # Firebase Cloud Functions (Node.js/TypeScript)
│   ├── src/
│   │   ├── index.ts
│   │   ├── battle_conclusion.ts
│   │   ├── leaderboard_recalc.ts
│   │   ├── mission_evaluation.ts
│   │   ├── mission_reset.ts
│   │   ├── streak_check.ts
│   │   ├── notification_dispatcher.ts
│   │   ├── clan_battle_conclusion.ts
│   │   └── step_ingestion.ts
│   ├── package.json
│   └── tsconfig.json
│
├── pubspec.yaml
├── firebase.json
├── firestore.rules
├── firestore.indexes.json
└── .firebaserc
```

---

## SECTION 3 — Backend Architecture

### 3.1 Authentication Flow

```
App Launch → Check Auth State → Signed In?
  YES → Main Shell
  NO  → Login Screen → Google/Apple/Email → User doc exists?
    YES → Main Shell
    NO  → Onboarding (set username, connect health, set goal) → Create user doc → Main Shell
```

Session persistence: Firebase Auth persists sessions automatically.
Token refresh: Firebase SDK handles ID token refresh automatically (tokens expire every 1 hour).

### 3.2 Firestore Database Schema

#### Collection: `users`

| Field | Type | Constraints |
|---|---|---|
| `userId` | `string` | Document ID = Firebase Auth UID |
| `displayName` | `string` | 3–20 chars, unique |
| `avatarURL` | `string?` | Nullable |
| `email` | `string` | From auth provider |
| `phone` | `string?` | Nullable |
| `level` | `number` | Default 1 |
| `totalXP` | `number` | Default 0 |
| `currentStreak` | `number` | Default 0 |
| `bestStreak` | `number` | Default 0 |
| `rank` | `number` | Updated by scheduled function |
| `dailyStepGoal` | `number` | Default 8000 |
| `totalStepsAllTime` | `number` | Default 0 |
| `friends` | `array<string>` | List of userIds |
| `clanId` | `string?` | Nullable |
| `createdAt` | `timestamp` | |
| `lastActiveAt` | `timestamp` | |
| `location` | `geopoint?` | For map feature |

- Indexes: `totalXP` desc, `displayName` asc, `clanId`
- Security: User read/write own doc. Friends read limited fields. Rank only writable by Cloud Functions.
- Est. doc size: ~500 bytes | Write freq: ~every 15 min

#### Collection: `step_logs`

| Field | Type | Constraints |
|---|---|---|
| `logId` | `string` | Auto ID |
| `userId` | `string` | |
| `date` | `string` | `yyyy-MM-dd` |
| `stepCount` | `number` | |
| `calories` | `number` | steps × 0.04 |
| `source` | `string` | `"healthkit"` / `"healthconnect"` |
| `syncedAt` | `timestamp` | |

- Indexes: `userId` + `date` desc
- Est. doc size: ~200 bytes | Write freq: every 5–15 min per active user

#### Collection: `battles`

| Field | Type | Constraints |
|---|---|---|
| `battleId` | `string` | Auto-generated code |
| `type` | `string` | `"1v1"`, `"group"` |
| `status` | `string` | `"pending"`, `"active"`, `"completed"` |
| `participants` | `array<map>` | `{userId, displayName, avatarURL, currentSteps, isWinner}` |
| `startTime` | `timestamp` | |
| `endTime` | `timestamp` | |
| `durationDays` | `number` | |
| `xpReward` | `number` | |
| `winnerId` | `string?` | |
| `createdBy` | `string` | |

- Indexes: `status` + participant userId, `status` + `endTime`
- Est. doc size: ~800B–2KB | Write freq: every 5 min during active battles

#### Collection: `missions`

| Field | Type |
|---|---|
| `missionId` | `string` |
| `type` | `string` (`"daily"` / `"weekly"`) |
| `title` | `string` |
| `description` | `string` |
| `category` | `string` (`"steps"` / `"battle"` / `"streak"` / `"calories"`) |
| `targetValue` | `number` |
| `xpReward` | `number` |
| `difficulty` | `string` |
| `resetCycle` | `string` |

- Rarely written (admin only). All users can read.

#### Collection: `user_mission_progress`

| Field | Type |
|---|---|
| `userId` | `string` |
| `missionId` | `string` |
| `currentValue` | `number` |
| `targetValue` | `number` |
| `isCompleted` | `boolean` |
| `completedAt` | `timestamp?` |
| `periodStart` | `string` (yyyy-MM-dd) |

- Indexes: `userId` + `periodStart`

#### Collection: `clans`

| Field | Type |
|---|---|
| `clanId` | `string` |
| `name` | `string` (3–20 chars) |
| `clanIdCode` | `string` (e.g. `#CL7X9`) |
| `captainId` | `string` |
| `memberIds` | `array<string>` |
| `totalClanXP` | `number` |
| `activeBattleId` | `string?` |
| `createdAt` | `timestamp` |
| `maxMembers` | `number` (default 10) |

- Subcollection `members/`: `{userId, displayName, avatarURL, role, stepsToday}`

#### Collection: `clan_battles`

| Field | Type |
|---|---|
| `clanBattleId` | `string` |
| `status` | `string` |
| `clanA` | `map` (`{clanId, clanName, totalSteps}`) |
| `clanB` | `map` |
| `startTime` | `timestamp` |
| `endTime` | `timestamp` |
| `durationDays` | `number` |
| `battleType` | `string` (`"total_steps"` / `"daily_average"`) |
| `xpPerMember` | `number` (default 300) |
| `winnerClanId` | `string?` |

#### Collection: `friend_relationships`

| Field | Type |
|---|---|
| `relationshipId` | `string` |
| `fromUserId` | `string` |
| `toUserId` | `string` |
| `status` | `string` (`"pending"` / `"accepted"` / `"rejected"`) |
| `createdAt` | `timestamp` |

#### Collection: `notifications`

| Field | Type |
|---|---|
| `notificationId` | `string` |
| `userId` | `string` (recipient) |
| `type` | `string` |
| `title` | `string` |
| `body` | `string` |
| `data` | `map` (deep link data) |
| `read` | `boolean` |
| `createdAt` | `timestamp` |

#### Collection: `leaderboard_snapshots`

| Field | Type |
|---|---|
| `userId` | `string` (document ID) |
| `displayName` | `string` |
| `avatarURL` | `string?` |
| `totalXP` | `number` |
| `rank` | `number` |
| `updatedAt` | `timestamp` |

- Indexes: `rank` asc, `totalXP` desc. Written every 15 min by Cloud Function.

### 3.3 Cloud Functions

| Function | Trigger | What It Does |
|---|---|---|
| `concludeBattle` | Scheduled every 1 min | Checks battles where `endTime <= now` AND `status == "active"`. Determines winner, awards XP, sends push notification. |
| `recalculateLeaderboard` | Scheduled every 15 min | Queries all users by `totalXP` desc, writes rank to `leaderboard_snapshots`. |
| `evaluateMissionProgress` | Scheduled at midnight (per timezone) | Reads step_logs, checks battle wins, checks streak. Updates `user_mission_progress`. Awards XP for completions. |
| `resetDailyMissions` | Scheduled midnight daily | Resets daily `user_mission_progress` docs. |
| `resetWeeklyMissions` | Scheduled midnight Sunday | Resets weekly `user_mission_progress` docs. |
| `checkStreaks` | Scheduled 2 AM daily | Checks yesterday step_log. Increments or breaks streak. Awards +100 XP on every 7th day. |
| `dispatchNotification` | Firestore trigger on `notifications` create | Sends FCM push with title, body, deep link. |
| `concludeClanBattle` | Scheduled every 1 min | Checks clan battles at endTime. Sums member steps. Awards XP to all winning clan members. |
| `ingestSteps` | HTTP callable | Validates + writes step_log. Updates `totalStepsAllTime`. Updates battle participant steps. |

### 3.4 Real-time Listeners vs One-time Fetch

| Screen / Data | Pattern |
|---|---|
| Home — user doc (steps, XP, level) | **Real-time** listener |
| Home — active battle | **Real-time** listener |
| Home — mission progress | **Real-time** listener |
| Home — map nearby users | One-time fetch |
| Battles — active list | **Real-time** listener |
| Battles — scheduled/completed | One-time fetch |
| Battle detail — live steps | **Real-time** listener |
| Missions — progress | **Real-time** listener |
| Clan — members | **Real-time** listener |
| Clan — active battle | **Real-time** listener |
| Leaderboard | One-time fetch (paginated) |
| Profile | One-time fetch |
| Add Friends search | One-time fetch |

### 3.5 Offline Strategy

| Scenario | Behaviour |
|---|---|
| Steps tracked | `health` package reads from device store regardless of network. `workmanager` stores locally in Hive. |
| Data queue + sync | Firestore SDK queues writes locally. On reconnect, queued writes flush automatically. |
| Home tab | Shows last-known data from cache. Step count updates from local health data. |
| Battles | Show last-known opponent steps. "Network error" banner with retry. Own steps accumulate locally. |
| Missions | Progress bars update locally from step count. Completion deferred until online. |
| Leaderboard | Shows cached data with "Last updated" label. |
| Map | Degrades — "Connect to internet to see nearby walkers". |
| Create/Join flows | Disabled with "No internet connection" on buttons. |

---

## SECTION 4 — Feature-by-Feature Implementation Plan

### 4.1 Step Tracking + Health Sync
- Reads: Device health store
- Writes: `step_logs`, `users.totalStepsAllTime`
- State: `stepProvider` StreamProvider
- Foreground poll every 60s, background every 15 min, active battle every 5 min
- Edge cases: permission denied, no pedometer, timezone change, multi-source dedup

### 4.2 XP Calculation + Level-up
- Reads: `users.totalXP`, threshold table
- Writes: `users.totalXP`, `users.level`
- Atomic increment for concurrent XP events. Level-up animation fires once per boundary.

### 4.3 Streak Tracking
- Cloud Function checks yesterday's step_log at 2 AM
- Increments or resets `currentStreak`. Awards +100 XP every 7th day.
- Edge case: timezone changes (use user's registered timezone)

### 4.4 Home Tab — Overview Card + Stat Pills
- Combines user provider + step provider + mission provider
- Shows level, step count, XP delta, progress to next level, calories, rank, missions

### 4.5 Active Battle Card on Home
- StreamProvider from first active battle
- 3 states: active battle, last completed, no battles (CTA)

### 4.6 Daily Missions Section on Home
- 3 mission rows with progress bars from real-time mission progress
- "All complete" banner when all done

### 4.7 Map Snapshot on Home
- One-time fetch of nearby users. Location permission gate.

### 4.8 Battles Tab
- 3 sections: active (real-time), scheduled (fetch), completed (paginated fetch)
- Empty states for each

### 4.9 New Battle Creation
- Two flows: 1v1 (single friend select) and group (multi-select, up to 10)
- Writes new battle doc. Disabled until opponent selected.

### 4.10 Battle Real-time Sync
- StreamProvider on `battles/{id}`. Steps update every 5 min via `ingestSteps`.
- Shows "Last updated" timestamp for staleness.

### 4.11 Battle Conclusion
- Cloud Function determines winner at endTime. Awards XP. Sends push.
- Tie: final hour tiebreaker. Idempotent XP write.

### 4.12 Missions Tab
- Daily + weekly sections with live progress. Countdown timer for reset.

### 4.13 Mission Detail Sheet
- Single mission progress, "How it works" text, "Go Walk Now" CTA.

### 4.14 Mission Progress Evaluation
- Cloud Function at midnight: reads steps, battles, streak. Updates progress docs.

### 4.15 Mission Reset
- Daily at midnight, weekly on Sunday. Client receives update via listener.

### 4.16 Clan — Create
- Level 5+ required. Name validation. Auto-generated clan code. Captain = creator.

### 4.17 Clan — Join
- Search by code or name. Clan full check (10 max).

### 4.18 Clan Dashboard
- Real-time member list with steps. Captain can remove members.

### 4.19 Clan Battle Creation
- Search opponent clan. Configure duration (1/3/7 days) and type (total/avg).

### 4.20 Clan Battle Join
- Browse available battles. Fill opponent slot. Real-time step aggregation during battle.

### 4.21 Clan Battle Conclusion
- Cloud Function sums member steps. Awards XP to all winning clan members.

### 4.22 Leaderboard — Global
- Paginated from `leaderboard_snapshots`. Top 3 special treatment.

### 4.23 Leaderboard — Friends
- Same structure filtered by friends list.

### 4.24 Floating My-Rank Card
- Pinned above bottom nav. Shows rank, XP, weekly change.

### 4.25 Profile — This Week Stats
- Aggregated from step_logs + battles + missions for current week.

### 4.26 Profile — All Time Stats
- From user doc: totalXP, battles won/lost, bestStreak, totalSteps.

### 4.27 Set Goal Flow
- Presets (5K/8K/10K/15K) + custom input (±500 stepper). Min 1K, max 50K.

### 4.28 Add Friends
- Reusable sheet. Two tabs: Friends List + Search/User ID.
- Single-select mode (1v1 battle) vs multi-select mode (group/clan).

### 4.29 Full-Screen Map
- Google Maps dark style. Avatar pins. Leading user gold ring. Own pin blue.

### 4.30 Push Notifications
- FCM. Types: battle invite, result, level-up, clan result, mission reset.
- Deep link routing on tap.

---

## SECTION 5 — API / Service Layer Design

```dart
abstract class AuthService {
  Future<User?> signInWithGoogle();
  Future<User?> signInWithApple();
  Future<User?> signInWithEmail(String email, String password);
  Future<void> signOut();
  User? get currentUser;
  Stream<User?> onAuthStateChanged();
}

abstract class HealthService {
  Future<bool> requestPermissions();
  Future<int> getTodaySteps();
  Future<int> getCalories({required DateTime date});
  Future<List<StepLog>> getStepHistory({required DateTime from, required DateTime to});
  Future<void> startBackgroundSync();
  Future<void> stopBackgroundSync();
  bool get isAuthorized;
}

abstract class StepService {
  Future<void> syncStepsToBackend({required String userId, required int steps, required DateTime date});
  Future<List<StepLog>> getStepHistory({required String userId, required DateTime from, required DateTime to});
  Stream<int> watchTodaySteps({required String userId});
  Future<int> getDailyTotal({required String userId, required DateTime date});
}

abstract class BattleService {
  Future<Battle> createBattle({required String type, required List<String> participantIds, required int durationDays});
  Future<void> acceptBattle({required String battleId, required String userId});
  Future<void> cancelBattle({required String battleId});
  Future<List<Battle>> getBattles({required String userId, required String status});
  Stream<Battle> listenToBattle({required String battleId});
  Future<void> updateParticipantSteps({required String battleId, required String userId, required int steps});
}

abstract class MissionService {
  Future<List<Mission>> getDailyMissions();
  Future<List<Mission>> getWeeklyMissions();
  Stream<List<UserMissionProgress>> listenToProgress({required String userId, required String periodStart});
  Future<void> claimReward({required String userId, required String missionId});
}

abstract class ClanService {
  Future<Clan> createClan({required String name, required List<String> memberIds});
  Future<void> joinClan({required String clanId, required String userId});
  Future<void> leaveClan({required String clanId, required String userId});
  Stream<List<ClanMember>> watchMembers({required String clanId});
  Future<void> addMember({required String clanId, required String userId});
  Future<void> removeMember({required String clanId, required String userId});
  Future<ClanBattle> createClanBattle({required String clanId, required String opponentClanId, required int durationDays, required String battleType});
  Future<void> joinClanBattle({required String clanBattleId, required String clanId});
  Future<List<ClanBattle>> getAvailableClanBattles();
  Stream<ClanBattle> listenToClanBattle({required String clanBattleId});
}

abstract class LeaderboardService {
  Future<List<LeaderboardEntry>> getGlobalRanks({required int limit, LeaderboardEntry? startAfter});
  Future<List<LeaderboardEntry>> getFriendsRanks({required String userId});
  Future<LeaderboardEntry> getMyRank({required String userId});
}

abstract class FriendService {
  Future<List<UserModel>> searchByUsername({required String query});
  Future<List<UserModel>> searchByUserId({required String userId});
  Future<void> sendRequest({required String fromUserId, required String toUserId});
  Future<void> acceptRequest({required String relationshipId});
  Future<void> rejectRequest({required String relationshipId});
  Future<List<UserModel>> getFriends({required String userId});
  Future<void> removeFriend({required String userId, required String friendId});
}

abstract class NotificationService {
  Future<bool> requestPermission();
  Future<void> subscribeToTopic(String topic);
  void handleForegroundMessage(RemoteMessage message);
  void handleBackgroundMessage(RemoteMessage message);
  Future<void> saveToken({required String userId});
}

abstract class MapService {
  Future<List<UserModel>> getNearbyUsers({required double lat, required double lng, required double radiusKm});
  Stream<Position> startLocationUpdates();
  Future<void> stopLocationUpdates();
  Future<void> updateUserLocation({required String userId, required double lat, required double lng});
}

abstract class XPService {
  Future<void> awardXP({required String userId, required int amount, required String reason});
  int calculateLevel(int totalXP);
  int xpToNextLevel(int totalXP);
  bool isLevelUp(int oldXP, int newXP);
}
```

---

## SECTION 6 — Development Phases

| Phase | What Gets Built | Depends On | Size | Done When |
|---|---|---|---|---|
| 1: Foundation | Project scaffold, theme, GoRouter, 5 tab shells, nav bar, glass_card/progress_bar widgets | Nothing | M | App launches, tabs navigate, dark theme matches tokens, glassmorphism renders |
| 2: Auth + Onboarding | Firebase Auth (Google/Apple/Email), login screen, onboarding, user doc creation | Phase 1 | L | Sign up, complete onboarding, see main shell. Returning users skip. |
| 3: Health + Step Sync | `health` package, permission flow, foreground polling, background sync, step_logs writes, ingestSteps function | Phase 2 | XL | Steps read from device, synced to Firestore every 15 min, today's count displays, background works |
| 4: Home Tab | Overview card, stat pills, active battle card (3 states), missions section, map preview | Phase 3 | L | Live step count, XP delta, level progress, mission bars, empty states |
| 5: Battles | Battles tab (3 sections), battle sheets, real-time sync, concludeBattle function, XP award | Phase 3 | XL | Create 1v1/group, live step updates, conclusion at endTime, winner gets XP, push on result |
| 6: Missions | Missions tab, mission detail sheet, evaluation + reset Cloud Functions, XP on completion | Phase 3 | L | Live progress, complete → earn XP, reset at midnight, weekly reset Sunday |
| 7: Clan | Clan entry/dashboard, create/join sheets, clan battle screens, concludeClanBattle function | Phase 5 | XL | Create/join clan, see members live, create clan battle, live aggregation, conclusion awards XP |
| 8: Leaderboard + Friends | Leaderboard tab, podium, pagination, floating card, recalculateLeaderboard function, Add Friends sheet, friend requests | Phase 2 | L | XP-ranked users, pagination, friends filter, add friends, floating rank card |
| 9: Profile + Settings | Profile screen, set goal sheet, streak history, sign out, checkStreaks function | Phase 3 | M | Correct stats, change goal, streak display, sign out, weekly/all-time aggregation |
| 10: Map | Full-screen Google Map, dark styling, avatar pins, location permission | Phase 3 | L | Map renders, nearby users as pins, gold ring on leader, blue own pin, permission flow |
| 11: Push Notifications | FCM, dispatchNotification function, foreground/background handlers, deep links | Phases 5,6,7 | M | Battle invite → push → tap → open battle. Level up push. Mission reset push. |
| 12: Polish | Animations (XP earn, level-up confetti), shimmer loaders, haptics, all empty states, error banners | All | L | Every list has empty state, loading shows shimmer, errors show retry, animations play |
| 13: Testing + Release | Unit tests, widget tests, integration tests, security rules test, profiling, store metadata | Phase 12 | L | Critical paths tested, security rules work, smooth with 100+ cards, builds compile |

---

## SECTION 7 — Risk Register

| Risk | Severity | Mitigation |
|---|---|---|
| Background step sync reliability on iOS | High | HealthKit background delivery is limited. Use `workmanager` as fallback. Accept 15–30 min lag. During active battles, encourage foreground use. Show "last synced" timestamp. |
| Firestore cost at scale | High | Minimize real-time listeners (only active battles + today's missions). Pre-computed `leaderboard_snapshots`. Cache missions locally. Budget alert at $50/month. |
| Battle step sync latency | Medium | Client writes every 5 min. Show "Last updated" timestamp. Acceptable for step competition (not real-time gaming). |
| Leaderboard at 10K+ users | Medium | Dedicated `leaderboard_snapshots` collection with pre-computed ranks. Paginate 50 at a time. No live sort on full user collection. |
| Clan battle step aggregation | Medium | Denormalized `totalSteps` on `clan_battles` doc. Cloud Function sums member logs every 15 min. Client reads single document. |
| Location permission UX | Medium | Request only on map tap (not app launch). Explain value. App works without location. "While using" permission sufficient. |
| Health permission rejection | Medium | App works without health data. Show "Connect Health" banner. All non-step features accessible. |
| Streak across timezone changes | Low | Store user timezone. Cloud Function evaluates per user's local midnight. Accept minor edge cases. |

---

## SECTION 8 — Third-Party Services & Accounts Needed

### Firebase Project Setup
- [ ] Create Firebase project
- [ ] Enable Auth providers: Google, Apple, Email/Password
- [ ] Create Firestore database (production mode)
- [ ] Deploy security rules + indexes
- [ ] Set up Cloud Functions (Node.js 18+)
- [ ] Enable FCM
- [ ] Set up Firebase Storage (avatars)
- [ ] Add iOS + Android apps, download config files

### Apple Developer Account
- [ ] Active membership ($99/year)
- [ ] HealthKit entitlement in Xcode
- [ ] HealthKit usage descriptions in Info.plist
- [ ] Sign in with Apple service ID
- [ ] APNs push certificate/key for FCM
- [ ] Background Modes: Background fetch, Remote notifications

### Google Cloud Console
- [ ] Enable Maps SDK for iOS + Android
- [ ] Generate restricted API key
- [ ] Enable Health Connect API
- [ ] Set up billing ($200/month free tier for Maps)

### Other
- [ ] Google Fonts: Space Grotesk + Manrope (bundled in app)
- [ ] Material Symbols (Flutter package)
- [ ] Rive/Lottie animation files for XP + level-up (design task)

---

## What We Are Building In One Page

**StepBattle** is a cross-platform mobile fitness game built with **Flutter** and **Firebase**. It reads steps from Apple HealthKit and Google Health Connect, converts them to XP, and wraps everything in competitive social gameplay.

**5 main tabs** — Home (dashboard), Battles (1v1 + group step competitions), Missions (daily + weekly challenges), Clan (team formation + clan battles), Leaderboard (global + friends XP rankings). Plus a Profile page, 9 bottom sheets, a Snapchat-style map, and push notifications.

**Tech:** Flutter + Dart, Riverpod state management, GoRouter navigation, Firestore real-time data, Cloud Functions for server logic, FCM for push, Google Maps, Hive for offline caching.

**13 development phases** from foundation → auth → health → home → battles → missions → clan → leaderboard → profile → map → notifications → polish → testing.

**Design system:** Dark nocturnal palette (#0e0e10), glassmorphism cards with blue inner glow, Space Grotesk headlines, Manrope body text, no divider lines, gradient progress bars with spark effects, aggressive typographic scale.

---

Plan complete. Ready to begin Phase 1.
