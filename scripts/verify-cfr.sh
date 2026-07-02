#!/usr/bin/env bash
# verify-cfr.sh <screen.mp4> <camera.mp4> <screen_fps> <camera_fps>
#
# PASS/FAIL verification harness for CFR (Constant Frame Rate) recording cadence.
# Measures actual packet timestamps — never reads r_frame_rate / avg_frame_rate /
# nb_frames metadata, which nominal encoding lies about.
#
# Usage:
#   scripts/verify-cfr.sh screen.mp4 camera.mp4 60 30
#
# Exit codes: 0 = all checks pass, 1 = one or more checks fail, 2 = missing deps
#
# Negative-control expectation (GitHub issue #102 bad baseline):
#   ./scripts/verify-cfr.sh \
#     ~/Movies/Onset/Onset-1780682249-screen.mp4 \
#     ~/Movies/Onset/Onset-1780682250-camera.mp4 60 30
#   MUST FAIL on:
#     - screen packet rate  (measured ~42.3 vs expected 60)
#     - screen PTS-delta uniformity  (large gaps from skipped slots)
#     - camera packet rate  (measured ~28.2 vs expected 30, ~6% off)
#     - camera fresh content  (measured ~2.9 fps vs floor 25)
#     - camera duplicate-run clusters  (modal run ~13, far above MAX_RUN_MODE=2)
#   NOTE: camera PTS-delta uniformity (B) may now PASS on the bad baseline after the
#   sort-n fix — camera packets arrive in decode order with B-frame reordering producing
#   negative deltas on unsorted input; sorting before delta computation removes false gaps.
#
# NOTE: camera fresh-content check (C) requires actual motion in frame during
# recording. A static scene with no movement will produce keep_count=0 and
# fresh_fps=0, which is indistinguishable from a duplicate-frame bug. Run with
# footage that contains camera movement or a moving subject.

set -euo pipefail

# ── Threshold constants ───────────────────────────────────────────────────────

# Packet-rate tolerance: |measured_fps − nominal_fps| / nominal_fps ≤ RATE_TOL_PCT/100
RATE_TOL_PCT=2

# PTS-delta uniformity: a delta > GAP_SLOTS * slot_duration counts as a gap.
GAP_SLOTS=1.5

# Maximum allowed PTS delta expressed in slot units.
MAX_GAP_SLOTS=2.0

# Maximum allowed gap-deltas per minute of recording (accommodates start/stop edge artefacts).
# The actual per-file allowance is computed inside awk as ceil(duration_min * MAX_GAPS_PER_MIN).
MAX_GAPS_PER_MIN=10

# Camera fresh-content floor (keep fps from mpdecimate; requires motion in frame).
# Overridable via env (#297 AC-2): stabilization acceptance compares ON/OFF pairs by the
# RELATIVE fresh_fps delta, so the absolute gate is disabled for those runs:
#   MIN_FRESH_FPS=0 scripts/verify-cfr.sh …
# (the Brio's 20–25 fps passes the default 25 floor only by luck, and on 4K both halves of a
# pair would fail it). The machine-extractable "FRESH_FPS=<value>" line below feeds the delta.
MIN_FRESH_FPS="${MIN_FRESH_FPS:-25}"

# Modal duplicate-run length must be ≤ this.
MAX_RUN_MODE=2

# No run-length ≥ LONG_RUN_LEN may occur ≥ LONG_RUN_MAX times.
LONG_RUN_LEN=5
LONG_RUN_MAX=10

# ── Argument validation ───────────────────────────────────────────────────────

if [ $# -ne 4 ]; then
  echo "Usage: $0 <screen.mp4> <camera.mp4> <screen_fps> <camera_fps>"
  exit 2
fi

SCREEN_FILE="$1"
CAMERA_FILE="$2"
SCREEN_FPS="$3"
CAMERA_FPS="$4"

# ── Dependency check ──────────────────────────────────────────────────────────

for CMD in ffprobe ffmpeg; do
  if ! command -v "$CMD" > /dev/null 2>&1; then
    echo "ERROR: required tool '$CMD' not found in PATH"
    exit 2
  fi
done

# ── Input file check ──────────────────────────────────────────────────────────

for FILE in "$SCREEN_FILE" "$CAMERA_FILE"; do
  if [ ! -f "$FILE" ]; then
    echo "ERROR: file not found: $FILE"
    exit 2
  fi
done

# ── Helpers ───────────────────────────────────────────────────────────────────

PASS_COUNT=0
FAIL_COUNT=0

report() {
  local verdict="$1"  # PASS or FAIL
  local name="$2"
  local measured="$3"
  local expected="$4"
  if [ "$verdict" = "PASS" ]; then
    echo "PASS  $name: $measured vs $expected"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL  $name: $measured vs $expected"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ── Collect PTS timestamps ────────────────────────────────────────────────────
# Run ffprobe once per file; reuse the pts list for both A (rate) and B (deltas).

echo ""
echo "=== Collecting packet timestamps ==="

SCREEN_PTS=$(ffprobe -v error \
  -select_streams v:0 \
  -show_entries packet=pts_time \
  -of csv=p=0 \
  "$SCREEN_FILE" 2>/dev/null) || true

if [ -z "$SCREEN_PTS" ]; then
  echo "WARNING: ffprobe returned no packets for screen file ($SCREEN_FILE)"
fi

CAMERA_PTS=$(ffprobe -v error \
  -select_streams v:0 \
  -show_entries packet=pts_time \
  -of csv=p=0 \
  "$CAMERA_FILE" 2>/dev/null) || true

if [ -z "$CAMERA_PTS" ]; then
  echo "WARNING: ffprobe returned no packets for camera file ($CAMERA_FILE)"
fi

# ── mpdecimate: single run for checks C and D ─────────────────────────────────
# mpdecimate on long files is slow — may take ~1 min per 10 min of video.

echo "Analyzing camera content (may take ~1 min per 10 min of video)..."

MPDECIMATE_OUT=$(ffmpeg -hide_banner \
  -i "$CAMERA_FILE" \
  -vf mpdecimate \
  -loglevel debug \
  -f null - 2>&1) || true

if [ -z "$MPDECIMATE_OUT" ]; then
  echo "WARNING: ffmpeg mpdecimate produced no output — camera file may be unreadable"
fi

# ── A. Packet rate ────────────────────────────────────────────────────────────
# rate = (count − 1) / (last_pts − first_pts)
# PASS iff |rate − fps| / fps ≤ RATE_TOL_PCT / 100

echo ""
echo "=== A. Packet rate ==="

for LABEL_FPS in "screen:$SCREEN_FPS:$SCREEN_PTS" "camera:$CAMERA_FPS:$CAMERA_PTS"; do
  LABEL="${LABEL_FPS%%:*}"
  REST="${LABEL_FPS#*:}"
  NOMINAL="${REST%%:*}"
  PTS_DATA="${REST#*:}"

  RESULT=$(echo "$PTS_DATA" | awk \
    -v nominal="$NOMINAL" \
    -v tol="$RATE_TOL_PCT" \
    'BEGIN { first=""; last=""; count=0 }
     /^[0-9]/ {
       if (first == "") first = $1
       last = $1
       count++
     }
     END {
       if (count < 2) {
         print "FAIL measured=0 (insufficient packets)"
         exit
       }
       span = last - first
       if (span <= 0) {
         print "FAIL measured=0 (zero span)"
         exit
       }
       rate = (count - 1) / span
       err = (rate - nominal)
       if (err < 0) err = -err
       rel = err / nominal
       thresh = tol / 100.0
       verdict = (rel <= thresh) ? "PASS" : "FAIL"
       printf "%s measured=%.2f expected=%s tol=%s%%\n", verdict, rate, nominal, tol
     }') || true

  VERDICT="${RESULT%% *}"
  MEASURED=$(echo "$RESULT" | grep -oE 'measured=[^ ]+' | cut -d= -f2)
  EXPECTED=$(echo "$RESULT" | grep -oE 'expected=[^ ]+' | cut -d= -f2)
  TOL_MSG=$(echo "$RESULT" | grep -oE 'tol=[^ ]+' | cut -d= -f2)
  report "$VERDICT" "packet-rate-$LABEL" "${MEASURED} fps" "${EXPECTED} fps (±${TOL_MSG})"
done

# ── B. PTS-delta uniformity ───────────────────────────────────────────────────
# PTS list is sorted numerically before delta computation to handle B-frame decode
# order: packets arrive in decode order, not presentation order, so raw deltas can be
# negative. Sorting restores presentation order and yields true inter-frame gaps.
#
# slot = 1 / fps
# max_gap_count = ceil(duration_min * MAX_GAPS_PER_MIN)  — scales with recording length
# PASS iff max_delta ≤ MAX_GAP_SLOTS·slot AND count(delta > GAP_SLOTS·slot) ≤ max_gap_count

echo ""
echo "=== B. PTS-delta uniformity ==="

for LABEL_FPS in "screen:$SCREEN_FPS:$SCREEN_PTS" "camera:$CAMERA_FPS:$CAMERA_PTS"; do
  LABEL="${LABEL_FPS%%:*}"
  REST="${LABEL_FPS#*:}"
  NOMINAL="${REST%%:*}"
  PTS_DATA="${REST#*:}"

  # sort -n: restore presentation order (B-frame decode order can scramble PTS).
  RESULT=$(echo "$PTS_DATA" | LC_ALL=C sort -n | awk \
    -v fps="$NOMINAL" \
    -v max_gap_slots="$MAX_GAP_SLOTS" \
    -v gap_slots="$GAP_SLOTS" \
    -v max_gaps_per_min="$MAX_GAPS_PER_MIN" \
    'BEGIN { prev=""; max_delta=0; gap_count=0; n=0; first=""; last="" }
     /^[0-9]/ {
       if (first == "") first = $1
       last = $1
       if (prev != "") {
         d = $1 - prev
         if (d > max_delta) max_delta = d
         slot = 1.0 / fps
         if (d > gap_slots * slot) gap_count++
       }
       prev = $1
       n++
     }
     END {
       slot = 1.0 / fps
       max_allowed = max_gap_slots * slot
       if (n < 2) {
         printf "FAIL max_delta=0.0000 max_allowed=%.4f gap_count=0 max_gap_count=0 (insufficient packets: %d)\n", \
           max_allowed, n
         exit
       }
       span = last - first
       duration_min = (span > 0) ? span / 60.0 : 0
       # ceil(duration_min * max_gaps_per_min), minimum 1 to allow one edge artefact
       raw = duration_min * max_gaps_per_min
       max_gap_count = int(raw) + (raw > int(raw) ? 1 : 0)
       if (max_gap_count < 1) max_gap_count = 1
       verdict = (max_delta <= max_allowed && gap_count <= max_gap_count) ? "PASS" : "FAIL"
       printf "%s max_delta=%.4f max_allowed=%.4f gap_count=%d max_gap_count=%d\n", \
         verdict, max_delta, max_allowed, gap_count, max_gap_count
     }') || true

  VERDICT="${RESULT%% *}"
  MAX_D=$(echo "$RESULT" | grep -oE 'max_delta=[^ ]+' | head -1 | cut -d= -f2)
  MAX_A=$(echo "$RESULT" | grep -oE 'max_allowed=[^ ]+' | cut -d= -f2)
  # Use word-boundary pattern to avoid matching max_gap_count= as well.
  GAP_C=$(echo "$RESULT" | grep -oE '[^_]gap_count=[^ ]+' | cut -d= -f2)
  MAX_GC=$(echo "$RESULT" | grep -oE 'max_gap_count=[^ ]+' | cut -d= -f2)
  report "$VERDICT" "pts-uniformity-$LABEL" \
    "max_delta=${MAX_D}s gap_count=${GAP_C}" \
    "max_delta≤${MAX_A}s gap_count≤${MAX_GC}"
done

# ── C. Camera fresh content ───────────────────────────────────────────────────
# fresh_fps = keep_count / pts_span
# PASS iff fresh_fps ≥ MIN_FRESH_FPS

echo ""
echo "=== C. Camera fresh content ==="

# Duration reused from camera pts span (already measured in A).
CAMERA_DURATION=$(echo "$CAMERA_PTS" | awk \
  'BEGIN { first=""; last="" }
   /^[0-9]/ { if (first=="") first=$1; last=$1 }
   END { if (first=="" || last=="") print "0"; else print last - first }') || true

RESULT=$(echo "$MPDECIMATE_OUT" | awk \
  -v duration="$CAMERA_DURATION" \
  -v min_fps="$MIN_FRESH_FPS" \
  '/Parsed_mpdecimate/ && (/ drop /||/ keep /) {
     if (/ keep /) keep_count++
   }
   END {
     if (duration <= 0 || keep_count == 0) {
       printf "FAIL fresh_fps=0.00 min_fps=%s\n", min_fps
       exit
     }
     fresh = keep_count / duration
     verdict = (fresh >= min_fps) ? "PASS" : "FAIL"
     printf "%s fresh_fps=%.2f min_fps=%s\n", verdict, fresh, min_fps
   }') || true

VERDICT="${RESULT%% *}"
FRESH=$(echo "$RESULT" | grep -oE 'fresh_fps=[^ ]+' | cut -d= -f2)
MIN_F=$(echo "$RESULT" | grep -oE 'min_fps=[^ ]+' | cut -d= -f2)
report "$VERDICT" "camera-fresh-content" "${FRESH} fps" "≥${MIN_F} fps"
# Machine-extractable line for the #297 AC-2 ON/OFF freshness delta:
#   grep '^FRESH_FPS=' | cut -d= -f2
echo "FRESH_FPS=${FRESH}"

# ── D. No duplicate-run clusters ─────────────────────────────────────────────
# Build run-length histogram of consecutive drop sequences from mpdecimate.
# PASS iff modal run length ≤ MAX_RUN_MODE AND no run ≥ LONG_RUN_LEN occurs ≥ LONG_RUN_MAX times.

echo ""
echo "=== D. Duplicate-run clusters (camera) ==="

RESULT=$(echo "$MPDECIMATE_OUT" | awk \
  -v max_run_mode="$MAX_RUN_MODE" \
  -v long_run_len="$LONG_RUN_LEN" \
  -v long_run_max="$LONG_RUN_MAX" \
  'BEGIN { run=0; total=0 }
   /Parsed_mpdecimate/ && (/ drop /||/ keep /) {
     total++
     if (/ drop /) {
       run++
     } else {
       # flush on keep
       if (run > 0) {
         hist[run]++
         run = 0
       }
     }
   }
   END {
     if (total == 0) {
       printf "FAIL mode_run=0 max_run_mode=%d long_fail=0 long_run_len=%d long_run_max=%d (no mpdecimate data)\n", \
         max_run_mode, long_run_len, long_run_max
       exit
     }

     # flush any trailing run
     if (run > 0) hist[run]++

     # find modal run length (most frequent)
     mode_len = 0
     mode_cnt = 0
     for (len in hist) {
       if (hist[len] > mode_cnt) {
         mode_cnt = hist[len]
         mode_len = len
       }
     }

     # check long-run constraint
     long_fail = 0
     for (len in hist) {
       if (len >= long_run_len && hist[len] >= long_run_max) {
         long_fail = 1
       }
     }

     mode_ok = (mode_len <= max_run_mode)
     verdict = (mode_ok && !long_fail) ? "PASS" : "FAIL"
     printf "%s mode_run=%d max_run_mode=%d long_fail=%d long_run_len=%d long_run_max=%d\n", \
       verdict, mode_len, max_run_mode, long_fail, long_run_len, long_run_max
   }') || true

VERDICT="${RESULT%% *}"
MODE_R=$(echo "$RESULT" | grep -oE 'mode_run=[^ ]+' | cut -d= -f2)
MAX_RM=$(echo "$RESULT" | grep -oE 'max_run_mode=[^ ]+' | cut -d= -f2)
LONG_F=$(echo "$RESULT" | grep -oE 'long_fail=[^ ]+' | cut -d= -f2)
LONG_RL=$(echo "$RESULT" | grep -oE 'long_run_len=[^ ]+' | cut -d= -f2)
LONG_RM=$(echo "$RESULT" | grep -oE 'long_run_max=[^ ]+' | cut -d= -f2)
report "$VERDICT" "camera-run-clusters" \
  "mode_run=${MODE_R} long_fail=${LONG_F}" \
  "mode_run≤${MAX_RM} no_run≥${LONG_RL}_appears≥${LONG_RM}x"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
TOTAL=$((PASS_COUNT + FAIL_COUNT))
echo "────────────────────────────────────────────────────────────────────────"
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "RESULT: PASS ($PASS_COUNT/$TOTAL)"
  exit 0
else
  echo "RESULT: FAIL ($PASS_COUNT/$TOTAL)"
  exit 1
fi
