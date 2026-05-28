# Wraps `flutter run` so every line printed by AppLogger gets routed to a
# per-category file under ./logs/<session-timestamp>/.
#
# Usage:
#   pwsh tools/run_with_logs.ps1
#   pwsh tools/run_with_logs.ps1 -d <deviceId>
#   pwsh tools/run_with_logs.ps1 --release
#
# Anything after the script name is passed through to `flutter run` verbatim.
# Use `flutter devices` to list device IDs.
#
# Output layout (per `flutter run` invocation):
#   logs/2026-05-16_12-30-45/
#     _session.log     <- session header + crashes + anything not tagged
#     step.log
#     mission.log
#     xp.log
#     battle.log
#     ... (one file per LogCategory)
#
# The script also echoes everything to its own stdout so the normal
# `flutter run` UX (hot reload via `r`, restart via `R`, etc.) is preserved.
#
# Why we open files via .NET FileStream(FileShare.ReadWrite) instead of
# Add-Content: PowerShell's Add-Content opens files with FileShare.Read,
# which collides with editors (VSCode, Notepad, etc.) that hold the file
# open while you tail it. The shared-RW handle lets editors keep reading
# while we keep appending.

param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$FlutterArgs = @()
)

$ErrorActionPreference = 'Stop'

# Resolve repo root (parent of `tools/`) so the script works no matter
# where it is invoked from.
$repoRoot = Split-Path -Parent $PSScriptRoot
$logRoot  = Join-Path $repoRoot 'logs'

$sessionTs  = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$sessionDir = Join-Path $logRoot $sessionTs
New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null

# Match `[LOG][<category>][<iso>][<level>] ...` anywhere in the line.
# `flutter run` prefixes every Dart stdout line with `I/flutter (PID):`,
# so we cannot anchor to ^. Looking for `[LOG][cat]` anywhere is enough —
# `[LOG]` is unique to our tagged emissions.
$logRegex = '\[LOG\]\[([^\]]+)\]\[[^\]]+\]\[[^\]]+\]'

# Cached writers keyed by full file path. Each writer is a StreamWriter
# wrapping a FileStream opened with FileShare.ReadWrite so the IDE can
# keep the file open without locking out our appends.
$writers = @{}

function Get-LogWriter([string]$path) {
  if ($script:writers.ContainsKey($path)) {
    return $script:writers[$path]
  }
  # FileMode.Append auto-creates the file if missing.
  $fs = [System.IO.FileStream]::new(
    $path,
    [System.IO.FileMode]::Append,
    [System.IO.FileAccess]::Write,
    [System.IO.FileShare]::ReadWrite
  )
  # UTF-8 without BOM — easier for tools that grep the file.
  $sw = [System.IO.StreamWriter]::new($fs, [System.Text.UTF8Encoding]::new($false))
  $sw.AutoFlush = $true
  $script:writers[$path] = $sw
  return $sw
}

$sessionFile = Join-Path $sessionDir '_session.log'
$sessionWriter = Get-LogWriter $sessionFile

# Session header — writes through the shared-RW writer so it survives
# the IDE re-opening _session.log.
$sessionWriter.WriteLine("session_start: $sessionTs")
$sessionWriter.WriteLine("repo_root: $repoRoot")
$sessionWriter.WriteLine("flutter_args: $($FlutterArgs -join ' ')")
$sessionWriter.WriteLine(('-' * 60))

Write-Host ""
Write-Host "Logging session to: $sessionDir" -ForegroundColor Cyan
Write-Host ""

try {
  # PowerShell 5.1 quirk: with `$ErrorActionPreference = 'Stop'` (set at the
  # top of this script for the file-setup phase) any native-command stderr
  # line gets promoted to a terminating error when piped through `2>&1`.
  # The Android SDK occasionally prints a "SDK XML version 4" warning to
  # stderr that's not actually fatal — let those pass through.
  $previousPref = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'

  # `& flutter run` pipes stdout+stderr through. The ForEach-Object
  # tees to host stdout (so hot reload UX still works) and routes
  # matching lines into the per-category file.
  & flutter run @FlutterArgs 2>&1 | ForEach-Object {
    $line = $_.ToString()
    Write-Host $line
    if ($line -match $logRegex) {
      $cat = $matches[1]
      $file = Join-Path $sessionDir "$cat.log"
      try {
        (Get-LogWriter $file).WriteLine($line)
      } catch {
        # Last-ditch fallback: if even the FileShare-RW writer can't be
        # created (rare — e.g. disk full or permission), surface the
        # failure once but keep the run alive.
        Write-Warning "Could not write to $file : $_"
      }
    } else {
      try {
        $sessionWriter.WriteLine($line)
      } catch {
        Write-Warning "Could not write to $sessionFile : $_"
      }
    }
  }
} finally {
  # Restore the script-level error preference and flush + close every
  # writer so the last few lines aren't truncated if PowerShell exits
  # abruptly (Ctrl+C, etc.).
  if ($null -ne $previousPref) { $ErrorActionPreference = $previousPref }
  foreach ($w in $writers.Values) {
    try { $w.Flush() } catch {}
    try { $w.Dispose() } catch {}
  }
}
