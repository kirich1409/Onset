#!/usr/bin/env bash
# check-entitlements.sh <path-to-Onset.app>
#
# Verifies entitlements on the BUILT .app binary (not the source .entitlements
# file). xcodebuild injects entitlements during signing; checking only the
# source file produces false pass/fail results.
#
# Usage: scripts/check-entitlements.sh /path/to/Onset.app
#
# Exit codes: 0 = pass, 1 = violation found

set -euo pipefail

APP_PATH="${1:?Usage: $0 <path-to-Onset.app>}"
BINARY="$APP_PATH/Contents/MacOS/Onset"

if [ ! -f "$BINARY" ]; then
  echo "ERROR: Binary not found at $BINARY"
  exit 1
fi

echo "Checking entitlements on: $APP_PATH"
echo ""

# Extract entitlements from the signed binary.
# codesign -d --entitlements - outputs an XML plist to stdout.
# --xml ensures machine-readable output even when the binary is ad-hoc signed.
ENTITLEMENTS=$(codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null) || {
  # Ad-hoc Debug builds may not have entitlements embedded.
  # Treat as empty entitlements (all keys absent = pass by default).
  echo "NOTE: No entitlements found (ad-hoc/unsigned build). Treating as empty."
  ENTITLEMENTS="<plist><dict></dict></plist>"
}

echo "Raw entitlements:"
echo "$ENTITLEMENTS"
echo ""

VIOLATIONS=0

# ── DENY list ────────────────────────────────────────────────────────────────
# These entitlements must NOT be present in Onset.
# Onset is a Developer ID app distributed outside the App Store (no sandbox).
# It requires direct ~/Movies/ access and AVCaptureSession without entitlements.

DENY_LIST=(
  "com.apple.security.app-sandbox"
  # Network client/server entitlements: Onset must not initiate network connections.
  "com.apple.security.network.client"
  "com.apple.security.network.server"
  # App Store-specific entitlements should not appear in Developer ID builds.
  "com.apple.developer.icloud-container-identifiers"
  "com.apple.developer.ubiquity-kvstore-identifier"
)

for ENTITLEMENT in "${DENY_LIST[@]}"; do
  if echo "$ENTITLEMENTS" | grep -q "$ENTITLEMENT"; then
    echo "DENY VIOLATION: $ENTITLEMENT is present and must NOT be"
    VIOLATIONS=$((VIOLATIONS + 1))
  fi
done

# ── ALLOW list audit ─────────────────────────────────────────────────────────
# These are the expected/permitted entitlements for Onset (Developer ID,
# screen recording + audio capture).
# Any entitlement NOT in this list that IS present triggers a warning.
# Update this list as new entitlements are intentionally added.

ALLOWED_LIST=(
  # Screen capture permission (required for screen recording feature)
  "com.apple.security.screen-capture"
  # Camera access (required for webcam overlay recording)
  "com.apple.security.device.camera"
  # Microphone / audio-input access (required for voice recording into video track)
  # Hardened Runtime key is com.apple.security.device.audio-input (not .microphone)
  "com.apple.security.device.audio-input"
  # Debug-only: injected by Xcode to allow debugger attachment; absent in Release/Distribution builds
  "com.apple.security.get-task-allow"
)

# Extract entitlement keys from plist XML for unknown-key detection.
# Uses basic grep — plutil is more robust but requires the file on disk.
PRESENT_KEYS=$(echo "$ENTITLEMENTS" | grep -o '<key>[^<]*</key>' | sed 's/<key>//;s/<\/key>//' || true)

while IFS= read -r KEY; do
  [ -z "$KEY" ] && continue

  # Hardened Runtime relaxations (com.apple.security.cs.*) are never allowed in Onset.
  # Any cs.* entitlement is a hard violation — it weakens the security boundary and
  # would surface immediately rather than as a silent unknown.
  case "$KEY" in
    com.apple.security.cs.*)
      echo "CS VIOLATION: $KEY weakens Hardened Runtime — must not be present in Onset"
      VIOLATIONS=$((VIOLATIONS + 1))
      continue
      ;;
  esac

  FOUND=0
  for ALLOWED in "${ALLOWED_LIST[@]}"; do
    if [ "$KEY" = "$ALLOWED" ]; then
      FOUND=1
      break
    fi
  done
  if [ "$FOUND" -eq 0 ]; then
    echo "UNKNOWN entitlement (not in allow list): $KEY — review if intentional"
    # Warning only, not a hard violation. Add to ALLOWED_LIST if intentional.
    # To make this a hard failure: VIOLATIONS=$((VIOLATIONS + 1))
  fi
done <<< "$PRESENT_KEYS"

# ── Result ───────────────────────────────────────────────────────────────────
echo ""
if [ "$VIOLATIONS" -gt 0 ]; then
  echo "FAIL: $VIOLATIONS entitlement violation(s) found"
  exit 1
else
  echo "PASS: entitlements check passed"
fi
