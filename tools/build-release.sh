#!/usr/bin/env bash
# Build a size- and perf-optimized release artifact.
#
# Wraps `flutter build appbundle` / `flutter build ipa` with the flags we
# need to keep in every release build so an ad-hoc build on someone's
# machine can't drift from CI.
#
# Usage:
#   tools/build-release.sh                          # android app bundle
#   tools/build-release.sh --target=ios             # ios ipa
#   tools/build-release.sh --flavor=prod            # with flutter flavor
#   tools/build-release.sh --skip-obfuscate         # readable dart symbols
#
# Flags applied:
#   --tree-shake-icons    Drop unused Material/Cupertino icon glyphs
#   --split-debug-info    Extract Dart symbol tables → build/symbols/<sha>/
#   --obfuscate           Rename Dart identifiers (unless --skip-obfuscate)

set -euo pipefail

TARGET="android"
FLAVOR=""
OBFUSCATE=1

for arg in "$@"; do
    case "$arg" in
        --target=*)      TARGET="${arg#*=}" ;;
        --flavor=*)      FLAVOR="${arg#*=}" ;;
        --skip-obfuscate) OBFUSCATE=0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

if ! [[ "$TARGET" =~ ^(android|ios)$ ]]; then
    echo "Target must be 'android' or 'ios', got: $TARGET" >&2
    exit 2
fi

commit_sha="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
symbols_dir="$(pwd)/build/symbols/${commit_sha}"
mkdir -p "$symbols_dir"

flags=(
    --release
    --tree-shake-icons
    "--split-debug-info=${symbols_dir}"
    "--dart-define=SENTRY_RELEASE=${commit_sha}"
)
[[ $OBFUSCATE -eq 1 ]] && flags+=(--obfuscate)
[[ -n "$FLAVOR"    ]] && flags+=(--flavor "$FLAVOR")

case "$TARGET" in
    android) cmd=(flutter build appbundle "${flags[@]}") ;;
    ios)     cmd=(flutter build ipa       "${flags[@]}") ;;
esac

echo "Building $TARGET with:"
echo "  ${cmd[*]}"
echo "  Symbols → $symbols_dir"
echo ""

"${cmd[@]}"

echo ""
echo "✓ Build complete."
echo ""
echo "Next steps:"
echo "  1. Upload symbols to Sentry (once configured):"
echo "     sentry-cli debug-files upload --org <org> --project <project> $symbols_dir"
echo "  2. Ship the artifact from build/app/outputs/bundle/release/ (android)"
echo "     or build/ios/ipa/ (ios)."
