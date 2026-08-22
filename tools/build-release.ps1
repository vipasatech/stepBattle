#requires -Version 5.1
<#
.SYNOPSIS
Build a size- and perf-optimized release artifact for Android + iOS.

.DESCRIPTION
Wraps `flutter build appbundle` / `flutter build ipa` with the flags we
need to keep in every release build so an ad-hoc build on someone's
machine can't drift from CI. Flags applied:

  --tree-shake-icons     Drop unused Material/Cupertino icon glyphs from
                         the bundled `MaterialIcons.ttf`. Saves 100-300
                         KB per build.

  --split-debug-info     Extract Dart symbol tables into per-arch files
                         so Sentry can symbolicate release stack traces
                         while the shipped .aab stays small. Output goes
                         to `build/symbols/<sha>/`.

  --obfuscate            Rename Dart identifiers so decompiled bytecode
                         is unreadable. Requires --split-debug-info to
                         be usable in Sentry.

.PARAMETER Target
`android` (default) or `ios`.

.PARAMETER Flavor
Optional Flutter flavor. Passed as `--flavor <name>` when set.

.PARAMETER SkipObfuscate
Toggle obfuscation off — useful when reproducing a customer crash
locally where you want readable Dart identifiers in `dart devtools`.

.EXAMPLE
./tools/build-release.ps1
# Builds android app bundle with all optimizations.

.EXAMPLE
./tools/build-release.ps1 -Target ios
# Builds an iOS IPA with the same flags.
#>
param(
    [ValidateSet('android', 'ios')]
    [string]$Target = 'android',
    [string]$Flavor = '',
    [switch]$SkipObfuscate
)

$ErrorActionPreference = 'Stop'

$commitSha = ((git rev-parse --short HEAD 2>$null) -join '') -replace '\s', ''
if ([string]::IsNullOrWhiteSpace($commitSha)) { $commitSha = 'nogit' }
$symbolsDir = Join-Path (Get-Location) "build/symbols/$commitSha"
New-Item -ItemType Directory -Force -Path $symbolsDir | Out-Null

$flags = @(
    '--release',
    '--tree-shake-icons',
    "--split-debug-info=$symbolsDir",
    "--dart-define=SENTRY_RELEASE=$commitSha"
)
if (-not $SkipObfuscate) { $flags += '--obfuscate' }
if (-not [string]::IsNullOrWhiteSpace($Flavor)) { $flags += '--flavor', $Flavor }

switch ($Target) {
    'android' { $cmd = 'flutter build appbundle ' + ($flags -join ' ') }
    'ios'     { $cmd = 'flutter build ipa '       + ($flags -join ' ') }
}

Write-Host "Building $Target with:"
Write-Host "  $cmd"
Write-Host "  Symbols → $symbolsDir"
Write-Host ""

Invoke-Expression $cmd
if ($LASTEXITCODE -ne 0) {
    Write-Error "Build failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "Build complete."
Write-Host ""
Write-Host "AAB path: build/app/outputs/bundle/release/app-release.aab"
Write-Host "Symbols:  $symbolsDir"
