#!/usr/bin/env bash
# Zero-runtime-network-egress scan (invariant 1). Two stages:
#
#   1) First-party source: ZERO outbound-network API references, no exceptions.
#   2) Linked Release binary (PR 12): every network symbol and URL string in
#      the binary must appear in scripts/egress-allowlist.txt. The allowlist
#      exists because FluidAudio links statically and its (never-invoked)
#      model-download code imports network APIs; those paths are hard-disabled
#      at launch (DownloadUtils.enforceOffline = true, set before any model
#      API and CHECKED as a precondition in FluidAudioASR.prepare). Every
#      allowlist entry is annotated with its provenance. Anything NEW fails
#      the scan — first-party network code can never ride in silently.
#
# Usage: scripts/check-egress.sh [path-to-binary]
#   With no argument, builds Release to build/egress-dd and scans that.
set -euo pipefail

cd "$(dirname "$0")/.."

# ---- Stage 1: first-party source ------------------------------------------

SCAN_DIRS=(Vizpr)

# Outbound-network API surface that must never appear in first-party code.
PATTERNS='URLSession|URLRequest|NSURLConnection|Network\.|NWConnection|NWBrowser|CFStream|CFSocket|getaddrinfo|socket\(|connect\(|sendto\(|URLDownload'

echo "[1/2] Scanning first-party source for outbound-network APIs ..."
# Whole-line comments are excluded (docs may NAME these APIs to explain why
# they are not used); any match in actual code fails.
SOURCE_HITS="$(grep -rEn --include='*.swift' "$PATTERNS" "${SCAN_DIRS[@]}" 2>/dev/null \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*///?' || true)"
if [[ -n "$SOURCE_HITS" ]]; then
  echo "$SOURCE_HITS"
  echo "FAIL: outbound-network API reference found in first-party source." >&2
  exit 1
fi
echo "PASS: no outbound-network API references in first-party source."

# ---- Stage 2: linked Release binary ----------------------------------------

BINARY="${1:-}"
if [[ -z "$BINARY" ]]; then
  echo "[2/2] Building Release for the binary scan ..."
  xcodebuild -project Vizpr.xcodeproj -scheme Vizpr -configuration Release \
    -derivedDataPath build/egress-dd build -quiet
  BINARY="build/egress-dd/Build/Products/Release/Vizpr.app/Contents/MacOS/Vizpr"
fi
if [[ ! -f "$BINARY" ]]; then
  echo "FAIL: binary not found at $BINARY" >&2
  exit 1
fi
echo "[2/2] Scanning linked binary: $BINARY"

ALLOWLIST="scripts/egress-allowlist.txt"
FINDINGS="$(mktemp)"
trap 'rm -f "$FINDINGS"' EXIT

# Imported network symbols (undefined = resolved from system frameworks at
# load). Anchored so e.g. _connectionField doesn't match.
nm -u "$BINARY" 2>/dev/null | grep -E \
  '_OBJC_CLASS_\$_NSURLSession|NSURLSession|Network12NWConnection|_nw_connection|CFSocket|CFStreamCreatePairWithSocket|^_getaddrinfo$|^_socket$|^_connect$|^_sendto$|^_recvfrom$' \
  | sed 's/^/sym /' | sort -u >> "$FINDINGS" || true

# Embedded URL strings (download endpoints live here if anywhere).
strings -a "$BINARY" | grep -E '^https?://' | sed 's/^/url /' | sort -u >> "$FINDINGS" || true

if [[ ! -f "$ALLOWLIST" ]]; then
  echo "FAIL: $ALLOWLIST missing. Current findings:" >&2
  cat "$FINDINGS" >&2
  exit 1
fi

# Every finding must be allowlisted (comments/blank lines in the allowlist
# are ignored). New findings fail loudly.
NEW="$(grep -vxF -f <(grep -v '^#' "$ALLOWLIST" | grep -v '^$') "$FINDINGS" || true)"
if [[ -n "$NEW" ]]; then
  echo "FAIL: network symbols/URLs in the binary that are NOT allowlisted:" >&2
  echo "$NEW" >&2
  echo "Trace each to its source; only never-invoked, runtime-disarmed" >&2
  echo "third-party code may be added to $ALLOWLIST (with provenance)." >&2
  exit 1
fi

COUNT="$(grep -c . "$FINDINGS" || true)"
echo "PASS: $COUNT binary finding(s), all allowlisted with provenance."
echo "PASS: zero unaccounted network egress paths."
