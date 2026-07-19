---
type: spec
slug: coupled-recording-quality
date: 2026-06-29
status: draft
platform: macOS 26+ (Apple Silicon)
surfaces: [main-window, menu-bar]
risk_areas: [encoder-budget-calibration, capability-resolution, ui-coupling, persistence, accessibility]
non_functional: [stability, performance, accessibility]
acceptance_criteria_ids: [AC-Q1, AC-Q2, AC-Q3, AC-Q4, AC-Q5, AC-Q6, AC-Q7, AC-Q8, AC-Q9, AC-Q10, AC-Q11, AC-Q12]
amends: docs/specs/2026-06-02-onset-recording-mvp.md (AC-5 silent downscale + the Phase-2 deferral of explicit camera format choice)
design: TBD (Claude Design service — hand to owner; must precede Phase B, see AC-Q3/AC-Q5)
---

# Coupled recording-quality selection (device-budget-aware)

## Context and Motivation

Onset records two concurrent HEVC streams (screen + camera). The hardware video
encoder on Apple Silicon is a **shared throughput budget**, not independent
per-stream engines — empirically two concurrent 4K HEVC `VTCompressionSession`s
scale ~1.04× (not 2×): they contend on one budget
(`swarm-report/dual-encoder-contention-spike-state.md`). Combined encode load that
exceeds the device's real budget drops frames — this caused a camera stutter bug
(4K camera upscale inflated the lane), short-term fixed by capping the camera to
1080p (#281).

Today (MVP **AC-5**) the app **silently** downscales the screen at record start to
fit a single hardcoded 995M px/s budget. Two problems: (1) the downscale is
invisible — the user gets a lower-quality recording with no explanation; (2) the
995M cap is a single uncalibrated constant, **retracted** as a "flood-artifact"
upper bound (not a measured realtime budget), and is not hardware-tier-aware.

This feature replaces the silent downscale with **explicit, transparent quality
selection**: on the main window, next to the camera and display pickers, the user
chooses a recording quality for the screen and for the camera. The two are
**coupled** by the device's computed encode budget — combinations that would
exceed the budget are shown unavailable, so the user always allocates a finite,
honest hardware budget themselves rather than discovering a silent downgrade after
the fact.

**Honest framing (do not silently "fix"):** on every current Apple Silicon tier
the camera is the *cheap* stream (≤1080p ≈ ≤124M px/s) and the screen is the load
(up to 4K60 ≈ 498M px/s). One screen step (4K30→4K60 = +249M) costs more than the
camera's entire range. So the camera picker rarely constrains the screen today;
bidirectional coupling becomes materially useful only once the camera stack can
exceed 1080p (parked Stage A). The owner has chosen to ship **both** coupled
pickers now (JOINT-FIT); this spec documents the camera lever is near-degenerate
on current hardware so it is not mistaken for a defect.

**Stability is priority #1 (project bar).** This feature *removes* the silent
downscale and does *not* introduce a runtime drop-fallback (the `DropMonitor`
degradation latch redefinition is separate work — it currently "watches the wrong
failure mode"). Therefore the **preflight budget is the only guard** against a
silently bad recording. Two consequences run through the ACs below: (a) the budget
must be *calibrated against worst-case content*, not merely internally consistent
(AC-Q4); (b) uncalibrated hardware tiers must fail *safe-low*, never inherit a
stronger tier's budget (AC-Q9).

## Acceptance Criteria

- **AC-Q1 (screen taxonomy).** The screen quality picker offers exactly the
  selected display's native resolution and below, each at `{min(nativeRefresh, 60), 30}`
  fps; no level above the display's native resolution or refresh is offered.
  Labels are concrete resolution + fps (e.g. "4K · 60 fps", "1080p · 30 fps").
- **AC-Q2 (camera taxonomy + delivered-fps seam).** The camera quality picker
  offers levels the selected camera device supports (16:9, ≤ camera MVP cap),
  with each level's fps grounded in **delivered** fps for that device, supplied by
  an injected per-device delivered-fps source (sampled from the live preview /
  prior measurement) — the pure taxonomy type receives delivered-fps as an explicit
  input, never reads it itself. For a device with no measured delivered-fps yet, a
  level is shown from *announced* fps marked provisional (not presented as
  delivered) or withheld — never silently presented as delivered. For a camera with
  no 16:9 format, a single auto level (largest supported) is shown, no choice. When
  the camera is off, the picker is hidden/disabled.
- **AC-Q3 (budget-fit invariant — math + actionable reason).** For every (screen,
  camera) pair the UI lets the user *select* (non-greyed),
  `screenPxPerSec + cameraPxPerSec ≤ deviceBudget(chipTier)`. Pairs that exceed it
  are shown disabled with an **actionable** reason naming what to lower/disable to
  unlock the level (e.g. "снизьте камеру или выключите её, чтобы выбрать 4K · 60"),
  not a bare "unavailable". The minimal actionable reason ships in Phase B; rich
  hover-tooltips/bitrate hints are Phase C. Falsifiable by enumeration against
  `EngineBudgetCap.fits()`.
- **AC-Q4 (budget validation — empirical, L5, worst-case; the gate that matters).**
  For each *calibrated* tier, recording the **maximum combo the UI offers** on
  reference hardware, driving **worst-case content** (fast motion + high spatial
  detail + scene cuts on the **camera** lane — the per-pixel-expensive stream — plus
  a busy screen, at the high end of the bitrate table), produces **0 encoder-backpressure
  drops** (per-stream `DropCounters`, #282) over **≥2 runs of ≥10 min each**, verified
  by `verify-cfr` + PTS deltas. Generic "motion" is insufficient — the original bug
  was episodic and content-dependent (gaps clustered 50–90s). A tier's budget is set
  by an **upward ceiling search** (raise combined px/s until the first backpressure
  drop appears; set the cap a margin *below* the last 0-drop point), NOT by assuming
  the seed floor is the ceiling. Distinguish in the per-tier table: a **validated
  floor** (proven 0-drop, conservative) vs a **calibrated ceiling** (sweep-derived).
- **AC-Q5 (no silent level change — ever).** The selected screen or camera level
  changes from what the user chose **only with a visible notice** — never silently —
  in every case: camera turned on, display/camera changed, **and launch-time
  restore-clamp** (AC-Q8). At the type level: the resolver consumes the user-selected
  levels as the **target** dims/fps and its budget-solver is demoted to a safety-net
  that is a **no-op on any combo the UI showed as selectable** (UI enumeration and the
  record-path solver use the *same* `EngineBudgetCap.fits()`, so a non-grey combo is
  provably never downscaled on the record path). Notice channel: main window open →
  inline notice at the picker; main window closed → menu-bar badge or deferred notice
  shown on next window open (Onset is MenuBarExtra + Window — external display/camera
  changes fire with the window closed).
- **AC-Q6 (camera off → full budget, no auto-change).** With the camera off the
  screen picker is computed against the full device budget (more options open), but
  the **current screen selection does not auto-change** (no silent upgrade) — only the
  available options expand. Turning the camera on restores the last chosen camera
  level if it still fits; if the combined load no longer fits, the screen level is
  reduced only per AC-Q5 (visible notice).
- **AC-Q7 (floor never blocks recordability).** At least one (screen, camera) combo
  is always selectable; the budget gates *quality*, never *recordability*. The only
  hard preflight block remains "no hardware encoder" (existing MVP AC-6). Falsify:
  any device/budget state where the record button is disabled for a budget reason.
- **AC-Q8 (persistence of intent).** The user's chosen levels persist across launches
  as **intent, serialized as concrete `(width, height, fps)` per stream** (not a
  taxonomy index). On restore the intent is re-validated against current device +
  budget; the clamped value is used for the session and any downward clamp surfaces a
  notice per AC-Q5; the original intent is retained so a subsequently capable
  device/display restores the higher choice. Falsify: attach-then-detach a weaker
  display strands the user below their saved choice, OR a restore-clamp happens
  silently.
- **AC-Q9 (uncalibrated/weak tier → fail safe-low, never inherit).** A chip tier
  with no L5 calibration — including known-but-unmeasured single-media-engine tiers
  (e.g. base M1/M2), not only "unknown future chip" — is assigned a deliberately low
  budget admitting roughly **one sustainable stream** (scaled conservatively, e.g.
  by the tier's known media-engine count where available), and **never** inherits a
  stronger tier's budget nor the retracted 995M. Phase B may ship on a tier only once
  that tier has an AC-Q4 calibration; uncalibrated tiers get the safe-low budget until
  then. Falsify: a base-M1 (or any single-engine tier) resolves to the M3 Max budget.
- **AC-Q10 (accessibility).** A greyed level announces its actionable reason to
  VoiceOver (not just "dimmed"); "unavailable" is conveyed by more than color/dimming
  alone; the AC-Q5 forced-change notice is reachable by assistive technology.
- **AC-Q11 (locked during recording).** While a recording session is active, the
  quality pickers are disabled (consistent with the MVP's read-only source pickers
  during recording); the locked state is communicated (no silent ignore of taps).
- **AC-Q12 (event-driven recompute).** The selectable-levels enumeration is a pure
  function recomputed only on discrete user/device events (level pick, camera/display
  change, camera on/off) — never on the frame-delivery path.

## Prerequisites

- **PR #282 (per-stream drop telemetry)** — **merged** (`main` commit `b6c110a`,
  "Split drop telemetry by stream and separate real loss from coalescing"). AC-Q4
  reads per-stream `encoderBackpressureDrops` to validate the budget empirically.
- **Empirical per-tier calibration (AC-Q4)** — at minimum the reference tier (M3 Max)
  before Phase B ships on it; other tiers ship Phase A's safe-low budget (AC-Q9) and
  are calibrated as tracked follow-up, one L5 sweep per tier. A single-engine tier
  (e.g. M1) L5 is the highest-value early calibration (largest installed base, lowest
  budget).
- Reference hardware for L5: Logitech MX Brio + a 4K display (so the 4K60-screen +
  camera pairing — the actual max combo — is exercised, not an unconfirmed-resolution
  display).

## Affected Modules and Files

| Path | Change | Note |
|---|---|---|
| `Onset/Configuration/ChipTier.swift` (new) | add | pure `nonisolated enum ChipTier` with explicit `nonisolated static func ==`/`hash` if needed; media-engine count per tier where known |
| `Onset/Configuration/ChipTierDetector.swift` (new) | add | `nonisolated` (mirror `CapabilityProbe`); `sysctlbyname("hw.model")`/`machdep.cpu.brand_string` (needs `unsafe` under strict memory safety) → `ChipTier`; logs raw model string; never crashes on unknown |
| `Onset/Configuration/RecordingPolicyTypes.swift` | edit | add `nonisolated static func budgetCap(for: ChipTier, codec: …) -> EngineBudgetCap` (exhaustive **switch**, NOT a `[ChipTier:…]` Dictionary — the `BitrateKey` array-of-pairs workaround at :200-206 shows why Hashable-on-MainActor-default fails); per-tier `// validated floor` / `// calibrated ceiling` / `// safe-low, uncalibrated` notes |
| `Onset/Configuration/RecordingConfiguration.swift` | edit | `makeDefault(chipTier:)` calls existing `makeMVPDefault(...)` and overrides only `budgetCap` from the per-tier function (keep `mvpDefault` so non-budget consumers — `RecordingCoordinator`, `MainViewModel+Preview/Devices` — are untouched) |
| `Onset/Recording/Pipeline/QualityLevels.swift` (new) | add | pure: screen/camera level taxonomies (dims+fps+pxRate) from display native + camera announced formats + injected delivered-fps; plus the JOINT-FIT pure free function (reuses `EngineBudgetCap.fits()`) — kept here, not bloating `CapabilityResolver` |
| `Onset/Recording/Pipeline/CapabilityResolver.swift` | edit | **input-contract change**: accept the user-selected target levels; budget-solver (`downscaleIfNeeded`) demoted to safety-net (no-op on UI-selectable combos). Reuse `EngineBudgetCap.fits()`; no new resolver type |
| `Onset/UI/Main/*` (MainViewModel + view) | edit | two quality pickers next to camera/display pickers; reactive greying with actionable reason; visible-notice (inline + menu-bar/deferred); lock during recording; startup `ChipTierDetector → makeDefault(chipTier:)` composition seam |
| `Onset/Storage/` (new quality-intent store) | add | persist chosen levels as intent `(w,h,fps)` (mirror `OutputFolderStore`/`UserDefaultsDeviceSelectionStore`; injected, never `UserDefaults.standard` in tests); intent vs clamped separated |
| `docs/specs/2026-06-02-onset-recording-mvp.md` | edit | amend AC-5 (silent downscale) **and** the Phase-2 deferral of explicit camera-format choice — both superseded here (owner-reviewed) |
| `docs/architecture.md` | edit | document ChipTier/budget + coupled-quality flow |
| `OnsetTests/*` | add | pure tests: ChipTier mapping, per-tier `budgetCap` switch, taxonomy + delivered-fps fallback, JOINT-FIT enumeration vs `fits()`, persistence intent/clamp + restore-notice; L5: AC-Q4 worst-case sweep |

NOTE — **not** changed: `VideoEncoder*.swift`. Real-session `UsingHardwareAcceleratedVideoEncoder`
verification at actual dims under concurrent load **already exists** (`VideoEncoder.swift:404`
throws `noHardwareEncoder`; accessor `:357`; `VideoEncoder+LiveSession.swift:157`; Require-HW at
`:75`). The earlier "GAP: mirror UsingHW at real session" note was stale; empirical code check
supersedes it. If a *user-facing* "HW not granted" indication is wanted (distinct from the existing
hard throw → AC-Q7), that is a `UI/Main/*` addition, not an Encode change (minimal-diff).

## Technical Approach

**Dependency direction (inward, pure core):**

```
impure  ChipTierDetector (nonisolated; sysctl, unsafe)  ──▶  pure ChipTier
pure  RecordingPolicyTypes.budgetCap(for:codec:) switch  ◀── ChipTier
                          │ injected at
impure  RecordingConfiguration.makeDefault(chipTier:)  →  config.budgetCap  (wraps makeMVPDefault, overrides only budgetCap)
                          │ consumed unchanged by
pure  EngineBudgetCap.fits()  ──used by both──▶  pure QualityLevels JOINT-FIT enumeration (UI greying)
                                              └─▶  pure CapabilityResolver (record-path safety-net)
```

- **No new resolver / no Dictionary.** Extend pure `CapabilityResolver` /
  `EngineBudgetCap.fits()`; the per-tier table is an exhaustive `switch` function
  (compiler-checked completeness; carries a `codec` param for forward-compat with no
  multiplier today). `ChipTierDetector` is the only new impure capability, `nonisolated`,
  called once at config assembly.
- **resolve() input contract is the AC-Q5 guarantee.** User-selected levels are the
  *targets*; `downscaleIfNeeded` becomes a safety-net that is provably a no-op on any
  combo the UI marked selectable, because UI enumeration and the record-path use the
  identical `fits()`. This is what makes "no silent downscale" a type-level property,
  not a hope.
- **Calibration honesty — validated floor vs calibrated ceiling.** Seed the M3 Max
  tier with the empirically anchored 0-drop point from #281 L5: 4K60 (497.664M) +
  1080p60 (124.416M) = **622.08M px/s** (pin the floor at ≥ 622.08M and label the
  camera level **1080p60** explicitly — the earlier "≤620M" was an arithmetic slip and
  would fail its own AC-Q3 fit). That 622M is a **validated floor** (safe), not the
  ceiling; AC-Q4's upward sweep finds the real ceiling with margin. Re-anchor on
  worst-case content (the #281 seed run was a fix-verification clip, not a worst-case
  stress). Other tiers: **safe-low** until their own AC-Q4 (AC-Q9).
- **Budget computed on resolved/announced dims** (preflight runs before frames flow);
  document this — the delivered≠announced gap was the original 4K-upscale bug, and the
  camera format cap (#281) keeps announced≈delivered for the camera.
- **delivered-fps seam.** An impure per-device delivered-fps source (preview-stream
  sampling / prior measurement) feeds the pure `QualityLevels`; unmeasured → provisional
  (announced-marked) or withheld, never passed off as delivered (AC-Q2).
- **Thermal / long-session.** AC-Q4 mandates ≥10-min repeated runs to catch
  beyond-cold behavior. If a tier's HW encoder is genuinely thermo-insensitive
  (fixed-function), state that explicitly per tier; otherwise the margin below the
  ceiling is the compensation for the absence of a runtime fallback.
- **Persistence.** Intent stored as `(w,h,fps)` per stream; re-validate + clamp on
  launch with a notice; keep intent for future restoration.

## Technical Constraints

- Swift 6 strict concurrency (`complete`), default `MainActor` isolation,
  warnings-as-errors, strict memory safety (`unsafe` for sysctl C interop). Pure types
  `nonisolated`; enums need explicit `nonisolated static func ==`; **no
  `Dictionary` keyed by a custom pure type** (use `switch` / array-of-pairs, per the
  documented `BitrateKey` constraint).
- macOS 26+, Apple Silicon only — no availability fallbacks.
- UI from standard SwiftUI/AppKit components; visual *design* via the Claude Design
  service, handed to the owner, and it must precede Phase B (AC-Q3 reason surface +
  AC-Q5 notice channel are behavioural ACs that depend on the designed surfaces).
- Minimal diff; pure-logic + impure-actor split per CLAUDE.md.
- The app must never gain network code (existing invariant).

## Decisions Made

1. **Two coupled pickers now, JOINT-FIT** (owner) — both ship; infeasible combos
   greyed with actionable reason. Camera lever near-degenerate today (documented).
2. **Concrete labels** (owner) — "4K · 60 fps", not "High/Medium/Low".
3. **Extend `CapabilityResolver`, add only `ChipTierDetector`; per-tier `switch`, not
   Dictionary** (architecture review — Swift 6 constraint).
4. **Budget gates quality, never recordability** — only hard block is no HW encoder.
5. **Calibrate against worst-case content; validated-floor ≠ calibrated-ceiling;
   uncalibrated tiers fail safe-low, never inherit** — stability #1; preflight is the
   only guard (no runtime fallback in scope).
6. **Persist intent `(w,h,fps)`, not clamped value** — avoids stranding the user.
7. **Encode-layer HW verification already complete** — not re-touched (empirical code
   check over stale plan note).

## Out of Scope

- Per-codec budget multipliers (HEVC-only; AV1 encode not HW-accelerated on Apple
  Silicon ≤ M3). Carry `codec` in the `budgetCap` signature for forward-compat, no
  multiplier now.
- System-audio / multi-camera / multi-display capture.
- Rich Phase-C affordances: hover-tooltips explaining *why* greyed beyond the minimal
  actionable reason, estimated bitrate/file-size hints, one-tap "auto-fit". (The
  minimal **actionable reason** itself is in Phase B — AC-Q3.)
- Graceful-termination finalization (#243) — independent.
- `DropMonitor` degradation-latch redefinition — separate; this spec relies on
  preflight as the guard (hence the AC-Q4/AC-Q9 rigor).
- Manual VBR/bitrate override by the user.
- Mid-session quality re-config (pickers locked during recording, AC-Q11).

## Open Questions

- **[non-blocking] Camera 1080p60 availability.** #281 L5 recorded MX Brio delivering
  ~58 fps at 1080p (39174 frames, 0 gaps) — updating older project memory ("announces
  1080p60, delivers ≤30 fps"). Whether to expose 1080p60 per device hinges on the
  AC-Q2 delivered-fps measurement (verify-cfr + PTS, not nominal); offered only where
  measured clean, else provisional/withheld.
- **[non-blocking] Screen ladder granularity.** Whether to include 1440p tiers between
  4K and 1080p. Default: native-and-below standard 16:9 steps the display supports.
- **[blocking — owner] AC-5 + Phase-2 amendment.** This supersedes MVP AC-5 (silent
  downscale → explicit) **and** the MVP Phase-2 deferral of explicit camera-format
  choice. `docs/specs/` is a meta change: owner-reviewed, never auto-merged. The
  amendment ships in this spec's PR.

## Future Phases

- **Phase A (foundation, ships first, mostly non-UI; STABILITY deliverable):**
  `ChipTierDetector` + `ChipTier` + per-tier `budgetCap` switch + `makeDefault(chipTier:)`
  + M3 Max worst-case calibration (AC-Q4) + safe-low for all other tiers (AC-Q9).
  Self-contained; the preflight budget is the only guard, so this is priority #1.
- **Phase B (the feature):** two coupled pickers, JOINT-FIT greying with actionable
  reason, visible-notice (inline + menu-bar/deferred) on every forced change incl.
  restore-clamp, persistence (intent `(w,h,fps)`), clamp on device/display change,
  camera-off behavior, accessibility, locked-during-recording (AC-Q1/Q2/Q3/Q5/Q6/Q7/Q8/Q10/Q11/Q12).
  Ships per-tier only where AC-Q4-calibrated. Replaces silent AC-5. Requires the
  Claude Design pass first.
- **Phase C (later):** rich affordances; per-tier calibration breadth (esp. a
  single-engine M1 sweep); the camera picker gains real budget weight once the camera
  stack exceeds 1080p.
