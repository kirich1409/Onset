#!/usr/bin/env bash
# check-privacy-manifest.sh [path-to-PrivacyInfo.xcprivacy]
#
# Static lint of the privacy manifest — parses the XML source directly, no build
# required. Cheap and deterministic, so it can run as a standalone parallel
# pr-gate job. Also reused against the bundled copy in artifact-checks.
#
# Verifies:
#   1. The file exists.
#   2. It is a valid plist (plutil -lint).
#   3. NSPrivacyAccessedAPICategoryUserDefaults is declared with a NON-EMPTY
#      NSPrivacyAccessedAPITypeReasons array.
#   4. Each declared reason is an official Apple required-reason code for
#      UserDefaults (not an arbitrary string).
#
# Apple required-reason codes (NSPrivacyAccessedAPICategoryUserDefaults):
#   https://developer.apple.com/documentation/bundleresources/privacy_manifest_files/describing-use-of-required-reason-api
#
# Usage: scripts/check-privacy-manifest.sh [path/to/PrivacyInfo.xcprivacy]
#
# Exit codes: 0 = pass, 1 = violation found

set -euo pipefail

MANIFEST="${1:-Onset/PrivacyInfo.xcprivacy}"

# Official Apple required-reason codes for the UserDefaults API category.
USERDEFAULTS_VALID_REASONS=("CA92.1" "1C8F.1" "C56D.1" "AC6B.1")

# ── 1. Existence ───────────────────────────────────────────────────────────────
if [ ! -f "$MANIFEST" ]; then
  echo "::error::PrivacyInfo.xcprivacy not found at $MANIFEST"
  exit 1
fi

echo "Linting privacy manifest: $MANIFEST"

# ── 2. Valid plist ─────────────────────────────────────────────────────────────
# plutil is macOS-only; when present (CI runner) use it as an explicit gate.
# Elsewhere, plistlib.load below validates the plist structure on parse.
if command -v plutil >/dev/null 2>&1; then
  if ! plutil -lint "$MANIFEST" >/dev/null; then
    echo "::error::$MANIFEST is not a valid plist"
    exit 1
  fi
fi

# ── 3 & 4. Extract UserDefaults reasons ────────────────────────────────────────
# plistlib (Python stdlib, present on GitHub-hosted runners) parses the XML
# robustly regardless of array ordering. Prints one reason per line.
REASONS="$(/usr/bin/env python3 - "$MANIFEST" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    manifest = plistlib.load(handle)

for entry in manifest.get("NSPrivacyAccessedAPITypes", []):
    if entry.get("NSPrivacyAccessedAPIType") == "NSPrivacyAccessedAPICategoryUserDefaults":
        for reason in entry.get("NSPrivacyAccessedAPITypeReasons", []):
            print(reason)
PY
)"

if [ -z "$REASONS" ]; then
  echo "::error::NSPrivacyAccessedAPICategoryUserDefaults is missing or declares no reasons (declared reasons must not be empty)"
  exit 1
fi

VIOLATIONS=0
while IFS= read -r REASON; do
  [ -z "$REASON" ] && continue
  FOUND=0
  for VALID in "${USERDEFAULTS_VALID_REASONS[@]}"; do
    if [ "$REASON" = "$VALID" ]; then
      FOUND=1
      break
    fi
  done
  if [ "$FOUND" -eq 1 ]; then
    echo "OK: UserDefaults required-reason '$REASON' is valid"
  else
    echo "::error::Invalid UserDefaults required-reason code: '$REASON' (must be one of: ${USERDEFAULTS_VALID_REASONS[*]})"
    VIOLATIONS=$((VIOLATIONS + 1))
  fi
done <<< "$REASONS"

# ── Result ─────────────────────────────────────────────────────────────────────
echo ""
if [ "$VIOLATIONS" -gt 0 ]; then
  echo "FAIL: $VIOLATIONS privacy-manifest violation(s) found"
  exit 1
else
  echo "PASS: privacy manifest check passed"
fi
