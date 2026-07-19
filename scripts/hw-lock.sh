#!/usr/bin/env bash
# hw-lock.sh — serialize exclusive access to the shared target Mac's hardware.
#
# Concurrent agent sessions (and the owner) share ONE machine's camera, screen,
# and running Onset.app. Any operation that grabs that hardware — L5 tests, the
# UI verification loop, launching Onset.app, screencapture — must hold this lock
# so sessions don't fight over the devices and hang.
#
# The lock STATE is machine-global (/tmp/onset-hw.lock), never per-checkout:
# concurrent sessions run in separate clones, so an in-repo lock would be
# invisible across them. The atomic primitive is `mkdir`, which succeeds for
# exactly one process; the holder's liveness PID is recorded so a crashed
# session's stale lock can be reclaimed. The lock is a coordination aid, not a
# hard guarantee — reclaim-by-dead-PID plus a TTL bound the worst case.
#
# Usage:
#   scripts/hw-lock.sh run [--wait [SECONDS]] -- CMD [ARGS...]
#       Hold the lock only while CMD runs, then release (even on failure).
#       Robust and self-scoped — preferred for a single hardware grab.
#   scripts/hw-lock.sh acquire [--wait [SECONDS]] [--ttl SECONDS]
#       Take the lock and hold it across later, separate commands (e.g. the UI
#       loop). A detached keepalive represents the holder and self-expires after
#       TTL (default 1800s), so a crashed session cannot pin the lock forever.
#   scripts/hw-lock.sh release
#       Release the lock (kills the keepalive, removes the lock dir).
#   scripts/hw-lock.sh status
#       Report the current holder, or that the lock is free/stale.
#
# --wait polls until the lock frees (optionally bounded by SECONDS); without it,
# a busy lock fails immediately so the caller can defer.
#
# Exit codes: 0 success · 1 busy or CMD failed · 2 usage error.

set -euo pipefail

LOCK_DIR="${ONSET_HW_LOCK_DIR:-/tmp/onset-hw.lock}"
PID_FILE="$LOCK_DIR/pid"
TTL="${ONSET_HW_LOCK_TTL:-1800}"
POLL="${ONSET_HW_LOCK_POLL:-3}"

holder_pid() { [ -f "$PID_FILE" ] && cat "$PID_FILE" 2>/dev/null || true; }

# 0 if the recorded holder is a live process, non-zero if dead or missing.
holder_alive() {
  local pid
  pid="$(holder_pid)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Atomically take the lock, recording $1 as the liveness token. Reclaims a stale
# lock whose recorded holder is no longer running. Returns 0 on success, 1 if a
# live holder owns it.
_take() {
  local holder="$1" stale
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$holder" > "$PID_FILE"
    return 0
  fi
  if ! holder_alive; then
    stale="$(holder_pid)"
    echo "hw-lock: reclaiming stale lock (holder ${stale:-unknown} not running)" >&2
    rm -rf "$LOCK_DIR"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      printf '%s\n' "$holder" > "$PID_FILE"
      return 0
    fi
  fi
  return 1
}

# Take the lock, optionally polling until it frees. Args: holder want_wait timeout.
_take_waiting() {
  local holder="$1" want_wait="$2" timeout="$3" waited=0
  if _take "$holder"; then return 0; fi
  if [ "$want_wait" -eq 0 ]; then
    echo "hw-lock: busy — held by live PID $(holder_pid), not waiting" >&2
    return 1
  fi
  while true; do
    sleep "$POLL"
    waited=$((waited + POLL))
    if _take "$holder"; then
      echo "hw-lock: acquired after ${waited}s" >&2
      return 0
    fi
    if [ "$timeout" -gt 0 ] && [ "$waited" -ge "$timeout" ]; then
      echo "hw-lock: timed out after ${timeout}s — still held by PID $(holder_pid)" >&2
      return 1
    fi
  done
}

# Consume a leading "--wait [SECONDS]" from the argument list, setting WANT_WAIT
# and TIMEOUT. Leaves the remaining args in REST.
WANT_WAIT=0
TIMEOUT=0
REST=()
_parse_wait() {
  WANT_WAIT=0
  TIMEOUT=0
  REST=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --wait)
        WANT_WAIT=1
        shift
        if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
          TIMEOUT="$1"
          shift
        fi
        ;;
      *)
        REST+=("$1")
        shift
        ;;
    esac
  done
}

cmd_run() {
  _parse_wait "$@"
  set -- ${REST[@]+"${REST[@]}"}
  if [ "${1:-}" != "--" ]; then
    echo "hw-lock: run needs '-- CMD [ARGS...]'" >&2
    return 2
  fi
  shift
  if [ $# -eq 0 ]; then
    echo "hw-lock: run needs a command after '--'" >&2
    return 2
  fi
  # Holder is THIS process: it stays alive for exactly the command's duration,
  # so liveness/reclaim is precise and release is automatic on any exit.
  _take_waiting "$$" "$WANT_WAIT" "$TIMEOUT" || return 1
  trap 'rm -rf "$LOCK_DIR"' EXIT
  "$@"
}

cmd_acquire() {
  local ttl="$TTL" rest=()
  # Split out --ttl first, then reuse the shared --wait parser.
  while [ $# -gt 0 ]; do
    case "$1" in
      --ttl)
        shift
        ttl="${1:?hw-lock: --ttl needs SECONDS}"
        shift
        ;;
      *)
        rest+=("$1")
        shift
        ;;
    esac
  done
  _parse_wait ${rest[@]+"${rest[@]}"}
  if [ ${#REST[@]} -ne 0 ]; then
    echo "hw-lock: unexpected args: ${REST[*]}" >&2
    return 2
  fi
  # Record this live process first, then hand the lock to a detached keepalive so
  # it survives past this short invocation but self-expires after TTL.
  _take_waiting "$$" "$WANT_WAIT" "$TIMEOUT" || return 1
  nohup sleep "$ttl" >/dev/null 2>&1 &
  local keep=$!
  disown "$keep" 2>/dev/null || true
  printf '%s\n' "$keep" > "$PID_FILE"
  echo "hw-lock: acquired (holder $keep, ttl ${ttl}s)"
}

cmd_release() {
  if [ ! -d "$LOCK_DIR" ]; then
    echo "hw-lock: not held"
    return 0
  fi
  local pid
  pid="$(holder_pid)"
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  rm -rf "$LOCK_DIR"
  echo "hw-lock: released"
}

cmd_status() {
  if [ ! -d "$LOCK_DIR" ]; then
    echo "hw-lock: free"
    return 0
  fi
  local pid
  pid="$(holder_pid)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "hw-lock: held by live holder PID $pid"
  else
    echo "hw-lock: stale (holder ${pid:-unknown} not running) — next acquire reclaims it"
  fi
}

usage() { sed -n '16,31p' "$0"; }

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  run) cmd_run "$@" ;;
  acquire) cmd_acquire "$@" ;;
  release) cmd_release "$@" ;;
  status) cmd_status "$@" ;;
  ""|-h|--help|help) usage ;;
  *) echo "hw-lock: unknown command: $cmd" >&2; usage >&2; exit 2 ;;
esac
