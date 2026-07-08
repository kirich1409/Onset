---
name: onset-ui-loop
description: Drive the running Onset app's UI for verification — launch, click, screenshot, compare — using the recipes that actually work on this machine (cliclick + screencapture, AXPress for pickers, hw-lock). Use for the UI verification loop, "launch the app and check", manual UI testing, or driving Onset for screenshots.
---

# Onset UI-driving loop

The autonomous UI verification loop: build → launch .app → drive → `screencapture` → compare against expectation → fix → repeat. No human in the loop. These are the recipes proven to work on this machine — do not re-derive them.

## Locking and hygiene

- The target Mac is shared (concurrent agent sessions + the owner). Before launching `.app`, grabbing the screen, or any `screencapture`: hold `scripts/hw-lock.sh` (`acquire` … `release` around the whole UI session; `run -- CMD` for one-shot grabs).
- `pgrep -la Onset` before launching; never kill a live instance you don't own (see onset-l5-run Step 0 for the pkill rules).
- Screen Recording/Accessibility TCC are pre-granted to the agent host. On a TCC error: stop and report — never run `tccutil` to self-heal.

## Driving recipes (known-good)

- **Clicks:** AX window geometry flaps on this setup — prefer `cliclick` with coordinates taken from a fresh `screencapture -R x,y,w,h` region shot, not AX-reported frames.
- **Pickers (dropdown/Picker controls):** the ONLY reliable actuation is AX `AXPress` on the picker element (via `osascript` System Events), then AXPress on the menu item. Coordinate clicks on pickers are flaky.
- **Global hotkey ⌘⌥⌃R:** synthetic key events do NOT reach the Carbon hotkey handler — do not test the hotkey synthetically; use the UI (menu bar / record button) instead.
- **Recording start is gated on an audio input** being available — a machine state with no mic visible blocks recording; check the mic picker first.
- **Notifications:** under macOS Focus, the recording banner is delivered silently to Notification Center — absence of a visible banner is not a failure; check NC.

## Context discipline

- Long live UI runs die on the context limit: chunk `manual-tester` sessions into 3–5 steps per agent invocation, then relaunch with the next chunk.
- Screenshots: use `screencapture -R` region shots over full-screen where possible; compare against the expectation and state PASS/FAIL per step.

## Loop skeleton

1. Build (background if long), locate YOUR worktree's `.app` (mtime check — see onset-l5-run Step 3).
2. `hw-lock acquire`.
3. `open <path>/Onset.app`, wait for the window by polling (`until` loop with a bound), never a bare `sleep`.
4. Drive per recipes above; `screencapture -R` after each meaningful state change.
5. Compare, record per-step verdicts; on mismatch — fix code, rebuild, repeat.
6. Quit the app, `hw-lock release`, report with screenshot evidence.
