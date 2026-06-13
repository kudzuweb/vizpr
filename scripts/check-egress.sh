#!/usr/bin/env bash
# Zero-runtime-network-egress scan (invariant 1).
#
# PLACEHOLDER — filled out in PR 12 against the linked Release binary. The final
# version scans the built binary's symbols and strings for outbound-network APIs
# (URLSession, BSD sockets, Network.framework, CFStream, etc.) and targets zero
# findings. For now this scans the source tree as an early tripwire so a stray
# networking call is caught the moment it lands, not at packaging time.
set -euo pipefail

cd "$(dirname "$0")/.."

# First-party source only — third-party deps (FluidAudio) are audited separately;
# FluidAudio's network paths are disarmed at runtime via its offline mode (PR 4).
SCAN_DIRS=(Vizpr)

# Outbound-network API surface that must never appear in first-party code.
PATTERNS='URLSession|URLRequest|NSURLConnection|Network\.|NWConnection|NWBrowser|CFStream|CFSocket|getaddrinfo|socket\(|connect\(|sendto\(|URLDownload'

echo "Scanning first-party source for outbound-network APIs ..."
if grep -rEn --include='*.swift' "$PATTERNS" "${SCAN_DIRS[@]}" 2>/dev/null; then
  echo "FAIL: outbound-network API reference found in first-party source." >&2
  exit 1
fi

echo "PASS: no outbound-network API references in first-party source."
echo "NOTE: binary-level scan of the Release build is implemented in PR 12."
