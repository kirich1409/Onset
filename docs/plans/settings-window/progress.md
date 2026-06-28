# Progress: Settings (⌘,) window — v1

> Plan: ./plan.md · Tasks: ./tasks.md

## Status
- [x] T-1 — Domain types in Configuration/ (SettingApplyPolicy, SettingsKeys) ✅ build+L2 green
- [x] T-2 — Per-key settings store (timer, mirror) ✅ build+L2 green
- [ ] T-3 — Shared @Observable AppSettings (in-memory source of truth)
- [x] T-4 — Add cameraMirror to RecordingConfiguration ✅ build+L2 green
- [ ] T-5 — Read mirror at record seam + provide AppSettings to preview
- [ ] T-6 — Menu-bar timer toggle (consumer)
- [ ] T-7 — Camera mirror (recording path + live preview)
- [~] T-8 — Observable recording-active + availability classifier ✅ impl+classifier L2 green; ⚠ coordinator regression test still pending (follow-up)
- [ ] T-9a — Settings scene, tabs, discoverability, real controls
- [ ] T-9b — Read-only stub panes + during-recording gating
- [ ] T-10 — Docs + L5 verification + CLAUDE.md

> Quality profile DROPPED from v1 (owner) — deferred to a later task with hardware calibration.

## Learnings
- Wave 1 (T-1,T-2,T-4,T-8) implemented by swift-engineer; lint green; build+L2 verifying. Boxes checked once green.
- T-8: `isRecordingActive` also reset to false on start() failure paths (throw/cancel/denial-timeout), not just stop — else the gate sticks `true` when nothing records. Sites: decl 146, true@462, false@478(catch)/498(!activated cleanup)/778(stop). isStarting defer untouched.
- T-4: `cameraMirror` is a plain `let` (no inline default, so it stays in the memberwise init); default `false` lives on `makeMVPDefault` param. Forced updates to 4 `RecordingConfiguration(...)` call sites in ScreenStreamConfigurationBuilderTests + RecordingSessionTests (L0).
- T-2: `SettingsDefaults` is the single default source; `showMenuBarTimer` default **true**, `cameraMirror` **false**. `AppSettings` (T-3) must load via `SettingsPersisting.load*()`, not raw UserDefaults. Fake = `InMemorySettingsStore`.
- FOLLOW-UP (open): T-8 coordinator regression test (isRecordingActive stays true across start window; resets on denied/cancelled start) NOT yet written — assign to a later test wave (owns RecordingCoordinatorTests.swift).
- Xcode uses filesystem-synchronized groups — new files auto-compile, no pbxproj edits.
