# Progress: Settings (⌘,) window — v1

> Plan: ./plan.md · Tasks: ./tasks.md

## Status
- [x] T-1 — Domain types in Configuration/ (SettingApplyPolicy, SettingsKeys) ✅ build+L2 green
- [x] T-2 — Per-key settings store (timer, mirror) ✅ build+L2 green
- [x] T-3 — Shared @Observable AppSettings (in-memory source of truth) ✅ build+L2 green (901 tests)
- [x] T-4 — Add cameraMirror to RecordingConfiguration ✅ build+L2 green
- [x] T-5 — Read mirror at record seam + provide AppSettings to preview ✅ build green
- [x] T-6 — Menu-bar timer toggle (consumer) ✅ build+L2 green (timer-toggle suite)
- [x] T-7 — Camera mirror (recording path + live preview) ✅ impl+build green; L5 PASS — recorded camera.mp4 flips deterministically both directions; live preview flips
- [x] T-8 — Observable recording-active + availability classifier ✅ impl+classifier+coordinator regression (6 tests) green
- [x] T-9a — Settings scene, tabs, discoverability, real controls ✅ build green; L5 PASS — SettingsLink + ⌘, both open window, opens Индикация first / persists last tab
- [x] T-9b — Read-only stub panes + during-recording gating ✅ build green; Dock-icon stub present; L5 PASS — mirror gated+caption during recording, stub rows = AXStaticText
- [x] T-10 — Docs + L5 verification + CLAUDE.md ✅ docs/architecture.md + CLAUDE.md done; L5 on MX Brio (signed build) PASS — all 8 e2e steps; see swarm-report/settings-window-e2e-scenario.md

> Quality profile DROPPED from v1 (owner) — deferred to a later task with hardware calibration.

**Status:** DONE. All tasks implemented + L5-verified on MX Brio (signed build). Build + 907 unit tests green; `/finalize` PASS; L5 PASS (mirror flip both ways, CFR cadence gap_count=0 over 8.7 min, timer live hide, gating, persistence-across-restart, AX static-text stubs).
**Next:** promote PR #274 → ready; OWNER REVIEW required (touches CLAUDE.md + UI → never auto-merge per project meta-merge policy).

## L5 results (2026-06-29, MX Brio, signed build TeamID 9PULX5QX5Y)
- Mirror flip: recorded camera.mp4 OFF=cabinet LEFT (natural), ON=cabinet RIGHT (flipped) — deterministic both ways on MX Brio (ffprobe metadata can't see it; pixel frame-extraction used). ⚠ Built-in FaceTime front-camera mirror-OFF (the case the finalize auto-adjust fix targets) UNTESTED — built-in cam is isSuspended (clamshell/external-display), not selectable in picker; needs lid-open. Fix is correct defensive code; path unreachable in this config.
- Cadence gate (verify-cfr): packet-rate 60/30 PASS, PTS-uniformity gap_count=0 BOTH streams BOTH runs (mirror-ON 526s) → NO frame-drop/cadence regression from mirror. (gap_count=0 proves no drops, not the zero-copy mechanism itself — powermetrics dropped, sudo blocked.) C/D fresh-content FAIL equally (static subject — script limitation, not regression).
- Timer toggle: live hides/shows menu-bar elapsed during recording, dot persists; survives restart.
- During-recording: mirror `.disabled` + «Недоступно во время записи»; timer stays enabled.
- AX: stub rows = AXStaticText (not buttons); live toggles = AXCheckBox.
- Persistence: @AppStorage last-tab + SettingsStore mirror state restored after full quit/relaunch.

## Learnings
- Wave 1 (T-1,T-2,T-4,T-8) implemented by swift-engineer; lint green; build+L2 verifying. Boxes checked once green.
- T-8: `isRecordingActive` also reset to false on start() failure paths (throw/cancel/denial-timeout), not just stop — else the gate sticks `true` when nothing records. Sites: decl 146, true@462, false@478(catch)/498(!activated cleanup)/778(stop). isStarting defer untouched.
- T-4: `cameraMirror` is a plain `let` (no inline default, so it stays in the memberwise init); default `false` lives on `makeMVPDefault` param. Forced updates to 4 `RecordingConfiguration(...)` call sites in ScreenStreamConfigurationBuilderTests + RecordingSessionTests (L0).
- T-2: `SettingsDefaults` is the single default source; `showMenuBarTimer` default **true**, `cameraMirror` **false**. `AppSettings` (T-3) must load via `SettingsPersisting.load*()`, not raw UserDefaults. Fake = `InMemorySettingsStore`.
- FOLLOW-UP (open): T-8 coordinator regression test (isRecordingActive stays true across start window; resets on denied/cancelled start) NOT yet written — assign to a later test wave (owns RecordingCoordinatorTests.swift).
- Xcode uses filesystem-synchronized groups — new files auto-compile, no pbxproj edits.
