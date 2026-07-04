#!/usr/bin/env bash
# Prove the dev transcript logger is physically absent from a Release build
# (invariant 7 / §14). Pass the path to a built Release Vizpr.app (or its MacOS
# binary), or let it build one. The DICT_DEV_LOG-gated code embeds
# VIZPR_DEV_LOG_BUILD_MARKER; no Mach-O in the Release bundle may contain that
# marker or the logger's symbols.
#
# Note: every Mach-O in Contents/MacOS is scanned, not just the launcher. Debug
# builds split app code into a sibling Vizpr.debug.dylib (a build accelerator),
# so scanning only the main executable would miss the real code. Release builds
# are monolithic, but scanning the whole directory keeps the check honest
# regardless of how the bundle is laid out.
set -euo pipefail

cd "$(dirname "$0")/.."

TARGET="${1:-}"
if [[ -z "$TARGET" ]]; then
  echo "Building Release binary ..."
  DERIVED=$(mktemp -d)
  xcodebuild -project Vizpr.xcodeproj -scheme Vizpr -configuration Release \
    -derivedDataPath "$DERIVED" build >/dev/null
  TARGET="$DERIVED/Build/Products/Release/Vizpr.app"
fi

# Resolve the directory of Mach-O files to scan.
if [[ -d "$TARGET" && -d "$TARGET/Contents/MacOS" ]]; then
  SCAN_DIR="$TARGET/Contents/MacOS"
elif [[ -f "$TARGET" ]]; then
  SCAN_DIR="$(dirname "$TARGET")"
else
  echo "error: not a Vizpr.app or binary: $TARGET" >&2
  exit 1
fi

FAIL=0
SCANNED=0
while IFS= read -r bin; do
  # Only inspect Mach-O files.
  file "$bin" | grep -q "Mach-O" || continue
  SCANNED=$((SCANNED + 1))
  echo "Inspecting: $bin"
  if grep -a -q "VIZPR_DEV_LOG_BUILD_MARKER" "$bin"; then
    echo "  FAIL: dev-log build marker present." >&2
    FAIL=1
  fi
  if nm "$bin" 2>/dev/null | grep -qiE "VizprTranscriptLogger|VizprDevLogWriter|DevDictationTracker|DevDictationRecord|DevCleanupRecord"; then
    echo "  FAIL: dev logger symbols present." >&2
    FAIL=1
  fi
done < <(find "$SCAN_DIR" -type f)

if [[ "$SCANNED" -eq 0 ]]; then
  echo "error: no Mach-O binaries found under $SCAN_DIR" >&2
  exit 1
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "PASS: dev logger is absent from all $SCANNED Release binaries."
fi
exit "$FAIL"
