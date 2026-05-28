# tools/

## `run_with_logs.ps1`

Wraps `flutter run` so every line emitted by `AppLogger` lands in a
per-category log file under `./logs/<session-timestamp>/`. Each session
gets its own folder, so prior sessions are preserved for comparison.

### Quick start

```powershell
# from repo root
pwsh tools/run_with_logs.ps1
```

Any extra args are passed through to `flutter run`:

```powershell
pwsh tools/run_with_logs.ps1 -d 4f7b9a2c        # specific device
pwsh tools/run_with_logs.ps1 --release          # release build (logs off
                                                #   unless --dart-define=ENABLE_LOGS=true)
pwsh tools/run_with_logs.ps1 --dart-define=ENABLE_LOGS=true --release
```

Hot reload (`r`) and hot restart (`R`) still work as normal — the script
just pipes stdout, it does not detach the process.

### What you get

```
logs/
└── 2026-05-16_12-30-45/
    ├── _session.log     # session header + crashes + anything not tagged
    ├── step.log         # AppLogger.step.*
    ├── mission.log      # AppLogger.mission.*
    ├── xp.log           # AppLogger.xp.*
    ├── battle.log       # ...
    └── (one file per LogCategory)
```

Files are written line-by-line as the app runs, so you can `tail` /
`Get-Content -Wait` any of them in a side pane while you reproduce a bug.

### Line format

Every routed line has the shape:

```
[LOG][<category>][<isoUtcTimestamp>][<level>] <event> {"k":"v",...}
```

Example:

```
[LOG][step][2026-05-16T12:30:48.214Z][info] syncSteps {"userId":"abc","steps":647,"source":"google_fit"}
```

The category between the first two brackets is what the script greps on
to choose the output file.

### Disabling

The Dart-side logger short-circuits to a no-op when neither
`kDebugMode` nor `--dart-define=ENABLE_LOGS=true` is set, so release
builds incur zero runtime cost even with this script wrapped around them.
