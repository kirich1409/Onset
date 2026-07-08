---
name: onset-l5-run
description: Run Onset L5 hardware test suites (capture/encode on real camera+screen) correctly — signed build, hw-lock, correct test-plan invocation, and frame-level verification. Use when running L5 tests, "run hardware tests", "run Onset-L5", "verify on real hardware", or when a task's acceptance requires L5 on the target Mac.
---

# Onset L5 run

Procedure for running L5 (real-hardware) test suites without the known traps. Follow the steps in order.

## Step 0 — preconditions

1. `pgrep -la Onset` — check for live test hosts or the owner's app. `pkill -9 Onset` (exactly this name, never broader) is allowed ONLY for a stale/hung host: no live lock held, a dead lock PID, or the owner's explicit OK. Never kill a live run.
2. Hold the machine-global hardware lock for the whole run: `scripts/hw-lock.sh run [--wait] -- CMD` for a single grab, or `acquire`/`release` around a multi-step session. Concurrent sessions and the owner share one camera/screen.
3. One `xcodebuild test` at a time — parallel hardware tests fight over the camera and hang.

## Step 1 — signed build

L5 requires a SIGNED build: drop `CODE_SIGNING_ALLOWED=NO` for build-for-testing. An unsigned test host writes a sticky TCC deny for screen capture (recovery: `tccutil reset ScreenCapture` by the user + manual re-grant — do not run tccutil yourself).

Personal Team provisions camera + audio entitlements fine; only time-sensitive entitlements need a paid Apple Developer Program. Camera/screen L5 is therefore always feasible on this machine.

## Step 2 — invoke via test plan, never env prefix

```bash
xcodebuild test -scheme Onset -testPlan Onset-L5 -destination 'platform=macOS' -configuration Debug ONLY_ACTIVE_ARCH=YES
```

- A shell env prefix (`ONSET_RUN_L5_CAPTURE=1 xcodebuild ...`) does NOT reach the test host → suites silently skip and report "1 test passed" in ~0.001s. The test plan is the only reliable carrier of `ONSET_RUN_L5_CAPTURE` / `ONSET_RUN_L5_ENCODE`.
- `-only-testing` matches suites, not functions.
- The verdict is the Swift Testing summary line; the XCTest "Executed 0 tests" banner is false. Never use `-quiet` (hides the summary).

## Step 3 — verify by artifacts, not exit code

- A green exit code with suspiciously fast L5 suites (<1s) means the env gate silently skipped — treat as FAIL and recheck Step 2.
- Recordings land in session subfolders `Onset <timestamp>/` inside the user-selected base dir (default `~/Movies/Onset/`). Verify actual frames: run `scripts/verify-cfr.sh screen.mp4 camera.mp4 60 30` or the checks from the `onset-verify-recording` skill.
- When locating a built `.app` in DerivedData, never take `find DerivedData -name Onset.app | head` — each worktree has its own DerivedData hash and you may grab another worktree's build. Confirm the app binary's mtime is newer than the newest source mtime in YOUR worktree; otherwise you will falsely conclude "the fix doesn't work".
- When reading system logs, always use the absolute path `/usr/bin/log` — the zsh builtin `log` shadows it and bare `log show` is silently empty.

## Step 4 — cleanup

Release the hw-lock, confirm no orphan Onset hosts remain (`pgrep -la Onset`).
