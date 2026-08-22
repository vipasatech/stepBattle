# StepBattle

Flutter mobile app: step-counting battles, missions, XP, streaks, and
clan competitions, backed by Supabase (auth + Postgres + Realtime +
Storage). Health data comes from the OS native pedometer (iOS
CMPedometer, Android Health Connect + Google Fit fallback).

## Getting started

Requirements:

- **Flutter 3.27.x** (channel `stable`, Dart 3.6.0). Local CI pins this
  exact version — see [.github/workflows/ci.yml](.github/workflows/ci.yml).
- **JDK 17** for the Android build.
- A running Supabase project. Anon key + URL go into `.env`.

```bash
git clone <repo>
cd stepbattle
cp .env.example .env       # fill in SUPABASE_URL / SUPABASE_ANON_KEY
flutter pub get
flutter run
```

Sentry / PostHog are optional. Leave the `changeme` placeholders in
`.env` and the observability layer silently no-ops.

## Repo layout

```
lib/
├── config/            # theme, colors, constants, router
├── models/            # DTOs — one file per Supabase table
├── repositories/      # Cache-then-network layer over SupabaseClient
├── services/          # Domain services (auth, battle, mission, ...)
├── providers/         # Riverpod providers — bind services + repos to UI
├── screens/           # One folder per top-level route
├── sheets/            # Modal bottom sheets
├── widgets/           # Shared UI primitives
└── utils/             # AppLogger, retry helpers, etc.

test/
├── unit/              # Model, service, repo, client tests
├── widget/            # Widget-level rendering tests
└── benchmark/         # Micro-benchmarks — run for regressions

supabase/
├── migrations/        # SQL migrations, numbered 0001..NNNN
└── PENDING_MIGRATIONS.md  # SQL staged but not yet applied

tools/
├── build-release.ps1  # size-optimized android/ios release with symbols
├── build-release.sh   # same, unix
└── run_with_logs.ps1  # flutter run with per-category log tailing
```

## Common commands

```bash
flutter analyze                              # static analysis
flutter test                                 # all tests
flutter test test/benchmark                  # just benchmarks
flutter test --reporter expanded             # verbose (bench output visible)
pwsh tools/build-release.ps1                 # release .aab with symbols
pwsh tools/build-release.ps1 -Target ios     # release .ipa
```

## Architecture

For the layered architecture, data flow, observability + caching model,
and rules of the road for adding a new feature, read
[ARCHITECTURE.md](ARCHITECTURE.md).

## Pending Supabase changes

Any SQL migration I stage but haven't applied lands in
[supabase/PENDING_MIGRATIONS.md](supabase/PENDING_MIGRATIONS.md). The
code keeps working without them; they exist to unlock scale
(indexes, extensions) or downstream features.

## CI

`.github/workflows/ci.yml` runs `flutter analyze` and `flutter test`
on every push to `main` and every PR. No release-build step in CI
yet — see the workflow file for the reason.
