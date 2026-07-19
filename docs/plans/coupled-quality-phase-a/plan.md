---
type: plan
slug: coupled-quality-phase-a
date: 2026-07-19
status: approved
spec: docs/specs/2026-06-29-coupled-recording-quality.md
risk_areas: [perf-critical]
review_verdict: conditional
review_blockers: []
---

# Plan: Coupled recording quality — Phase A (device-budget foundation)

## Context & Decision
Epic #284 replaces the MVP's *silent* screen-downscale (AC-5) with an explicit,
device-budget-aware coupled quality selection. The **what** is decided and frozen in the
owner-reviewed, 4-expert-panel spec `docs/specs/2026-06-29-coupled-recording-quality.md`
(merged). This plan is the **how** for **Phase A only** — the non-UI foundation that de-risks
Phase B: detect the chip tier, map it to a calibrated per-tier encoder budget, and fail
safe-low on every uncalibrated tier. **Phase A ships no user-visible runtime behavior** — it
wires no UI and no startup composition, so the app keeps using `mvpDefault` (995M) at runtime
until Phase B wires `makeDefault(chipTier:)`. Phase A's deliverable is *reviewed, calibrated,
frozen types* (the foundation Phase B builds on), not an active stability win. Spec ACs realized
here: **AC-Q9** (uncalibrated tiers fail safe-low, never inherit a stronger tier's budget) and —
**only on a successful T-6 sweep** — **AC-Q4** (empirical L5 worst-case budget calibration);
until T-6 completes, AC-Q4 is explicitly *unrealized*.

**Reconciliation with the shipped active drop signal (#262 / `main` b355e24).** The spec was
written before #262 merged and frames preflight budget as *the only guard*, a miss being
*silently* bad. That is now stale: #262 added an **active critical-recording signal** that alerts
the user on encoder-backpressure drops / fps-collapse (reading the same per-lane counters T-6
uses). So a budget miss is a **loud** failure (user-visible alert), not a silent corruption —
detection, not correction. This does not lower the calibration bar (a loud "critical problem"
alert mid-recording is still a bad experience the preflight must prevent in normal use), but it
does mean the residual risk of an imperfect cap is a false/late alert, not lost footage. The
budget's job is to keep that alert from firing under the combos the UI offers.

## Technical Approach

**Dependency direction (inward, pure core) — Phase A slice of the spec diagram (spec:184–192):**

```
impure  ChipTierDetector (nonisolated; sysctl brand_string, unsafe)  ──▶  pure ChipTier
pure    EngineBudgetCap.budgetCap(for:codec:) exhaustive switch       ◀──  ChipTier
                                   │ injected at
impure  RecordingConfiguration.makeDefault(chipTier:)  →  config.budgetCap
                                   │  (wraps makeMVPDefault, overrides only budgetCap)
pure    EngineBudgetCap.fits(screen:camera:)  ── unchanged; consumed by CapabilityResolver today
```

Anchors from investigation (all file:line current as of `main` b355e24, confirmed by the
architecture reviewer against source + a live sysctl check on the reference M3 Max):

- **`EngineBudgetCap`** — `nonisolated struct EngineBudgetCap: Equatable`, single stored prop
  `nonisolated let maxPixelsPerSecond: Int` (`RecordingPolicyTypes.swift:389`), method
  `nonisolated func fits(screen:camera:) -> Bool` (`:396–398`) = `screen.pixelRate +
  camera.pixelRate <= maxPixelsPerSecond`. The new `budgetCap(for:codec:)` factory lives here as
  a `nonisolated static func` and returns an `EngineBudgetCap`; `fits()` is untouched.
- **Enum conformances under strict concurrency (empirically verified for THIS enum).** Declare
  `nonisolated enum ChipTier: Equatable, CaseIterable { case m3Max, uncalibrated }` and **rely on
  full compiler synthesis — no explicit `==`, no explicit `allCases`.** A spike compiling exactly
  this under the project flags (`-swift-version 6 -strict-concurrency=complete
  -default-isolation=MainActor -strict-memory-safety`) confirmed it builds and both `==` and
  `allCases` are usable from a `nonisolated` context. Do **not** copy the `DiskWarningReason` pattern
  of a separate `extension ChipTier: Equatable { nonisolated static func == }`: because `ChipTier`
  also conforms to `CaseIterable` (implicit `Hashable`) with `nonisolated` on the decl, a separate
  conformance extension makes the synthesized `Hashable` `@MainActor` and **fails to build** — a
  combination the existing enums (no `CaseIterable`) never exercised. This supersedes the general
  CLAUDE.md "enums need an explicit `nonisolated ==`" note for this specific shape. Fallback only if
  a toolchain regresses: put the witness *inside the enum body* or a non-conformance-redeclaring
  `extension ChipTier { }`. (The `BitrateKey` array-of-pairs workaround at `:198–206` is about
  *keyed lookup* — it is why `budgetCap` is an exhaustive `switch`, not a `[ChipTier: …]` Dictionary.)
- **`ChipTierDetector`** — no `sysctlbyname` exists in `Onset/` yet. Mirror `CapabilityProbe`
  (`Onset/Recording/Pipeline/CapabilityProbe.swift:82`): a `nonisolated enum` namespace of
  `nonisolated static func`s, C interop wrapped in the `unsafe` expression form required by
  `SWIFT_STRICT_MEMORY_SAFETY = YES` (`CapabilityProbe.swift:191–204`). Split pure from impure:
  a pure `chipTier(forBrandString:)` (fully unit-testable, no hardware) and an impure
  `detectChipTier()` that reads `machdep.cpu.brand_string` via `sysctlbyname` (two-call
  size-then-buffer; guard size 0, truncation, non-UTF8) and delegates parsing to the pure function.
  `machdep.cpu.brand_string` returns e.g. `"Apple M3 Max"` (confirmed live on arm64); **`hw.model`
  is not used** — it returns a model code (`"Mac15,10"`) the brand-string parser cannot read, so it
  is not a useful fallback. Any read failure → `.uncalibrated` (safe). Logs the raw brand string via
  `Logger(subsystem: "dev.androidbroadcast.Onset", category: "ChipTierDetector")` (pattern:
  `CapabilityProbe.swift:95`) and never crashes.
- **`makeDefault(chipTier:)` seam** — `RecordingConfiguration` is a `nonisolated struct` with all
  `let` stored props and a hand-rolled `==` (`RecordingConfiguration.swift:38, :417–461`); it cannot
  be mutated after construction. `makeMVPDefault(baseDirectory:cameraMirror:)` (`:331`) sets
  `budgetCap = EngineBudgetCap(maxPixelsPerSecond: 995_000_000)` at `:348`. To override only the
  budget with a minimal diff, add a defaulted trailing param
  `makeMVPDefault(baseDirectory:cameraMirror:budgetCap:)` whose default keeps the existing
  `995_000_000` literal — so `mvpDefault` (`:314`) and its ~100 consumers are byte-for-byte
  unchanged. `makeDefault(chipTier:)` = `makeMVPDefault(budgetCap: EngineBudgetCap.budgetCap(for:
  chipTier, codec: .hevc))`. The retracted 995M surviving as a default arg is a latent footgun
  (any bare `makeMVPDefault()` silently revives it); it is accepted for Phase A's minimal diff and
  scheduled for removal in Phase B once startup wiring makes `makeDefault(chipTier:)` the sole entry.
- **Calibration signal (#287)** — per-lane backpressure-only counters
  `DropBreakdown.bpEncodeScreen` / `.bpEncodeCamera` (`DropMonitor.swift:102–104`) are real
  encoder frame loss per stream; the L5 ceiling search reads these plus `verify-cfr` + PTS deltas.

**ChipTier taxonomy — two cases, conservative by construction.** Only M3 Max is AC-Q4-calibrated
in Phase A; **every other chip — recognized or not — resolves to a single conservative safe-low.**
This is a deliberate revision after the panel showed media-engine count cannot be inferred from a
marketing suffix (Apple Silicon **Pro** chips have **one** media engine, only **Max** = 2, **Ultra**
= 4) and that any per-engine multiplier assumes a VideoToolbox cross-engine session split that is
not guaranteed. Rather than ship an *unproven, possibly 2× over-subscribed* budget as the only
preflight guard on untested hardware, Phase A gives all uncalibrated tiers the conservative
single-stream floor; each earns a higher budget only through its own AC-Q4 sweep (#292). This is
exactly AC-Q9's "safe-low until their own AC-Q4" and honors stability-priority-#1.

```
enum ChipTier { case m3Max        // AC-Q4-calibrated reference tier
                case uncalibrated }  // everything else (recognized or unknown) → conservative safe-low
```

`mediaEngineCount` is **not** added in Phase A — it has no consumer here (JOINT-FIT is Phase B) and
would be a speculative second source of truth for the engine count that the panel showed is easy to
get wrong. It returns as a Phase-B concern if/when per-engine scaling is actually calibrated.

**Budget numbers (px/s), Phase A:**

- `m3Max` → **622_080_000** — the empirically anchored 0-drop point from the #281 L5: 4K60 screen
  (497_664_000) + 1080p60 camera (124_416_000). This is a *validated floor* **only against the
  #281 fix-verification clip, which was not worst-case content** (spec:210) — so it does **not**
  satisfy AC-Q4 on its own. T-6 runs the worst-case sweep to establish the *calibrated ceiling*
  (a quantified margin below the worst observed first-backpressure point) and updates this constant.
  AC-Q4 is realized only when T-6 succeeds.
- `uncalibrated` → **248_832_000** — one sustainable 4K30-equivalent stream's worth of px/s; the
  most conservative safe-low. Strictly below the m3Max floor (never inherits — AC-Q9) and still
  guarantees AC-Q7 recordability by a wide margin (e.g. 1080p60 screen + 1080p30 camera =
  186_624_000 < 248_832_000). Deliberately under-serves quality on strong-but-uncalibrated chips
  (an M-series Max/Ultra records at reduced quality until #292 calibrates it) — the correct
  stability-first trade because the preflight is the guard. **This 248M is a *reasoned* conservative
  bound, NOT an L5-measured ceiling** — it is proven only to satisfy AC-Q7 recordability, not to be
  fully sustainable under worst-case + thermal + concurrent load on the *weakest* single-engine chip
  it covers (base M1, incl. the fanless Air). It must not be trusted as a Phase-B runtime guard on
  such a chip without that chip's own AC-Q4 (#292 lists the M1 sweep as highest-value). Safe for
  Phase A because nothing is wired to runtime here.

`codec` is carried in the signature for forward-compat (spec:256–257, spec:163) with no multiplier
today (HEVC-only; AV1 not HW-accelerated on Apple Silicon ≤ M3). The doccomment must state that
media-engine px/s throughput is codec-agnostic and the param is *reserved* for a future per-codec
throughput correction, so it does not read as a random axis.

## Affected Modules & Files
| Path | Change | Note |
|---|---|---|
| `Onset/Configuration/ChipTier.swift` | New | pure `nonisolated enum ChipTier: Equatable, CaseIterable` (`case m3Max, uncalibrated`) — full compiler synthesis, no explicit witnesses (spike-verified; see Technical Approach) |
| `Onset/Configuration/ChipTierDetector.swift` | New | `nonisolated enum` namespace; pure `chipTier(forBrandString:)` + impure `detectChipTier()` (sysctl `machdep.cpu.brand_string`, `unsafe`, two-call, read-failure → `.uncalibrated`); logs raw string; never crashes |
| `Onset/Configuration/RecordingPolicyTypes.swift` | Modified | add `nonisolated static func budgetCap(for:codec:) -> EngineBudgetCap` on `EngineBudgetCap` — exhaustive `switch` over `ChipTier` (2 cases), per-tier `// validated floor / calibrated ceiling (T-6)` / `// safe-low, uncalibrated` notes + codec-reserved doccomment |
| `Onset/Configuration/RecordingConfiguration.swift` | Modified | add defaulted trailing `budgetCap:` param to `makeMVPDefault` (default = current 995M literal, keeps `mvpDefault` unchanged) + `makeDefault(chipTier:) -> Self` |
| `OnsetTests/ChipTierTests.swift` | New | pure: off-main `==` witness, off-main `allCases` access |
| `OnsetTests/ChipTierDetectorTests.swift` | New | pure: brand-string → tier parse matrix (M3 Max variants → `.m3Max`; every other string incl. other Apple chips / empty / garbage → `.uncalibrated`); never crashes |
| `OnsetTests/EngineBudgetCapTierTests.swift` | New | pure: switch exhaustiveness (all cases), m3Max = 622.08M floor, `uncalibrated` < m3Max (never-inherit over `allCases`), AC-Q7 recordability floor |
| `OnsetTests/RecordingConfigurationTests.swift` | Modified | `mvpDefault.budgetCap` still 995M (byte-identical); `makeDefault(.m3Max).budgetCap` = 622.08M; `makeDefault(.uncalibrated).budgetCap` = 248.832M; only `budgetCap` differs from `mvpDefault` |
| `docs/architecture.md` | Modified | document ChipTier / per-tier budget flow + validated-floor vs calibrated-ceiling + #262-signal reconciliation |
| `Onset/Configuration/RecordingConfiguration.swift` (inline docstrings) | Modified | update `mvpDefault` docstring + `EngineBudgetCap` type-doc (`RecordingPolicyTypes.swift:383–395`) that reference the retracted 995M / AC-5 placeholder — stale-docs = defect |
| `docs/plans/coupled-quality-phase-a/calibration-l5.md` | New (by T-6) | durable AC-Q4 calibration evidence (precedent: `docs/plans/disk-space-management/calibration-l5.md`) — NOT gitignored `swarm-report/` |

Explicitly NOT touched (verified against spec:157–178): `VideoEncoder*.swift` (HW verification
already exists), `QualityLevels.swift`, `CapabilityResolver.swift` input contract, `UI/Main/*`,
`Storage/` intent store, `docs/specs/2026-06-02-onset-recording-mvp.md` AC-5 amendment — all Phase B/C.

## Decisions Made
| Decision | Rationale | Alternatives rejected |
|---|---|---|
| `ChipTier` = 2 cases `.m3Max` / `.uncalibrated`; all non-M3-Max chips → one conservative safe-low | Media-engine count is not inferable from a marketing suffix (Pro = 1 engine, only Max = 2, Ultra = 4 — panel), and any per-engine multiplier assumes a VT cross-engine split that is not guaranteed; shipping an unproven multi-engine budget as the sole guard on untested HW violates AC-Q9 + stability-#1. Conservative safe-low is AC-Q9's "safe-low until own AC-Q4" | 4-case taxonomy with a `multiMediaEngineUncalibrated`=497.664M bucket (my earlier draft): over-subscribes Pro chips 2×, ships an unmeasured number as an active guard, and needs a fragile suffix parse |
| Drop `mediaEngineCount` from Phase A | No consumer in Phase A (JOINT-FIT is Phase B); a second in-code source of the engine count that the panel showed is error-prone (YAGNI) | Keeping it now — speculative, and risks drifting from the budget switch |
| Detect via `machdep.cpu.brand_string` only; no `hw.model` fallback; recognize just "M3 Max" | brand_string names the tier directly (live-confirmed on arm64). `hw.model` returns a model code the parser can't read, so it always yields `.uncalibrated` — a non-functional "fallback". Everything-else→`.uncalibrated` makes the parser trivial and robust | `hw.model` fallback (nonfunctional as described); a model-code→tier table (unneeded when non-M3-Max all share one budget) |
| Pure `chipTier(forBrandString:)` + impure `detectChipTier()` split, impure path smoke-tested on HW in T-6 | Parsing is fully unit-testable with no hardware; the impure sysctl/unsafe path has its own failure modes (size 0, truncation) and must be exercised once on the reference M3 Max, not shipped unrun | Single impure function (untestable mapping); shipping the unsafe path with zero runtime execution |
| Override budget via a defaulted trailing `budgetCap:` param on `makeMVPDefault`; schedule 995M-default removal for Phase B | `let`-only struct can't be copy-mutated; a defaulted param keeps `mvpDefault` + ~100 consumers byte-identical (minimal diff). The retracted-995M-as-default footgun is fenced by a Phase-B removal task | Hand re-init of 26 props (churn + drift); a `with(budgetCap:)` copy helper (new surface for one caller); leaving 995M default permanently (retracted value can leak) |
| `budgetCap(for:codec:)` = exhaustive `switch`, not `[ChipTier: …]` | Swift-6 MainActor-inference breaks `Hashable` on a pure type (documented `BitrateKey` constraint); `switch` is compiler-checked complete | Dictionary keyed by ChipTier — the pattern the codebase already had to work around |
| m3Max seeded at the 622.08M floor but AC-Q4 is UNrealized until T-6's worst-case sweep sets the calibrated ceiling | The floor was measured on a non-worst-case clip (spec:210); calling it AC-Q4-satisfied would ship an unvalidated guard. L5 IS available on this host, so T-6 runs for real | Treating the floor as AC-Q4-satisfied (false); seeding at the retracted theoretical 995M |
| If T-6 is genuinely blocked (TCC/HW), m3Max falls back to the `uncalibrated` safe-low (248.832M), NOT the floor | The floor is not worst-case-validated; the only defensible unproven default is the conservative safe-low. Recorded as a tracked exception, AC-Q4 marked unrealized | "Ship floor-only" (my earlier draft) — ships a non-worst-case number as the sole guard, contradicting AC-Q4 being "the gate that matters" |

## Risks & Mitigations
| Risk | Severity | Mitigation |
|---|---|---|
| Scalar additive px/s cap under-models the shared HW encoder — camera lane is per-pixel-costlier, and a Phase-B user split could load the camera lane harder than the calibrated combo | critical | T-6 calibrates the **camera-heaviest** max combo the taxonomy offers, under worst-case **camera-lane** content (spec:86–88), so the cap bounds the costliest allocation, not a mid-point. Documented Phase-B watch-item: if Phase-B allocation widens beyond the calibrated combo, re-validate at the new heaviest split or introduce a camera-px weight. The scalar remains the right Phase-B JOINT-FIT primitive; the *value* must bound the worst admitted split |
| Calibration threshold is stochastic/episodic (original bug clustered 50–90s), so a single "first drop" sweep mis-anchors the cap | critical | T-6 runs **≥5 runs of ≥10 min** at each sweep step; anchor the ceiling **below the worst (minimum) observed 0-drop point**, not the last; margin is an explicit quantified % (see below), never "a bit below" |
| Uncalibrated-tier budget wrong → silently bad recording (preflight is primary guard) | critical → downgraded | (a) all uncalibrated tiers get the conservative single-stream safe-low, provably < m3Max; test asserts it over `allCases`. (b) #262's active drop signal makes any miss **loud** (user alert), not silent — second line of defense, not correction |
| Media-engine count / VT cross-engine split assumption wrong for a strong uncalibrated chip | major → resolved | Removed the per-engine multiplier entirely; every uncalibrated chip = single conservative safe-low regardless of engine count until its own AC-Q4 |
| Cold/quiet-machine calibration hides thermal + contended drops (project non-negotiable: "runtime is loaded") | major | T-6 runs to **thermal plateau** (monitor `powermetrics` / thermal pressure, not a fixed timer) **and under representative concurrent load** (browser/IDE/GPU app active), per CLAUDE.md; margin absorbs residual thermal + inter-unit variance |
| Unsynchronized keyframe/GOP coincidence between the two sessions doubles instantaneous load (plausible cause of the episodic clustering) | major | T-6 includes a keyframe-coincidence condition (force-aligned IDR across both sessions) and sizes the margin for peak, not average, load |
| Bitrate/entropy not a budget axis — a higher prod bitrate at the same px/s costs the entropy coder more | major | T-6 calibrates at a bitrate ≥ the max any shipped combo can request; pin the invariant "calibration bitrate ≥ any achievable prod bitrate for that px/s" in the evidence + doccomment |
| Impure `detectChipTier()` (unsafe sysctl) never executed before shipping | major → resolved | T-6 (on the reference M3 Max) asserts `detectChipTier() == .m3Max` and logs the raw brand string into the evidence file — the "verify empirically, don't assume" gate, nearly free |
| AC-Q4 evidence lost (gitignored) | major → resolved | Evidence written to `docs/plans/coupled-quality-phase-a/calibration-l5.md` (durable, in the PR), key numbers duplicated in the PR body |
| `makeMVPDefault` param addition changes an existing consumer | minor | Defaulted param = call-site-compatible; `RecordingConfigurationTests` asserts `mvpDefault` byte-identical; full `check` between tasks |

**Explicit calibration margin + ceiling search (T-6).** The upward ceiling search MUST push
combined px/s **above** the 622.08M taxonomy max (synthetic higher resolutions on the same lanes)
to a real backpressure **cliff** — testing only the 622.08M combo would degenerate "worst 0-drop"
to 622.08M, and 0.85× would then exclude the very combo that passed. Set the m3Max ceiling at
**0.85 × the worst (minimum) observed 0-drop combined px/s _at the cliff_**. The 15% headroom is the
default budget for (threshold dispersion across runs + thermal drift beyond the plateau +
inter-unit/ambient variance + **cross-chassis thermal**: a 14" M3 Max throttles harder than a 16",
and the reference is one machine), since there is no runtime auto-throttle. T-6 widens the factor
(more conservative) if run-to-run dispersion is wide or to cover the hottest chassis, and records
the factor + dispersion + chassis in the evidence; it must not go below 0.85 without recorded
justification. To make the recorded dispersion meaningful, concurrent load MUST come from a
**reproducible, pinned harness** (named apps / GPU scenario at a representative p95 user level, not
max), also recorded — an uncontrolled background inflates dispersion with noise and over-shrinks the
cap into false unavailability. **Honest outcome:** if `0.85 × cliff < 622.08M` under worst-case
content, 622.08M is *not* a floor — the calibrated ceiling governs, `.m3Max` takes it regardless,
and the taxonomy max combo is greyed in Phase B (AC-Q7 holds on lower combos).

**Phase A "done" =** T-1..T-5 green **and** (T-6 ran and set the calibrated ceiling **OR** T-6 is
blocked-with-tracked-exception and `.m3Max` sits at the `.uncalibrated` safe-low with AC-Q4 marked
UNREALIZED). Merging Phase A with AC-Q4 UNREALIZED requires the remaining L5 gate to be stated in
the PR body (CLAUDE.md autonomy rule for deferred L5).

## Verification & Sources

| Source of truth | Type | Status | Sufficient for verification? |
|---|---|---|---|
| `docs/specs/2026-06-29-coupled-recording-quality.md` (AC-Q9, and AC-Q4 on T-6 success) | spec | present | yes — AC-Q9 is falsifiable by unit enumeration over `allCases` (no `.uncalibrated` budget EXCEEDS the *dynamic* `.m3Max` budget, checked against `budgetCap(for: .m3Max)` not a literal, so it survives T-6 mutating the constant); AC-Q4 is falsifiable by the L5 sweep pass condition (ceiling search pushed ABOVE the 622.08M taxonomy max to a real backpressure cliff; 0 `bpEncode*` over ≥5×≥10 min at each accepted step at the camera-heaviest combo, verify-cfr + PTS, ceiling at 0.85× the worst 0-drop at the cliff) |
| `docs/plans/coupled-quality-phase-a/calibration-l5.md` (written by T-6) | empirical measurement (durable) | to-capture-during-impl | yes — records per-run per-lane drop counts, the worst 0-drop combo, the chosen margin + dispersion, the raw brand string, and `detectChipTier()==.m3Max`, letting anyone confirm the ceiling is a real worst-case 0-drop point with margin |

**Testing strategy (pyramid levels):** L0 build (warnings-as-errors, Swift 6 strict concurrency
`complete`) always + L1 static (`swiftformat --lint .`, `swiftlint --strict`) + L2 Swift Testing
(pure ChipTier / detector-parse / budget-switch / makeDefault — the bulk of Phase A) + **L5**
mandatory for T-6 (AC-Q4 is *by definition* an empirical hardware gate; env-gated capture suite,
signed build, `scripts/hw-lock.sh`, MX Brio + 4K display). L5 is mandatory here because this is an
infra-layer change to the encode-budget guard whose correctness cannot be asserted from code alone
(qa-and-testing §0). T-1..T-5 are pure/config and fully covered by L0–L2; only T-6 needs L5.

## Out of Scope
- Everything Phase B/C: `QualityLevels` taxonomy + JOINT-FIT enumeration (#288), `CapabilityResolver`
  input-contract change (#289), the two UI quality pickers + greying + notice channel + a11y + lock
  (#290), persistence of intent (#291), per-tier calibration for other tiers (#292, tracked follow-up
  — each earns its budget via its own AC-Q4 sweep; until then it is `.uncalibrated` safe-low).
- Wiring `ChipTierDetector → makeDefault(chipTier:)` into app startup — that composition seam lives
  in `UI/Main/*` and is Phase B. Phase A delivers `makeDefault(chipTier:)` as a tested function only,
  so no runtime behavior changes.
- **Removal of the 995M default arg on `makeMVPDefault`** — done in Phase B once `makeDefault(chipTier:)`
  is the sole startup entry; tracked as **#340** (blocked-by Phase-B startup wiring) so the retracted
  value cannot silently leak.
- Amending MVP spec AC-5 — rides the Phase-B PR that actually removes the silent downscale.
- `DropMonitor` degradation-latch redefinition (separate work); per-codec budget multipliers;
  `mediaEngineCount` / per-engine budget scaling (returns in Phase B if calibrated).

## Open Questions
- [non-blocking] Flat `ChipTier` mixes a concrete calibrated chip (`.m3Max`) with a capability
  bucket (`.uncalibrated`). Pragmatic at one calibrated tier; **watch-item** — when a 3rd tier is
  calibrated (#292), reconsider a structured representation (engineCount + calibrationKey) instead
  of a case per chip.
- [non-blocking] T-6's max-combo target (4K60 + 1080p60) depends on the Phase-B `QualityLevels`
  taxonomy (#288) and the spec's open camera-1080p60-vs-30 question. T-6 calibrates against the
  upper-bound combo (1080p60 camera); if Phase B narrows the taxonomy, the ceiling is re-measured.
- [non-blocking] **Spec deviation to surface for owner review.** The frozen spec's *non-normative*
  sketch (spec:161; AC-Q9:128 "e.g. … scaled by the tier's known media-engine count where
  available") suggests per-tier engine scaling; this plan collapses all uncalibrated tiers to one
  safe-low — strictly more conservative, no normative requirement lost (the "e.g."/"where available"
  is illustrative, and the AC-Q9 hard falsification "base-M1 → M3 Max budget" is still impossible).
  Because `docs/specs/` is owner-reviewed meta, the eventual PR body MUST surface this deviation in
  one line, and the owner may amend the non-normative spec sketch so `main` does not contradict the
  implementation (docs-revision non-negotiable). Do NOT silently edit the frozen spec.
- [non-blocking] `CaseIterable` is marginal at two cases (its `allCases` is used only by the
  never-inherit test's enumeration). It is synthesized `nonisolated` fine here (spike-verified, so no
  hand-written witness is needed), but the real completeness guard against a forgotten future tier is
  the exhaustive `switch` in T-3 (it fails compilation on a new case), not `CaseIterable`.
