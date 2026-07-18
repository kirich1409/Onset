# Progress: disk-space-management (#88)

Spec: `docs/specs/2026-07-18-disk-space-management.md` · Plan: `plan.md` · Tasks: `tasks.md`

## Tasks
- [x] T-1 — Threshold constants + pure disk value types
- [x] T-2 — DiskSpaceProviding seam + actor live impl + fake
- [x] T-3 — DiskSpaceEstimator (pure calculator) + L2 tests [TDD]
- [x] T-4 — DiskSpaceMonitor collaborator + L2 tests
- [x] T-5 — DiskSpaceWarningNotifying seam (warning + auto-stop cause)
- [ ] T-6 — RecordingCoordinator integration + tests
- [ ] T-7 — Pre-flight idle estimate «≈N мин» (AC-1)
- [ ] T-8 — MenuBarExtra badge reflects warning (AC-12a)
- [ ] T-9 — Composition-root wiring (OnsetApp)
- [ ] T-10 — docs/architecture.md update
- [ ] T-11 — L5 calibration & acceptance (AC-10) [hardware-gated]

## Learnings
- T-1: types landed in `Onset/Configuration/RecordingPolicyTypes.swift` (not `Recording/Pipeline/` — that's where the sibling policy types actually live; plan's Affected-Modules table had it right). Introduced an arg-order bug at `RecordingConfiguration.swift:328` (memberwise-init order) — caught by the Layer-1 build, fixed. `ewmaTimeConstantSeconds`=16.0 (=4×movieFragmentInterval 4.0). All 3 enums got explicit `nonisolated static func ==`.
- T-2: CONFIRMED `volumeAvailableCapacityForImportantUsage` is `Int64?`; `volumeIdentifier` is NOT Sendable (as the plan anticipated) — kept inside the actor, only the Sendable snapshot crosses. Actor uses a dedicated serial DispatchQueue via withCheckedContinuation + dispatchPrecondition + os_signpost.
- Layer 1 build: BUILD SUCCEEDED after the arg-order fix.
- T-2 fake: `FakeDiskSpaceProvider` couldn't be `@MainActor` (DiskSpaceProviding is a nonisolated-async protocol) — converted to an `actor` (tests await its call log). Lesson: fakes for nonisolated-async DI seams are actors, not @MainActor classes.
- Recurring memberwise-init arg-order bug (RecordingConfiguration:328 in T-1, DiskThresholds sites in T-3 tests) — both caught by the build, fixed. `DiskThresholds` has many fields; call sites must match declaration order.
- Layer 2 gate: `xcodebuild test` → 975 tests in 176 suites PASSED (incl. new DiskSpaceEstimatorTests + LiveDiskSpaceProviderTests). L0+L2 green through T-5.
- T-4: `MonotonicClock` seam (`SystemMonotonicClock` live + `FakeMonotonicClock` test) for deterministic readEvery/generation tests. FakeDiskSpaceProvider (actor) needed isolated `configure(...)`/`setOutputFreeBytes(_:)` setters — can't assign an actor's stored var from outside via await. Layer-3 gate: full `xcodebuild test` → 983/983 PASSED, no regressions.
