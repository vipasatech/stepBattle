# Architecture

This is a **feature-scaled** description of how a request flows through
the app — enough to onboard someone in an afternoon, not enough to
substitute for reading the code. File paths hyperlink; follow them.

## The 5-layer stack

```
┌─────────────────────────────────────────────────────────────────────┐
│  UI                                                                 │
│  screens/*, sheets/*, widgets/*                                     │
│  Consumes Riverpod providers; nothing touches SupabaseClient here.  │
└───────────────────────────────┬─────────────────────────────────────┘
                                │  ref.watch(fooProvider)
┌───────────────────────────────▼─────────────────────────────────────┐
│  Providers                                                          │
│  providers/*                                                        │
│  Wire repositories + services to widgets. Own StreamProvider /      │
│  FutureProvider / Provider bindings + .autoDispose / .family.       │
└───────────────────────────────┬─────────────────────────────────────┘
                                │  reads
┌───────────────────────────────▼─────────────────────────────────────┐
│  Repositories                                                       │
│  repositories/*                                                     │
│  Cache-then-network. Emit Hive-cached rows on frame 1, then         │
│  live-update from a retry-wrapped Supabase realtime subscription.   │
└───────────────────────────────┬─────────────────────────────────────┘
                                │  routes through
┌───────────────────────────────▼─────────────────────────────────────┐
│  SupabaseApiClient (services/supabase_api_client.dart)              │
│  Retry-on-transient + PII-safe timing/error logging. Every read /   │
│  write on Supabase should flow through this — including from the    │
│  domain services below.                                             │
└───────────────────────────────┬─────────────────────────────────────┘
                                │  eq/select/insert/rpc/upsert
┌───────────────────────────────▼─────────────────────────────────────┐
│  Domain services                                                    │
│  services/battle_service.dart, mission_service.dart,                │
│  supabase_auth_service.dart, ...                                    │
│  Mutation surface: create/update/delete + business rules that       │
│  produce writes. Reads on hot paths have been lifted to             │
│  repositories.                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

**Rule of thumb when adding a feature**:
- New table or new data source → new repository. See
  [profile_repository.dart](lib/repositories/profile_repository.dart)
  for the canonical shape.
- Mutation-only (create battle, join clan) → stays on the domain
  service; wrap the actual Supabase call in `SupabaseApiClient.run(...)`
  with `retry: false` for anything that must not run twice.

## Data flow — read

1. Widget calls `ref.watch(currentUserProvider)`.
2. `currentUserProvider` is a `StreamProvider` delegating to
   `ProfileRepository.watch(userId)`.
3. `ProfileRepository.watch`:
   - Synchronously emits the Hive-cached row (frame 1).
   - Subscribes to `_supabase.from('profiles').stream(...).eq('id', uid)`.
   - The subscription is wrapped in
     [`retryingRealtimeStream`](lib/utils/realtime_retry.dart), which
     handles reconnection with exponential backoff and drops Sentry
     breadcrumbs on every state transition.
   - Every fresh row rewrites the Hive cache and emits downstream.
4. UI paints the cache instantly, then updates when the live row arrives.

## Data flow — write

1. Widget calls a method on a domain service via a provider:
   `ref.read(battleServiceProvider).createBattle(...)`.
2. Service constructs the row + calls
   `SupabaseApiClient.instance.run(() => _supabase.from(...).insert(...))`
   with `retry: false` (creates must not run twice).
3. `SupabaseApiClient.run` times the call, retries transient failures
   (unless `retry: false`), and logs via `AppLogger` — which
   auto-forwards errors to Sentry.
4. The realtime stream driving `allBattlesProvider` picks up the new row
   and every consumer rebuilds.

## Observability

Three sinks; one entry point (`AppLogger`).

- **AppLogger** ([`utils/app_logger.dart`](lib/utils/app_logger.dart)) —
  every log line is PII-redacted (email / phone / JWT scrubbed) before
  landing in a ring buffer + stdout + upstream hooks.
- **Sentry** — installed by
  [`ObservabilityService`](lib/services/observability_service.dart),
  which registers a hook on `AppLogger`. Every `.e(...)` call fans out.
  Placeholder-safe: `SENTRY_DSN=changeme` → no-op.
- **PostHog** — same module, product events fired by call sites (see
  `trackEvent('battle_completed', ...)`). Placeholder-safe.
- **Breadcrumbs** — `ObservabilityService.breadcrumb(...)` is called on
  every realtime state transition and every background-sync tick, so a
  crashed session ships with the preceding 30-90 s of activity attached.

## Caching + invalidation

Three repositories cache via
[`HiveJsonCache`](lib/repositories/hive_json_cache.dart) using
per-repo `prefix` namespaces. On sign-out
([`supabase_auth_service.dart:signOut`](lib/services/supabase_auth_service.dart)):

```dart
await Future.wait([
  ProfileRepository.clearAllCached(),
  MissionRepository.clearAllCached(),
  BattleRepository.clearAllCached(),
]);
```

Adding a new repository? Wire its `clearAllCached()` into that
`Future.wait`.

## Background sync

[`services/background_sync.dart`](lib/services/background_sync.dart)
owns three pieces:

- **Foreground service** (`_StepSyncTaskHandler`) — always-on while
  signed in; ticks every 30 s to refresh the persistent notification
  and sync steps.
- **WorkManager periodic task** — the only path that runs while the app
  is terminated (Android only). Called `stepbattle-step-sync`, fires
  ≥15 min, calls `headlessStepSync`.
- **Home widget push** — writes step / kcal / distance into
  `HomeWidget.saveWidgetData` so the Android widget can render fresh
  values.

Each layer emits Sentry breadcrumbs (`bg.stepSync` category) so a
crashed background task ships with the preceding tick history attached.

## Realtime hardening

Any Supabase realtime subscription that's user-facing goes through
[`retryingRealtimeStream`](lib/utils/realtime_retry.dart):

- Reconnects with exponential backoff (2 s → 30 s cap).
- Emits `onReconnectingChanged(true/false)` so the UI can show a small
  "Reconnecting…" pill without coupling data-vs-connection state into
  the same stream.
- Drops Sentry breadcrumbs on `connected` / `retry` / `closed` — the
  timeline is invaluable when someone reports "steps stopped syncing
  during my run".

## Media

- **User photos** (run session): OS-level downscale at pick time
  (1920 px max edge, JPEG q85), 3 MB per-photo hard cap before upload,
  retry-wrapped Supabase Storage upload — see
  [`run_tracking_service.dart:uploadTrackMedia`](lib/services/run_tracking_service.dart).
- **Remote images** (avatars, thumbnails): funnel through
  [`AppNetworkImage`](lib/widgets/app_network_image.dart) — one widget
  wrapping `CachedNetworkImage` so switching the disk-cache policy is
  a one-file change.
- **3D arena** (~10 MB GLB per time-of-day): preloaded during the
  splash floor via
  [`MediaWarmup.preloadArenaForNow()`](lib/services/media_warmup.dart)
  so the first battle-open paints instantly.
- **3D avatars** (~7 MB per character × 4 characters): bundled in
  `assets/images/3dAvatars/{adam,amy,shannon,jackie}/`. Draco-compressed.

## Test taxonomy

- `test/unit/` — pure logic + fake-in-memory tests. Repos, models,
  clients. Fast.
- `test/widget/` — widget-level rendering tests using
  `pumpWidget` + `MaterialApp` scaffolding.
- `test/benchmark/` — micro-benchmarks. Not assertions; they run so CI
  logs surface timing regressions as a diff for the reviewer.
- Integration / smoke tests — deliberately deferred. Value is high but
  cost of maintaining screenshot suites for a UI that's still moving is
  higher.

## Adding a feature — checklist

1. If it's a new table, write the migration into
   `supabase/migrations/NNNN_*.sql` and log it in
   [`supabase/PENDING_MIGRATIONS.md`](supabase/PENDING_MIGRATIONS.md).
2. If it's read on the UI critical path, write a repository. Steal the
   shape from
   [profile_repository.dart](lib/repositories/profile_repository.dart).
3. Bind reads to a provider (`StreamProvider`/`FutureProvider`) —
   `.autoDispose` if the data belongs to one screen, family if it's
   per-id.
4. Writes go through the domain service (`services/foo_service.dart`),
   wrapped in `SupabaseApiClient.instance.run(...)`. Use `retry: false`
   for anything that mutates a real-world state you can't undo (XP
   grants, payments, once-per-user creates).
5. If the new stream is user-facing realtime, run it through
   [`retryingRealtimeStream`](lib/utils/realtime_retry.dart) with the
   right `category`.
6. Wire `clearAllCached()` into the sign-out invalidation batch.
7. Write at least one unit test — see
   [test/unit/supabase_api_client_test.dart](test/unit/supabase_api_client_test.dart)
   for the invariant-pinning style.
