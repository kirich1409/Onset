---
type: plan
slug: settings-window
date: 2026-06-28
status: approved
spec: none
risk_areas: [perf-critical]
review_verdict: pass
review_blockers: []
---

# Plan: Settings (⌘,) window — v1

## Context & Decision

Onset needs a Settings window so app-wide and recording defaults can be configured and **persist
across launches** — today they are compiled constants. The change is decided and scoped with the
owner (design notes: `swarm-report/settings-window-design.md`). A Claude Design mockup
(`screens-prefs.jsx`) is the **visual reference only**, not a 1:1 spec — real sections derive from
app capability. This plan is the HOW: a native SwiftUI `Settings` scene, a persisted settings store,
**two real controls (menu-bar timer toggle, camera mirror)**, forward-looking read-only display rows
for currently-fixed parameters, and a setting apply-policy model.

> **Scope note:** a quality-profile selector was considered and **dropped from v1** by the owner after
> review — it is conflict-heavy (bitrate multiplier compounds into peak ×2.8, needs hardware
> calibration, non-standard enum→value selection). Deferred to a later task when calibration is in
> scope. The Видео tab is read-only stubs in v1. This removes the perf-critical bitrate risk entirely;
> the only remaining capture-pipeline concern is the camera-mirror zero-copy path (below).

## Technical Approach

**Scene & discoverability.** Add a SwiftUI `Settings { … }` scene (free ⌘,) to `Onset/OnsetApp.swift`
`body`, additive to the two `Window` scenes + `MenuBarExtra`. Because Onset is a menu-bar-centric app,
⌘, only fires with a focused window — so the `MenuBarExtra` menu (`MenuBarMenu`) **must** gain a
`SettingsLink { Text("Настройки…") }` entry so the window is reachable with no other window open.
Toolbar-tabs (Apple HIG via `TabView` + `.tabItem` with an SF Symbol per tab). The window opens on a
content-bearing tab (**Индикация**) and remembers the last-selected tab. UI is built **only from
standard SwiftUI/AppKit components** (`Settings`, `Form`, `Toggle`, `LabeledContent`, `TabView`) — no
custom controls to chase the mockup pixel-for-pixel.

**Persistence (first-class).** Follow the existing store pattern: persisting protocol + `UserDefaults`
impl + `InMemory` double — for two `Bool`s use direct `set(_:forKey:)`/`object(forKey:)` (presence-check
to distinguish unset → default; `OutputFolderStore` precedent stores values directly, not JSON),
`.standard` guard under test — precedent
`Onset/Storage/OutputFolderStore.swift`, `DeviceSelectionStore.swift`, `BackendSelectionStore.swift`.
Key constants in `Onset/Configuration/` (precedent `OutputFolderKeys.swift`). Store the two settings
**per-key** (`showMenuBarTimer: Bool`, `cameraMirror: Bool`) so corruption of one key self-heals to its
own default without resetting the other.

**Shared observable model (the one non-obvious risk).** SwiftUI observation propagates through a
shared `@Observable` reference, not through `UserDefaults` writes. Both settings are consumed by
**live** surfaces (timer → `MenuBarLabel`; mirror → live camera preview), so they need one
`@Observable` settings model owned at the composition root (`OnsetApp` `@State`, beside `coordinator`
at `OnsetApp.swift:49/57`), injected into the Settings scene, `MenuBarLabel`, and the preview surface.
It loads from the store at launch and **writes through synchronously via `didSet`** on each stored
property (works under `@Observable`; the mutation both persists to `SettingsStore` and triggers
observation). **Single source of read:** consumers read the value from `AppSettings`, not the store
directly — `AppSettings` is the in-memory source of truth (avoids two read paths for `cameraMirror`).
**Injection (explicit, not `@Environment`):** `MainViewModel` gains `let appSettings: AppSettings` in
its `init` (every VM creation site updated — see `MainViewModel.swift`); `MenuBarLabel` and
`SettingsView` receive it as an `init` parameter from `OnsetApp` where the single instance is owned.
The `Settings` scene constructs `SettingsView(appSettings:coordinator:)` — `coordinator` is needed for
`isRecordingActive` gating.

**Apply-policy model.** A pure `SettingApplyPolicy` taxonomy in `Onset/Configuration/`:
`.immediate` (applies at once, editable during recording — timer), `.nextRecordingStart` (editable,
recorded output affected only next session; **locked during recording** — mirror),
`.requiresRelaunch` (saved, needs restart; **unused in v1**, defined for forward-compat). A pure
classifier `(policy, isRecordingActive) -> ControlAvailability` lives in `UI/Settings/` mirroring
`MenuBarLabelMapper`; the view renders `.disabled(…)` **and** an explanatory caption
(«Недоступно во время записи») + `accessibilityHint` from its result — a greyed control always says
why.

**`isRecordingActive` must be observable.** `isStarting`/`isStopping` are `@ObservationIgnored` and
`phase` only becomes `.recording` at the end of `start()` (`RecordingCoordinator.swift:289-296,552`).
A *computed* `isRecordingActive` over those flags would NOT trigger SwiftUI invalidation during the
(possibly seconds-long) start/stop windows. Expose `isRecordingActive` as an **observable stored
property** with exactly two write points: **set `true` at the entry of `start()` (~:445)** — covering
the whole startup window — and **set `false` at the completion of `stop()`** (after the terminal phase
is set). The `isStarting` `defer` at :449 resets `isStarting`, a *different* variable, and must **not**
touch `isRecordingActive`. This two-point protocol (not "one site") keeps the gate true across the
seconds-long start window and the entire recording, false only once fully stopped; fed into the
classifier so controls grey out during transitions.

**Camera mirror.** Add `cameraMirror: Bool` to `RecordingConfiguration` (capture-side pref,
consistent with `minCameraFps`), with a **default `= false`** on the stored field and the
`makeMVPDefault` parameter so `static let mvpDefault` (:244) and other callers
(`CameraFormatSelector`, `RecordingCoordinator.stop`) compile unchanged. Both the preview `CameraSource` (`MainViewModel.swift:593`) and the
recording-path `CameraSource` (`RecordingComponentFactories.swift:284-288`) are built from `config`.
- **Recording path:** set `AVCaptureConnection.isVideoMirrored` on the VDO connection in
  `CameraSource+SessionSetup.swift` after `session.addOutput(videoOutput)` (~L300) — guard
  `isVideoMirroringSupported`, set `automaticallyAdjustsVideoMirroring = false`, then `isVideoMirrored`,
  inside `begin/commitConfiguration`. T1-verified (macOS SDK 26.5 header): not deprecated, physically
  flips VDO buffers → affects recording. **Invariant (regression guard):** set **only at session setup
  before the first frame**, never on a running session (one-shot lifecycle; mirror read fresh at record
  start). **Open risk:** a physical buffer flip on the camera hot-path may break the IOSurface
  zero-copy path into `VTCompressionSession` (spec «Zero-copy путь»). A break would NOT necessarily
  drop frames (a per-frame memcpy ~0.1–0.5 ms fits the 33 ms budget) — it surfaces as a CPU/energy/
  thermal regression, a top priority for long sessions. So L5 verifies zero-copy **directly**
  (CVPixelBuffer stays IOSurface-backed and/or per-frame encode CPU/energy delta via
  `powermetrics`/Instruments), with "no new drops" as a secondary signal — not the proof.
- **Live preview path:** the preview is a *separate* `AVCaptureSession` rendered via
  `AVCaptureVideoPreviewLayer` (`CameraPreviewView.swift`); its `connection.isVideoMirrored` is a cheap
  **layer transform**, not a buffer flip. Drive it **reactively from `AppSettings.cameraMirror`
  observation**: `CameraPreviewRepresentable` (in `MainView.swift`, lines 334–348) takes
  `cameraMirror` and applies it in its currently-no-op `updateNSView` —
  `nsView.previewLayer?.connection?.isVideoMirrored = cameraMirror` (with
  `automaticallyAdjustsVideoMirroring = false` set once when the preview layer is wired in
  `CameraPreviewView`). NO session `begin/commitConfiguration`, no `CameraSource` rebuild, so the toggle
  gives live WYSIWYG with no flicker/stall. `CameraPreviewRepresentable.updateNSView` is the **sole
  writer** of the preview connection's mirror state. Because the
  preview reflects the change instantly while the *recording* honors it from the next start, the
  mirror control's caption reads «Превью обновляется сразу, в запись — со следующего старта» (not the
  generic «применится к следующей записи»).

**Display/stub controls.** Currently-fixed params render as **read-only `LabeledContent` rows** (label +
static value, no chevron, non-interactive) — NOT single-option `Picker`s (which read as broken), no
"скоро". Items: codec HEVC, container MP4, resolution «Исходное», frame rate «авто/исходный» (NOT a
fixed number — the camera delivers variable/lower fps; a single number would imply a false guarantee);
camera resolution 1080p; audio noise-suppression off, system-audio off; language «Русский».
Interactive controls appear later only when a real choice exists.

**Categories (owner-driven):** Общие (language read-only row; optional version/About) · Индикация (timer
toggle, Dock-icon read-only stub) · Видео (read-only format rows — codec/container/resolution/fps) ·
Камера (mirror real + resolution read-only row) · Аудио (read-only rows). Только Индикация и Камера
несут реальные контролы в v1; остальные — честные read-only-дома для будущих настроек. Default-open tab
is Индикация; an L3 pass confirms the stub-only tabs read as "informational", not "broken".

## Affected Modules & Files

| Path | Change | Note |
|---|---|---|
| `Onset/Configuration/SettingsKeys.swift` | New | per-key UserDefaults constants (precedent `OutputFolderKeys`). |
| `Onset/Configuration/SettingApplyPolicy.swift` | New | apply-policy taxonomy; pure. |
| `Onset/Configuration/RecordingConfiguration.swift` | Modified | add `cameraMirror` field; extend `makeMVPDefault(baseDirectory:cameraMirror:)`; **update hand-rolled `==` (:308-341)**. |
| `Onset/Storage/SettingsStore.swift` | New | per-key persisting protocol + `UserDefaults` impl + `InMemory`. |
| `Onset/UI/AppSettings.swift` | New | shared `@Observable` settings model (in-memory source of truth). |
| `Onset/OnsetApp.swift` | Modified | add `Settings` scene; own + inject `AppSettings`. |
| `Onset/UI/MenuBar/MenuBarMenu.swift` | Modified | add `SettingsLink` («Настройки…») entry. |
| `Onset/UI/Settings/*` | New | `SettingsView` + tab panes (native components); pure `ControlAvailability` classifier. |
| `Onset/UI/MenuBar/MenuBarLabelMapper.swift` | Modified | add `showTimer:` param → omit elapsed when false. |
| `Onset/UI/MenuBar/MenuBarLabel*.swift` | Modified | read shared `AppSettings.showMenuBarTimer`. |
| `Onset/UI/RecordingCoordinator.swift` | Modified | expose **observable stored** `isRecordingActive`, single update path. |
| `Onset/UI/Main/MainViewModel.swift` | Modified | add `let appSettings: AppSettings` to `init` (+ update all VM creation sites). |
| `Onset/UI/Main/MainViewModel+Record.swift` | Modified | read `cameraMirror` from `self.appSettings`; thread into `makeMVPDefault` (:108). |
| `Onset/UI/Main/MainView.swift` | Modified | `CameraPreviewRepresentable` (lines 334–348): pass `appSettings.cameraMirror` and set it in `updateNSView` (the current no-op) on `nsView.previewLayer?.connection?.isVideoMirrored`. |
| `Onset/Recording/Capture/CameraSource+SessionSetup.swift` | Modified | set `isVideoMirrored` on VDO connection at setup; `attachOutputs` is NOT inside the existing `begin/commitConfiguration` (that wraps `setInputAndFormat` :164/169) — wrap the mirror set in its OWN `session.beginConfiguration()/commitConfiguration()` after `addOutput` (:300). |
| `Onset/UI/Main/CameraPreviewView.swift` | Modified | the `NSView` exposing `previewLayer`; `automaticallyAdjustsVideoMirroring = false` on the preview connection so the reactive set takes effect. |
| `OnsetTests/*` | New | L2 tests: per-key store, mapper, classifier, config equality. |
| `docs/architecture.md` | Modified | Settings scene + new types. |
| `CLAUDE.md` | Modified | (a) "UI from standard SwiftUI/AppKit components" rule; (b) reword "sole @Observable owner" → "sole session-lifecycle owner" (via revise-claude-md; ≤200 lines). |

## Decisions Made

| Decision | Rationale | Alternatives rejected |
|---|---|---|
| Drop quality profile from v1 | Conflict-heavy (peak ×2.8 compounding, needs hardware calibration, non-standard enum selection); removes perf-critical risk | Ship it now (review surfaced a critical + several majors) |
| One shared `@Observable` `AppSettings`; consumers read from it (not the store) | SwiftUI invalidation needs a shared ref; single in-memory source avoids two read paths | Per-VM private store (won't propagate); reading store at record seam + AppSettings at preview (two sources) |
| `cameraMirror` `.nextRecordingStart`; preview live, recording from next start | One-shot pipeline can't reconfigure mid-record; preview is a cheap layer transform | Mirroring a running recording session (mid-file flip) |
| `isRecordingActive` = observable **stored**, single update path | `@ObservationIgnored` flags don't invalidate; 6-site duplication risks drift | Computed getter over `@ObservationIgnored`; hand-written at 6 sites |
| Stubs = read-only `LabeledContent`, not single-option `Picker` | A one-option picker reads as a broken control (HIG) | Disabled picker / "скоро" badge |
| `CameraPreviewView` sole writer of preview mirror; auto-adjust off on both connections | Avoids double-application/race; some cameras auto-mirror preview by default | Writing mirror from both +Preview and CameraPreviewView |
| `SettingsLink` in `MenuBarExtra` | ⌘, only works with a focused window; menu-bar app needs an explicit entry | Rely on ⌘, alone (unreachable with no window) |
| `SettingApplyPolicy`/`SettingsKeys` in `Configuration/` | Preserves inward dependency direction | `UI/` placement inverts deps |
| Settings never flow through/into `RecordingCoordinator` | Coordinator is sole **session-lifecycle** owner; settings are one-way reads at seams | Coordinator owning settings |

## Risks & Mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| `isVideoMirrored` physical flip may break IOSurface zero-copy → CPU/energy/thermal regression (not drops) | major | L5 verifies zero-copy **directly** (IOSurface-backed / per-frame CPU-energy delta), mirror-ON vs OFF at default; drops secondary (T-7/T-10) |
| Hand-rolled `RecordingConfiguration ==` (:308-341) silently omits `cameraMirror` → broken change-detection | major | T-4 updates `==` in same edit; L2 test asserts inequality for the new field |
| `.immediate` timer / live preview mirror fail to re-render (wrong observation model) | major | Shared `@Observable` `AppSettings` at composition root; preview mirror bound to observation, single writer (T-3/T-5/T-7) |
| `isRecordingActive` not reactive in start/stop windows | major | Observable **stored** property, single update path (T-8) |
| Stubs/stub-only tabs read as broken/unfinished | major | Read-only `LabeledContent` rows; default-open Индикация; L3 confirms "informational" (T-9) |
| Camera-mirror L5 needs signed build + MX Brio, on a **quiet** machine | major | Camera/preview entitlements provision under Personal Team (memory: camera L5 feasible); mirror/energy measured with no parallel UI/screenshot load (project perf-verify-quiet-machine rule) |
| Accessibility gap on non-standard states (locked/read-only rows) | major | `accessibilityHint` on locked controls; read-only rows announce as **static text** (not button), correct focus order (T-9) |

## Verification & Sources

How the finished change is verified (the `/acceptance` contract):

| Source of truth | Type | Status | Sufficient for verification? |
|---|---|---|---|
| `swarm-report/settings-window-design.md` | requirements / design | present | yes — defines v1 controls (timer, mirror), categories, apply-policies, read-only-stub principle |
| `docs/specs/2026-06-02-onset-recording-mvp.md` (AC-4 codec/container) | spec | present | yes — constrains stubs (HEVC/MP4 fixed) |
| Behavioral baseline: current recording, mirror-OFF | before-state baseline | to-capture-before-impl (L5: ffprobe + `verify-cfr` of one default camera recording on a quiet machine) | yes — proves mirror-ON differs (flipped) without zero-copy/energy regression, and existing recording behavior is unchanged |

**Testing strategy (pyramid levels):** L0 build always + L1 lint (warnings-as-errors,
SwiftFormat/SwiftLint) + L2 unit (`RecordingConfiguration ==` for `cameraMirror`; mapper `showTimer`;
per-key settings store with `InMemory`; `ControlAvailability` classifier matrix) + L5 manual on MX Brio
(signed build, **quiet machine**): (a) mirror flips `camera.mp4` and the live preview; isolated
mirror-ON vs OFF at default shows zero-copy preserved (IOSurface-backed / no per-frame CPU-energy
regression), drops secondary; (b) menu-bar timer hides/shows live; (c) ⌘, and `SettingsLink` both open
the window; (d) recording-affecting (mirror) control greys out with explanation during an active
recording. L5 is **mandatory** — the change touches the capture pipeline (infra-layer) and recorded
output; build+unit alone do not close it. L3 UI (Settings walkthrough, stub-only tabs, locked states)
via manual-tester.

## Out of Scope

- **Quality profile / bitrate selection** — dropped from v1 (see Scope note); future task with hardware calibration.
- Launch at login (autostart), check-for-updates, language selection — future; home = «Общие» category.
- Default devices inside Settings — stay in main window for v1.
- Mockup vs reality discrepancies — NOT implemented, documented: container MOV (code/spec = MP4, AC-4),
  60 fps (camera delivers less; fps stub shown as «авто/исходный»).
- Format selection (codec/container/fps as real selectors), Dock-icon-during-recording behavior,
  noise suppression, system audio — read-only rows only in v1.
- Main pre-record window redesign (collapsible sources, `screens-settings.jsx`).

## Open Questions

- [non-blocking] Whether «Общие» also surfaces app version/About in v1 (would make the tab non-trivial).
- [non-blocking] This PR touches `CLAUDE.md` (+ is a UI change needing L5): per project meta-merge
  policy it is **not auto-mergeable** — owner review required. Optionally split the CLAUDE.md reword
  into a separate meta-PR to keep this one mergeable on its own gates.
