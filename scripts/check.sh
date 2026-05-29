#!/usr/bin/env bash
#
# scripts/check.sh — local checks for Onset (the SOFT layer).
#
# This is a fail-fast convenience for developers and the pre-commit hook. It is NOT
# the authority: a `--no-verify` commit bypasses it, and an agent may edit it. The
# airtight guarantees live inline in .github/workflows/ci.yml job `hard-gates`, which
# the production agent's PAT cannot modify (no workflows:write). Keep this in sync with
# the lint job, but never rely on it as the merge gate.
#
# Package.swift is at Packages/OnsetKit/Package.swift (NOT repo root); swift commands
# run from there.
#
# Usage:
#   scripts/check.sh --lint   swift-format lint + swiftlint (fast, used by pre-commit)
#   scripts/check.sh --full   build + test + lint (local pre-PR sanity)

set -euo pipefail

# Resolve repo root from this script's location so it works from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PACKAGE_DIR="${REPO_ROOT}/Packages/OnsetKit"

cd "${REPO_ROOT}"

usage() {
  echo "Usage: $0 [--lint | --full]" >&2
  exit 2
}

run_lint() {
  echo "==> swift-format lint --strict"
  # Same invocation as ci.yml job `lint`. Xcode-toolchain swift-format for determinism;
  # explicit --configuration so there is no auto-discovery ambiguity.
  xcrun swift-format lint --strict --recursive \
    --configuration .swift-format \
    Packages/OnsetKit/Sources Packages/OnsetKit/Tests onset onsetTests onsetUITests

  echo "==> SwiftLint"
  if command -v swiftlint >/dev/null 2>&1; then
    # Local SwiftLint may differ from the CI-pinned 0.63.3; CI is the authority on version.
    swiftlint lint --strict --config .swiftlint.yml
  else
    echo "    SwiftLint not installed locally — skipped (CI runs the pinned 0.63.3)." >&2
  fi
}

run_build_and_test() {
  echo "==> swift build (package)"
  ( cd "${PACKAGE_DIR}" && swift build )

  echo "==> swift test (package)"
  ( cd "${PACKAGE_DIR}" && swift test )

  echo "==> xcodebuild test (app target, UI tests skipped)"
  set -o pipefail
  local beautify=cat
  if command -v xcbeautify >/dev/null 2>&1; then
    beautify=xcbeautify
  fi
  xcodebuild test \
    -project onset.xcodeproj \
    -scheme onset \
    -destination 'platform=macOS' \
    -skip-testing:onsetUITests \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    | "${beautify}"
}

case "${1:-}" in
  --lint)
    run_lint
    ;;
  --full)
    run_build_and_test
    run_lint
    ;;
  *)
    usage
    ;;
esac

echo "check.sh: OK"
