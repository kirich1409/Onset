#!/usr/bin/env bash
# preflight.sh — single local pre-push gate.
#
# Runs the same checks as the CI pr-gate's lint / privacy-manifest / build / unit
# jobs, ordered cheapest-first so failures surface in seconds, not minutes:
#   1. SwiftFormat (lint mode)
#   2. SwiftLint (strict)
#   3. Privacy manifest static lint
#   4. xcodebuild test (builds with warnings-as-errors, then runs L2 Swift Testing)
#
# Local green here ⇒ CI pr-gate green (artifact-checks excepted — they need the
# built .app and run in CI after build).
#
# xcodebuild output pipes through xcbeautify when installed; the Swift Testing
# summary line survives xcbeautify, so the verdict stays visible.
#
# Usage: scripts/preflight.sh
# Exit codes: 0 = all gates pass, non-zero = first failing gate

set -euo pipefail
cd "$(dirname "$0")/.."

BEAUTIFY="cat"
if command -v xcbeautify >/dev/null 2>&1; then
  BEAUTIFY="xcbeautify"
fi

echo "── 1/4 SwiftFormat (lint) ──────────────────────────────────────────────"
swiftformat --lint .

echo "── 2/4 SwiftLint (strict) ──────────────────────────────────────────────"
swiftlint lint --strict --config .swiftlint.yml

echo "── 3/4 Privacy manifest ────────────────────────────────────────────────"
scripts/check-privacy-manifest.sh Onset/PrivacyInfo.xcprivacy

echo "── 4/4 Build + unit tests (Swift Testing, L2) ──────────────────────────"
xcodebuild test \
  -scheme Onset \
  -destination 'platform=macOS' \
  -configuration Debug \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  | "$BEAUTIFY"

echo "── preflight: all gates green ──────────────────────────────────────────"
