# Progress: Settings (⌘,) window — v1

> Plan: ./plan.md · Tasks: ./tasks.md

## Status
- [x] T-1 — Domain types in Configuration/ (SettingApplyPolicy, SettingsKeys) ✅ build+L2 green
- [x] T-2 — Per-key settings store (timer, mirror) ✅ build+L2 green
- [x] T-3 — Shared @Observable AppSettings (in-memory source of truth) ✅ build+L2 green (901 tests)
- [x] T-4 — Add cameraMirror to RecordingConfiguration ✅ build+L2 green
- [x] T-5 — Read mirror at record seam + provide AppSettings to preview ✅ build green
- [x] T-6 — Menu-bar timer toggle (consumer) ✅ build+L2 green (timer-toggle suite)
- [~] T-7 — Camera mirror (recording path + live preview) ✅ impl+build green; ⚠ L5 (flip + zero-copy on MX Brio) pending → T-10
- [x] T-8 — Observable recording-active + availability classifier ✅ impl+classifier+coordinator regression (6 tests) green
- [x] T-9a — Settings scene, tabs, discoverability, real controls ✅ build green (L3/L5 window-open in T-10)
- [~] T-9b — Read-only stub panes + during-recording gating ✅ build green; ⚠ Dock-icon stub omitted (in plan §Categories, not in T-9b list — add in T-10 polish or accept); L3/L5 a11y+gating pending → T-10
- [~] T-10 — Docs + L5 verification + CLAUDE.md ✅ docs/architecture.md + CLAUDE.md done; ⚠ L5 on MX Brio (mirror flip + zero-copy/energy, ⌘,/SettingsLink, gating, VoiceOver) pending — needs reference hardware + signed build

> Quality profile DROPPED from v1 (owner) — deferred to a later task with hardware calibration.

## Learnings
- Wave 1 (T-1,T-2,T-4,T-8) implemented by swift-engineer; lint green; build+L2 verifying. Boxes checked once green.
- T-8: `isRecordingActive` also reset to false on start() failure paths (throw/cancel/denial-timeout), not just stop — else the gate sticks `true` when nothing records. Sites: decl 146, true@462, false@478(catch)/498(!activated cleanup)/778(stop). isStarting defer untouched.
- T-4: `cameraMirror` is a plain `let` (no inline default, so it stays in the memberwise init); default `false` lives on `makeMVPDefault` param. Forced updates to 4 `RecordingConfiguration(...)` call sites in ScreenStreamConfigurationBuilderTests + RecordingSessionTests (L0).
- T-2: `SettingsDefaults` is the single default source; `showMenuBarTimer` default **true**, `cameraMirror` **false**. `AppSettings` (T-3) must load via `SettingsPersisting.load*()`, not raw UserDefaults. Fake = `InMemorySettingsStore`.
- FOLLOW-UP (open): T-8 coordinator regression test (isRecordingActive stays true across start window; resets on denied/cancelled start) NOT yet written — assign to a later test wave (owns RecordingCoordinatorTests.swift).
- Xcode uses filesystem-synchronized groups — new files auto-compile, no pbxproj edits.
