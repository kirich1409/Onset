#!/usr/bin/env bash
# check-no-network.sh <path-to-Onset.app>
#
# Static proxy for the "no network client" invariant (spec AC: Onset must not
# initiate network connections).
#
# Checks the BUILT binary for linkage of network frameworks and presence of
# network-related symbols. This is a static check — runtime verification
# (nettop) happens in the L5 self-hosted acceptance job.
#
# SCOPE NOTE: We check only the Onset main binary, not system frameworks.
# Apple's own frameworks (SwiftUI, SwiftData, Foundation) may transitively
# reference network symbols — that is Apple's code, not ours.
# The check targets: dynamic library linkage (-L check) and presence of
# Onset-originated URLSession/network call symbols in the binary's own
# symbol table (nm output, scoped to the app binary, not its dependencies).
#
# Usage: scripts/check-no-network.sh /path/to/Onset.app
#
# Exit codes: 0 = pass (no network linkage found), 1 = violation found

set -euo pipefail

APP_PATH="${1:?Usage: $0 <path-to-Onset.app>}"
BINARY="$APP_PATH/Contents/MacOS/Onset"

if [ ! -f "$BINARY" ]; then
  echo "ERROR: Binary not found at $BINARY"
  exit 1
fi

echo "Checking no-network invariant on: $BINARY"
echo ""

VIOLATIONS=0

# ── 1. Dynamic library linkage ───────────────────────────────────────────────
# Check that Onset does NOT directly link Network.framework or CFNetwork.
# Note: Foundation.framework is expected and may reference CFNetwork internally —
# that is Apple's indirection, not our code initiating a connection.
# We flag direct linkage of network-specific frameworks only.

echo "=== Linked libraries ==="
LINKED_LIBS=$(otool -L "$BINARY" 2>/dev/null | tail -n +2 | awk '{print $1}')
echo "$LINKED_LIBS"
echo ""

FORBIDDEN_FRAMEWORKS=(
  "/System/Library/Frameworks/Network.framework"
  # CFNetwork is wrapped by Foundation; direct linkage would be unusual and suspect.
  "/System/Library/Frameworks/CFNetwork.framework"
)

for FRAMEWORK in "${FORBIDDEN_FRAMEWORKS[@]}"; do
  if echo "$LINKED_LIBS" | grep -qF "$FRAMEWORK"; then
    echo "NETWORK LINK VIOLATION: $BINARY directly links $FRAMEWORK"
    VIOLATIONS=$((VIOLATIONS + 1))
  fi
done

# ── 2. URLSession symbol presence in app binary ──────────────────────────────
# Check that the Onset binary does not contain URLSession call sites.
# nm lists symbols defined in or referenced by the binary.
# We look for URLSession in the undefined symbol table (U = external reference
# from the app itself calling into a framework) — this indicates the app code
# calls URLSession APIs directly.
#
# False positive risk: SwiftUI/SwiftData bridging may reference network types
# in their generated stubs. If this fires on a known-clean binary, narrow the
# pattern or move to warn-only.

echo "=== URLSession symbol check (undefined symbols in app binary) ==="
NETWORK_SYMBOLS=$(nm "$BINARY" 2>/dev/null | grep -E "^[[:space:]]+U .*URLSession|^[[:space:]]+U .*NWConnection|^[[:space:]]+U .*CFHTTPMessage|^[[:space:]]+U .*NSURLConnection" || true)

if [ -n "$NETWORK_SYMBOLS" ]; then
  echo "NETWORK SYMBOL VIOLATION: Network call symbols found in $BINARY:"
  echo "$NETWORK_SYMBOLS"
  echo ""
  echo "NOTE: If these come from SwiftUI/SwiftData bridging (not app code), add"
  echo "      a targeted exception here with a comment explaining the source."
  VIOLATIONS=$((VIOLATIONS + 1))
else
  echo "No URLSession/NWConnection symbols in undefined table — OK"
fi

echo ""

# ── Result ───────────────────────────────────────────────────────────────────
if [ "$VIOLATIONS" -gt 0 ]; then
  echo "FAIL: $VIOLATIONS no-network violation(s) found"
  echo ""
  echo "If this is a false positive from Apple framework bridging code:"
  echo "  1. Run: nm $BINARY | grep -E 'URLSession|NWConnection'"
  echo "  2. Identify the call site (debug build retains symbol names)"
  echo "  3. If confirmed Apple-internal, narrow the grep pattern in this script"
  exit 1
else
  echo "PASS: no-network check passed (no direct network framework linkage or URLSession symbols)"
fi
