#!/usr/bin/env bash
#
# scripts/setup-hooks.sh — point git at the repo's tracked hooks.
#
# Run once per clone. Sets core.hooksPath to .githooks so the version-controlled
# pre-commit hook runs. No third-party frameworks, no Python. The hook is fail-fast
# convenience (bypassable with --no-verify); the authority is CI.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

git config core.hooksPath .githooks

echo "setup-hooks: core.hooksPath set to .githooks"
echo "             pre-commit will run scripts/check.sh --lint (bypass with --no-verify)."
