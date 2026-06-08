#!/usr/bin/env bash
# coverage-summary.sh <path-to-Result.xcresult>
#
# Renders a self-contained test-result + code-coverage summary from an Xcode
# result bundle — no external service. Writes GitHub-flavoured Markdown to
# $GITHUB_STEP_SUMMARY when set (CI), else to stdout (local inspection).
#
# Test counts come from the Xcode 16+ subcommand:
#   xcrun xcresulttool get test-results summary --path <bundle> --format json
# (the legacy `xcresulttool get --format json` is deprecated and requires
# --legacy on Xcode 16+; the new schema is used here.)
# Coverage comes from:
#   xcrun xccov view --report --json <bundle>
# which reads the .xcresult bundle directly.
#
# Optional gate: set ONSET_COVERAGE_MIN to a percentage (e.g. 60). When set and
# overall line coverage is below it, emits ::error:: and exits 1. Unset (the
# default) is report-only.
#
# Usage: scripts/coverage-summary.sh <path/to/Result.xcresult>
#
# Exit codes: 0 = summary written (threshold met, or no threshold set),
#             1 = bundle unreadable, or coverage below ONSET_COVERAGE_MIN.

set -euo pipefail

BUNDLE="${1:?Usage: $0 <path/to/Result.xcresult>}"
COVERAGE_MIN="${ONSET_COVERAGE_MIN:-}"

if [ ! -e "$BUNDLE" ]; then
  echo "::error::xcresult bundle not found at $BUNDLE"
  exit 1
fi

# Markdown destination: GitHub job summary in CI, stdout when run locally.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  OUT="$GITHUB_STEP_SUMMARY"
else
  OUT="/dev/stdout"
fi

# The overall coverage percentage is written to a side file (not stdout) so the
# Markdown — which may itself go to stdout locally — never collides with it.
PCT_FILE="$(mktemp)"
trap 'rm -f "$PCT_FILE"' EXIT

# Gather the two JSON payloads. Either may be absent (e.g. the plan ran without
# coverage); degrade to an empty object rather than failing the step — this is a
# report-only summary, so a tooling hiccup must not red an otherwise-green run.
# The only hard failures are a missing bundle (above) and the optional gate.
TEST_JSON="$(xcrun xcresulttool get test-results summary --path "$BUNDLE" --format json 2>/dev/null || echo '{}')"
COV_JSON="$(xcrun xccov view --report --json "$BUNDLE" 2>/dev/null || echo '{}')"
export TEST_JSON COV_JSON

# python3 is present on every GitHub-hosted runner — same dependency posture as
# check-privacy-manifest.sh. Renders Markdown to arg 1, writes the overall
# coverage percent (or "none") to arg 2 for the optional gate below.
/usr/bin/env python3 - "$OUT" "$PCT_FILE" <<'PY'
import json
import os
import sys

out_path, pct_path = sys.argv[1], sys.argv[2]
test = json.loads(os.environ["TEST_JSON"])
cov = json.loads(os.environ["COV_JSON"])

result = test.get("result", "unknown")
total = test.get("totalTestCount", 0)
passed = test.get("passedTests", 0)
failed = test.get("failedTests", 0)
skipped = test.get("skippedTests", 0)
xfail = test.get("expectedFailures", 0)

md = []
verdict = "✅ Passed" if result == "Passed" else f"❌ {result}"
md += ["## Unit Tests", "", f"**Result:** {verdict}", ""]
md += [
    "| Total | Passed | Failed | Skipped | Expected failures |",
    "|------:|-------:|-------:|--------:|------------------:|",
    f"| {total} | {passed} | {failed} | {skipped} | {xfail} |",
    "",
]

overall = "none"
targets = cov.get("targets") or []
if targets:
    overall = f"{cov.get('lineCoverage', 0.0) * 100:.2f}"
    md += ["## Code Coverage", "", f"**Overall line coverage:** {overall}%", ""]
    md += [
        "| Target | Line coverage | Covered / Executable |",
        "|--------|--------------:|---------------------:|",
    ]
    for target in targets:
        pct = target.get("lineCoverage", 0.0) * 100
        md.append(
            f"| {target.get('name', '?')} | {pct:.2f}% | "
            f"{target.get('coveredLines', 0)} / {target.get('executableLines', 0)} |"
        )
    md.append("")
    files = sorted(
        (f for target in targets for f in target.get("files", [])),
        key=lambda f: f.get("lineCoverage", 0.0),
    )
    if files:
        md += ["<details><summary>Lowest-covered files</summary>", ""]
        md += ["| File | Line coverage |", "|------|--------------:|"]
        for f in files[:10]:
            md.append(f"| {f.get('name', '?')} | {f.get('lineCoverage', 0.0) * 100:.2f}% |")
        md += ["", "</details>", ""]
else:
    md += ["## Code Coverage", "", "_No coverage data in result bundle._", ""]

with open(out_path, "a", encoding="utf-8") as handle:
    handle.write("\n".join(md) + "\n")
with open(pct_path, "w", encoding="utf-8") as handle:
    handle.write(overall)
PY

OVERALL_PCT="$(< "$PCT_FILE")"

# ── Optional threshold gate (default OFF: report-only) ──────────────────────
if [ -n "$COVERAGE_MIN" ] && [ "$OVERALL_PCT" != "none" ]; then
  # bash lacks float comparison; awk exits 0 (success) when below the threshold.
  if awk "BEGIN { exit !($OVERALL_PCT < $COVERAGE_MIN) }"; then
    echo "::error::Code coverage ${OVERALL_PCT}% is below the required minimum ${COVERAGE_MIN}%"
    exit 1
  fi
  echo "Code coverage ${OVERALL_PCT}% meets the required minimum ${COVERAGE_MIN}%"
fi
