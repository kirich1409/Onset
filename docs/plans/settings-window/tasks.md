# Tasks: Settings (⌘,) window — v1

> Plan: ./plan.md · No spec — acceptance below is the implementation-level contract.

## T-1 — Domain types in Configuration/
- after: none
- files: `Onset/Configuration/SettingApplyPolicy.swift`, `Onset/Configuration/SettingsKeys.swift`
- acceptance: GIVEN `SettingApplyPolicy` WHEN inspected THEN it has cases `.immediate/.nextRecordingStart/.requiresRelaunch`; `SettingsKeys` defines per-setting UserDefaults keys; types are `nonisolated` with explicit `==` for enums per project rule.
- check: `swift build` clean (no isolation/Equatable warnings); a small `SettingApplyPolicyTests` confirms equality witnesses usable off-main.

## T-2 — Per-key settings store
- after: T-1
- files: `Onset/Storage/SettingsStore.swift`, `OnsetTests/SettingsStoreTests.swift`
- acceptance: GIVEN a `UserDefaults`-backed `SettingsStore` storing `showMenuBarTimer` and `cameraMirror` as direct `Bool`s under their OWN keys (`set(_:forKey:)`; `object(forKey:)` presence-check → unset returns the per-setting default, `OutputFolderStore`-style, NOT JSON) WHEN one key is saved/absent THEN reload returns the saved value, and an absent/invalid key resolves to ITS default WITHOUT affecting the other; constructing with `.standard` under test traps (matches `BackendSelectionStore`).
- check: `SettingsStoreTests` — save→load per key, isolated corrupt-heal (corrupt one key, assert other intact) — green via `withScopedDefaults { InMemoryUserDefaults }`.

## T-3 — Shared @Observable AppSettings (in-memory source of truth)
- after: T-2
- files: `Onset/UI/AppSettings.swift`, `Onset/OnsetApp.swift`, `Onset/UI/Main/MainViewModel.swift`, `Onset/UI/MenuBar/MenuBarLabel*.swift`
- acceptance: GIVEN `AppSettings` owned as `@State` in `OnsetApp` (beside `coordinator`) WHEN a stored property is mutated THEN its `didSet` persists synchronously via `SettingsStore` AND triggers `@Observable` invalidation; values load from store at launch. THE SYSTEM SHALL be the single in-memory read source. THE SYSTEM SHALL inject it explicitly (not `@Environment`): add `let appSettings: AppSettings` to `MainViewModel.init` (update every VM creation site), and pass it as an `init` param to `MenuBarLabel` and `SettingsView` from `OnsetApp`.
- check: `swift build` clean (all `MainViewModel(...)` / `MenuBarLabel(...)` call sites updated); `AppSettingsTests` verifies load-at-init + synchronous `didSet` write-through to a fake store.

## T-4 — Add cameraMirror to RecordingConfiguration
- after: none
- files: `Onset/Configuration/RecordingConfiguration.swift`, `OnsetTests/RecordingConfigurationTests.swift`
- acceptance: GIVEN `makeMVPDefault(baseDirectory:cameraMirror: Bool = false)` (default `false` so `static let mvpDefault` :244 and other callers — `CameraFormatSelector`, `RecordingCoordinator.stop` — compile unchanged) WHEN built THEN `cameraMirror` is stored on config; the hand-rolled `==` (:308-341) treats two configs differing only in `cameraMirror` as non-equal.
- check: `RecordingConfigurationTests`: `==` inequality for `cameraMirror`; build clean incl. existing `mvpDefault` callers. (No bitrate/quality changes — quality profile is out of v1 scope.)

## T-5 — Read mirror at record seam + provide AppSettings to preview
- after: T-3, T-4
- files: `Onset/UI/Main/MainViewModel+Record.swift`, `Onset/UI/Main/MainView.swift`
- acceptance: GIVEN a recording starts WHEN `MainViewModel` builds config (+Record.swift:108) THEN it reads `cameraMirror` from `self.appSettings` and passes it to `makeMVPDefault`. THE SYSTEM SHALL pass `appSettings.cameraMirror` into `CameraPreviewRepresentable` (`MainView.swift` :334–348) so its `updateNSView` (T-7) reacts to toggles.
- check: build clean; `grep` confirms `CameraPreviewRepresentable` receives the mirror value (not a hardcoded constant).

## T-6 — Menu-bar timer toggle (consumer)
- after: T-3
- files: `Onset/UI/MenuBar/MenuBarLabelMapper.swift`, `Onset/UI/MenuBar/MenuBarLabel*.swift`, `OnsetTests/MenuBarLabelMapperTests.swift`
- acceptance: GIVEN `descriptor(phase:recordingState:elapsed:showTimer:)` WHEN `showTimer == false` THEN the descriptor's `elapsed` is `nil` (no time string) while the status dot is unchanged; `MenuBarLabel` passes `AppSettings.showMenuBarTimer`. THE SYSTEM SHALL update ALL existing `descriptor(...)` call sites (the ~9 in `MenuBarLabelMapperTests.swift` + production callers) to pass `showTimer:` — adding the param breaks them otherwise.
- check: `MenuBarLabelMapperTests` asserts `elapsed == nil` when `showTimer == false` during `.recording` (dot unchanged) AND all pre-existing cases pass `showTimer: true`; build clean (no unresolved call sites).

## T-7 — Camera mirror (recording path + live preview)
- after: T-4, T-5
- files: `Onset/Recording/Capture/CameraSource+SessionSetup.swift`, `Onset/UI/Main/CameraPreviewView.swift`, `Onset/UI/Main/MainView.swift`
- acceptance: GIVEN `config.cameraMirror == true` WHEN the recording VDO connection is configured AT SETUP in `attachOutputs` (after `addOutput` :300, before the first frame) THEN `isVideoMirrored` is set true — guarded by `isVideoMirroringSupported`, after `automaticallyAdjustsVideoMirroring = false`, wrapped in its OWN `session.beginConfiguration()/commitConfiguration()` (attachOutputs is NOT inside the existing one at :164/169); set ONLY at setup, never on a running session. THE SYSTEM SHALL make `CameraPreviewRepresentable.updateNSView` (`MainView.swift`) the SOLE writer of the preview-layer connection's `isVideoMirrored` (`CameraPreviewView` sets `automaticallyAdjustsVideoMirroring = false` when wiring the layer), reacting to `appSettings.cameraMirror` with no session reconfig; output unmirrored when `cameraMirror == false`.
- check: build clean; L5 (T-10): recorded `camera.mp4` horizontally flipped vs baseline; live preview flips on toggle with no flicker; mirror-ON vs OFF at default preserves zero-copy (IOSurface-backed / no per-frame CPU-energy regression), drops secondary.

## T-8 — Observable recording-active + availability classifier
- after: none
- files: `Onset/UI/RecordingCoordinator.swift`, `Onset/UI/Settings/ControlAvailability.swift`, `OnsetTests/ControlAvailabilityTests.swift`
- acceptance: GIVEN `RecordingCoordinator.isRecordingActive` is an OBSERVABLE STORED property set `true` at the ENTRY of `start()` (~:445, covering the startup window) and `false` at the COMPLETION of `stop()` (after terminal phase) — and the `isStarting` `defer` at :449 must NOT touch it (different variable) — WHEN the pure classifier maps `(.nextRecordingStart, active=true)` THEN it returns `.disabled`; `(.immediate, …)` returns `.enabled` always.
- check: `ControlAvailabilityTests` covers the policy × active matrix; build clean; mutating `isRecordingActive` triggers SwiftUI invalidation (stored, not computed over `@ObservationIgnored`); a coordinator test confirms it stays true across the start window (not reset by the :449 defer).

## T-9a — Settings scene, tabs, discoverability, real controls
- after: T-3, T-6, T-8
- files: `Onset/UI/Settings/SettingsView.swift`, `Onset/OnsetApp.swift`, `Onset/UI/MenuBar/MenuBarMenu.swift`
- acceptance: GIVEN `SettingsView(appSettings:coordinator:)` (explicit init — `appSettings` for toggle bindings, `coordinator` for `isRecordingActive` gating) hosted in the `Settings` scene WHEN opened via ⌘, OR the `SettingsLink` («Настройки…») in `MenuBarExtra` THEN a `TabView` shows tabs Общие/Индикация/Видео/Камера/Аудио (each an SF Symbol), opens on Индикация and remembers the last tab via `@AppStorage` keyed on a `SettingsTab` enum `rawValue: String` (default `.indication`); real controls — timer `Toggle` (Индикация), mirror `Toggle` (Камера) — bind to `appSettings`.
- check: build clean; L5: ⌘, AND SettingsLink both open the window (window-less too); toggles mutate persisted state; reopening restores last tab, first-ever open is Индикация; only standard SwiftUI controls used (review).

## T-9b — Read-only stub panes + during-recording gating
- after: T-9a
- files: `Onset/UI/Settings/*Pane.swift`
- acceptance: GIVEN the stub rows WHEN rendered THEN they are read-only `LabeledContent` (label + static value, no chevron, NOT a Picker): codec HEVC, container MP4, resolution «Исходное», fps «авто/исходный», camera 1080p, audio off/off, language «Русский». THE SYSTEM SHALL render the mirror control `.disabled` via `ControlAvailability` during recording WITH a visible «Недоступно во время записи» caption + `accessibilityHint`, and carry the «Превью обновляется сразу, в запись — со следующего старта» caption otherwise.
- check: L3/L5 manual: stubs are non-interactive rows (not greyed pickers); stub-only tabs (Общие/Видео/Аудио) read as informational, not broken; mirror greyed + explained during an active recording; VoiceOver announces read-only rows as static text (not button) with correct focus order; no custom control types (review).

## T-10 — Docs + L5 verification + CLAUDE.md
- after: T-9b
- files: `docs/architecture.md`, `CLAUDE.md`
- acceptance: THE SYSTEM SHALL document the Settings scene + new types in architecture.md; add to CLAUDE.md (via revise-claude-md, ≤200 lines) BOTH the "UI from standard SwiftUI/AppKit components" rule AND a reword of "sole @Observable owner" → "sole session-lifecycle owner". L5 on MX Brio (quiet machine, signed build): mirror flips `camera.mp4` + live preview; mirror-ON vs OFF at default preserves zero-copy (IOSurface / no CPU-energy regression) with no new drops (`verify-cfr`); menu-bar timer hides/shows live; ⌘, and SettingsLink both open the window.
- check: docs updated in this PR; L5 evidence (flip screenshot + mirror-ON/OFF zero-copy/energy comparison + verify-cfr result) recorded in PR body. NOTE: PR also touches CLAUDE.md + is a UI change → not auto-mergeable, owner review required.
