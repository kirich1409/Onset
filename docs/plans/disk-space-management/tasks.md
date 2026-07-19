# Tasks: disk-space-management (#88)

Spec: `docs/specs/2026-07-18-disk-space-management.md`. Each task cites the `AC-N` it advances;
acceptance below is the *implementation-level* check that the AC is met. L0 (build) + L1
(swiftformat `--lint .` + swiftlint `--strict`) are an implicit gate on every task — not repeated.

Parallelism: T1, T2, T5 have no deps (can run together). T3 after T1. T4 after T2+T3. T6 after
T4+T5. T7/T8 after T6. T9 after T6+T7. T10/T11 after integration.

## Traceability (every AC → task)

| AC | Task(s) | AC | Task(s) |
|---|---|---|---|
| AC-1 (pre-flight idle) | T-7 (calc in T-3, monitor in T-4) | AC-7 (last-resort diskFull/unplug) | **T-6** |
| AC-2 (tick, no new timer, off-main) | T-6 (provider T-2, monitor T-4) | AC-8 (idempotent stop) | T-6 |
| AC-3 (actionable warning, reason) | T-3 (reasons), T-6 (surface) | AC-9 (auto-stop cause notify) | T-5, T-6 |
| AC-4 (critical auto-stop, no deadlock) | T-6 | AC-10 (calibration + perf gate) | **T-11** |
| AC-5 (smoothed speed, floor active) | T-3 | AC-11 (de-escalation/hysteresis) | T-3 (calc), T-6 (surface) |
| AC-6 (two volumes, volume id) | T-2 (resolve), T-3 (strictest) | AC-12 (badge + one-shot UN) | T-5, T-6, T-8 |

---

## T-1 — Threshold constants + pure disk value types
- after: —
- files: `Onset/Configuration/RecordingConfiguration.swift`, `Onset/Recording/Pipeline/RecordingPolicyTypes.swift`
- interface:
  - produces: `DiskThresholds` (struct: `systemWarnBytes`, `systemStopBytes`, `outputWarnBytes`, `outputStopBytes`, `outputWarnEtaSeconds`, `outputStopEtaSeconds`, `ewmaTimeConstantSeconds` = **≥ 4× movieFragmentInterval** (EWMA time-constant, not a ring-buffer count — see T-3), `readEverySeconds` ≈ `movieFragmentInterval`, `warmupSeconds`, `hysteresisReleaseBytes` (byte-release margin for free-byte reasons), `deescalationDebounceSeconds` (hold time before clearing a warning)); `DiskVerdict` enum (`none` / `warning(DiskWarningReason)` / `critical(DiskStopReason)`) — `DiskWarningReason`/`DiskStopReason` distinguish output-eta / output-free / system-free (AC-3). **All three enums (`DiskVerdict` AND the nested `DiskWarningReason`/`DiskStopReason`) need an explicit `nonisolated static func ==` witness** (`InferIsolatedConformances` infers `@MainActor ==` even on a `nonisolated` decl — the nested payload enums are easy to forget). `ETAEstimate` (`secondsRemaining: Double?`, `isEstimateAvailable: Bool`, `slopeConfidence: Double`). Defaults on `RecordingConfiguration` (system warn ≤10GB/stop ≤5GB; output warn ETA≤10min|≤10GB / stop ≤2GB|ETA≤2min).
  - consumes: `RecordingConfiguration.averageBitrate(:203)`, `movieFragmentInterval`.
- acceptance: THE SYSTEM SHALL expose `DiskThresholds` as data on `RecordingConfiguration` (no hardcoded literals elsewhere); `ewmaTimeConstantSeconds` default SHALL be ≥ 4× movieFragmentInterval (≥4 reads influence the estimate at readEvery≈movieFragmentInterval); `DiskVerdict` + nested reason enums + `ETAEstimate` are `nonisolated` value types usable off MainActor.
  - check: build green; `grep` shows threshold numbers only in `RecordingConfiguration`/`RecordingPolicyTypes`; assert `ewmaTimeConstantSeconds >= 4 * movieFragmentInterval`; `DiskVerdict` AND `DiskWarningReason` AND `DiskStopReason` each have explicit `nonisolated static func ==`; a `nonisolated` off-MainActor call site compiles.

## T-2 — DiskSpaceProviding seam + actor live impl (dedicated executor) + fake
- after: —
- files: `Onset/Recording/Pipeline/DiskSpaceProviding.swift` (new), `OnsetTests/FakeDiskSpaceProvider.swift` (new)
- prerequisite gate (verify BEFORE code): confirm `URLResourceValues.volumeAvailableCapacityForImportantUsage` Swift type (Int64?) and `.volumeIdentifierKey` availability on macOS 26 via Xcode Quick Help (T1). Record confirmation in the task note.
- interface:
  - produces: `nonisolated protocol DiskSpaceProviding: Sendable` with async `snapshot(outputURL: URL) async -> DiskVolumesSnapshot`. **`DiskVolumesSnapshot` must be fully `Sendable`** = `(outputFreeBytes: Int64?, systemFreeBytes: Int64?, sameVolume: Bool)` — **the raw `volumeIdentifier` (Apple type `(NSCopying & NSObjectProtocol)?`, NOT Sendable) MUST NOT cross the actor boundary**; the actor resolves both volume ids internally, computes `sameVolume` there, and returns only the Sendable tuple. `actor LiveDiskSpaceProvider` wrapping `URLResourceValues`: the **blocking read is bridged off the cooperative pool via `withCheckedContinuation` dispatched onto a private serial `DispatchQueue`** (NOT a custom actor-wide `SerialExecutor` — simpler, wraps only the blocking call); resolves output volume from the URL (**walking up to the nearest EXISTING ancestor** — `baseOutputDirectory` may not exist yet: `resourceValues` on a missing path throws/nil) and system volume from `/System/Volumes/Data`; compares cheap `volumeIdentifierKey` FIRST — on match performs ONE `...ImportantUsageKey` read and sets `sameVolume=true`. `FakeDiskSpaceProvider` (`@MainActor final class`, scriptable capacities + **scriptable delay** + call log; template = `FakeDisplaySleepPreventer`).
  - consumes: `DiskVerdict` reasons (T-1) not required here; independent otherwise.
- acceptance:
  - Given a URL on some volume, When `snapshot` is called, Then output free = that volume's `...ImportantUsage` (or nil on read failure — never a fabricated number). (AC-6, error-safety)
  - Given output and system on the SAME volume, When snapshotted, Then `sameVolume==true` by `volumeIdentifier` compare (not path string) AND exactly ONE expensive `...ImportantUsage` read is issued. (AC-6, perf)
  - Given output and system on the SAME volume, Then `sameVolume==true` (computed inside the actor by `volumeIdentifier` compare, not path string) AND exactly ONE `...ImportantUsage` read is issued.
  - THE LIVE PROVIDER SHALL run its blocking read off MainActor AND off the shared cooperative pool. Empirical proof: `dispatchPrecondition(condition: .onQueue(dedicatedQueue))` on the read path (proves ON the dedicated queue — a bare `assert(!Thread.isMainThread)` proves off-main only, not off-cooperative-pool). os_signpost captures latency (not thread identity). Also **empirically measure `volumeIdentifierKey` read cost** (signpost) — the "cheap, not XPC" claim is a hypothesis; if it triggers the same expensive recompute, the dedup still saves the second `...ImportantUsage`.
  - check: build green (Sendable snapshot crosses the boundary with no `volumeIdentifier` leak); `FakeDiskSpaceProvider` conforms; unit test asserts nil-on-failure, sameVolume + single-read on same volume, nearest-ancestor resolution when base dir absent; task note records the Xcode type confirmation and the queue-precondition mechanism.

## T-3 — DiskSpaceEstimator (pure calculator) + L2 tests [TDD]
- after: T-1
- files: `Onset/Recording/Pipeline/DiskSpaceEstimator.swift` (new), `OnsetTests/DiskSpaceEstimatorTests.swift` (new)
- interface:
  - produces (all `nonisolated`, pure — no framework/actor deps):
    - (a) a pure value type `SmoothingState` (EWMA accumulator + recent-Δ stats) and `updateSmoothing(_ state: SmoothingState, freeBytes: Int64, elapsedSeconds: Double, thresholds:) -> SmoothingState` — **EWMA over per-read `Δ(free)/Δt`** with time-constant = `ewmaTimeConstantSeconds` (state = one accumulator + running variance of recent Δ; NOT a ring buffer). `SmoothingState` is owned by the Monitor (T-4) but updated only through this pure func so AC-5 tests hit pure code. `speed(_ state:) -> Double` and `slopeConfidence(_ state:) -> Double` = **SNR proxy** `|ewmaSpeed| / max(ε, stddev(recentΔ))` (method fixed here; the SNR<1 cutoff for gating is the calibrated value).
    - (b) `evaluate(outputFreeBytes:, systemFreeBytes:, sameVolume:, state: SmoothingState, thresholds:, previousVerdict:) -> DiskVerdict` — **byte-floor is the primary critical trigger** (fires regardless of ETA when below stop-bytes, incl. speed ≤ 0); **ETA thresholds secondary, gated on `slopeConfidence`** (< cutoff → ETA-warning suppressed, byte-floor still active); `ETA = outputFree / speed(state)`; `sameVolume` → strictest verdict; **hysteresis**: a warning clears only when the metric recovers above `set + hysteresisReleaseBytes` (free-byte reasons) or above warn-ETA margin, AND stays recovered for `deescalationDebounceSeconds` (both, scoped by reason type) — vs `previousVerdict`.
    - (c) `idleEstimate(freeBytes:, plan: ResolvedRecordingPlan, config:) -> ETAEstimate` (fallback bitrate, whole minutes, `>60 мин` cap, `.unavailable` on bad data). Idle DiskVerdict for the system/output warning at idle comes from the SAME `evaluate` seeded with `previousVerdict: .none` and a warmup `SmoothingState` (fallback bitrate speed) — T-7 calls both on one snapshot.
  - consumes: `DiskThresholds`, `DiskVerdict` + reasons, `ETAEstimate`, `SmoothingState` (T-1 for the first three), `ResolvedRecordingPlan`, `RecordingConfiguration.averageBitrate`.
- acceptance (each AC → a named test; watch-red-first for TDD cells):
  - AC-5: smoothing over a burst input (flush ~4s at 1Hz sampling) does NOT cross threshold falsely; `ETA = outputFree / smoothedSpeed`; at speed ≤ 0 the byte-floor still yields `critical` below stop-bytes.
  - AC-5: window contains ≥ 4 samples; warmup (< `warmupTicks`) falls back to table bitrate sum.
  - AC-5/ETA-SNR: given low `slopeConfidence`, ETA-warning is suppressed but byte-floor critical still fires (floor primary, ETA secondary).
  - AC-11: oscillating input around the warn threshold does NOT flip verdict each tick (hysteresis/debounce) — dedicated oscillation test.
  - AC-6: same-volume → strictest verdict; OS floor (5/10GB) NOT applied to an external output volume.
  - AC-3: warning verdict carries the correct reason (output-eta vs output-free vs system-free).
  - AC-1: `idleEstimate` returns whole-minute value, `>60 мин` when large, `.unavailable` on nil/bad data.
  - check: `xcodebuild test` — all `DiskSpaceEstimatorTests` pass; injected clock (no wall-clock sleep).

## T-4 — DiskSpaceMonitor collaborator + L2 tests
- after: T-2, T-3
- files: `Onset/UI/DiskSpaceMonitor.swift` (new), `OnsetTests/DiskSpaceMonitorTests.swift` (new)
- interface:
  - produces: `@MainActor final class DiskSpaceMonitor` holding `DiskSpaceProviding` + `RecordingConfiguration` + injected clock + **`SmoothingState`** (pure, T-3; updated only via `updateSmoothing`) + `lastReadAt` + **cached latest `DiskVerdict`** + one-shot warning-posted flag + last-good state + **`refreshInFlight` guard** + **`generation: Int` token**; `var currentVerdict: DiskVerdict` (cached, read synchronously by the tick). **The Monitor owns the `readEvery` throttle**: `func tickRefresh(outputURL: URL)` is called by the tick every ~1s but only spawns a read when `readEvery` has elapsed (injected clock) AND no refresh is in flight — this is what keeps the actual XPC cadence at `readEvery`, not 1Hz. The spawned refresh: captures `generation`, reads via provider off-main, on return **sets `refreshInFlight=false` in a `defer` UNCONDITIONALLY** (else a `reset()` during a slow refresh would wedge all future refreshes), then applies the result **only if the captured generation still matches** (drops out-of-order/pre-reset results) — updates `SmoothingState` via `updateSmoothing`, calls `evaluate`, **writes cached verdict only when it changes (Equatable-guard)**, preserves last-good on read failure. The refresh does **NOT post warnings or trigger stop** — it only updates cached state; the tick reads `currentVerdict` and decides (T-6). `func idleEstimate(outputURL:, plan:) async -> ETAEstimate` (+ idle `evaluate`); `func reset()` (**increments `generation`**, clears `SmoothingState` + one-shot flag).
  - consumes: `DiskSpaceProviding` (T-2), `DiskSpaceEstimator` + `SmoothingState` + types (T-3).
- acceptance:
  - Given scripted decreasing capacities from `FakeDiskSpaceProvider`, When `refresh` runs across ticks, Then `currentVerdict` transitions none→warning→critical at the spec thresholds. (AC-2,3,4)
  - Given a provider read returning nil, When refreshed, Then the monitor keeps its last-good verdict (no flap, no critical on garbage). (error-safety)
  - **Given two overlapping slow refreshes (provider delays > readEvery), When both resolve, Then the smoothing window is not corrupted by out-of-order application and no second refresh starts while one is in flight (single-flight).** (concurrency — regression from fire-and-forget)
  - **Given a slow refresh in flight, When `reset()` runs (new session) and the old refresh then resolves, Then its stale near-full capacity is dropped (generation mismatch) and does NOT contaminate the new session's window/verdict.** (cross-session safety)
  - Given a stable verdict across refreshes, Then the cached verdict property is written at most once (Equatable-guard — no per-tick churn). (perf)
  - Given `reset()`, Then `generation` increments and rolling state + one-shot flag clear. (AC-1 re-estimate)
  - **Given `tickRefresh` called every 1s with `readEvery`=4s, When 4 ticks elapse, Then exactly ONE provider read is issued (Monitor throttles to readEvery, not 1Hz).** (perf/cadence)
  - **Given a slow refresh in flight and a `reset()` mid-flight, When the slow refresh returns, Then `refreshInFlight` is cleared (defer) and subsequent `tickRefresh` calls resume issuing reads (no permanent wedge).** (liveness — the defer bug)
  - check: `xcodebuild test` — `DiskSpaceMonitorTests` pass with `FakeDiskSpaceProvider` (scriptable delay) + injected clock; overlapping-refresh, pre-reset-contamination, readEvery-throttle, and defer-unwedge tests included.

## T-5 — DiskSpaceNotifier seam (warning + auto-stop cause) — SEPARATE file
- after: —
- files: `Onset/Permissions/DiskSpaceNotifier.swift` (**new — NOT an extension of `RecordingStartNotifier.swift`**, to shrink merge-conflict surface with sibling `critical-recording-signals`); `OnsetTests/FakeDiskSpaceWarningNotifier.swift` (new)
- prerequisite gate: UserNotifications infra confirmed present in main (`RecordingStartNotifier.swift`); mirror its pattern.
- interface:
  - produces: `@MainActor protocol DiskSpaceWarningNotifying: AnyObject` with `func notifyLowSpaceWarning(reason:)` (AC-12, one-shot per crossing) and `func notifyAutoStopped(filesSaved:)` (AC-9: names cause «мало места» + confirms both files saved, reveal/path if possible); `LiveDiskSpaceWarningNotifier` (fire-and-forget `Task`, lazy UN-auth, silent fallback on `.denied`, PII-free `os.Logger` — mirrors `LiveRecordingStartNotifier`); `FakeDiskSpaceWarningNotifier` (call log).
  - consumes: `DiskWarningReason`/`DiskStopReason` (T-1).
- acceptance:
  - THE NOTIFIER SHALL post a UserNotification naming the low-space cause and, on auto-stop, confirm files were saved (positive fact, not silent abort). (AC-9)
  - Denied UN authorization SHALL NOT abort recording (silent fallback).
  - check: build green; `FakeDiskSpaceWarningNotifier` conforms; unit test asserts content includes cause + files-saved; file is a new standalone module (grep confirms `RecordingStartNotifier.swift` untouched).

## T-6 — RecordingCoordinator integration + tests
- after: T-4, T-5
- files: `Onset/UI/RecordingCoordinator.swift`, `OnsetTests/RecordingCoordinatorTests.swift` (extend), `OnsetTests/CoordinatorFixtures` (extend)
- prerequisite gate: confirm `AVError.Code.diskFull` (apple-docs — exists on macOS) before wiring AC-7.
- interface:
  - consumes: `DiskSpaceMonitor` (T-4), `DiskSpaceWarningNotifying` (T-5), existing `stop()`/`tickTask`/`lastWriteError`.
  - produces: new init params `diskSpaceProvider` (live default) + `diskWarningNotifier` (live default) — same optional-param-with-live-default seam as `sleepPreventer`/`notifier` (:242-248); owned `DiskSpaceMonitor`; published warning state (`diskWarning: DiskWarningReason?`, Equatable-guarded) + de-escalation; a **distinct, non-error `stoppedDueToLowSpace` state** for AC-9 (graceful stop — files saved). **This does NOT reuse `lastWriteError`/`hasPendingAlert`** (which force-opens MainView on menuBar-origin at :823, appropriate for a write ERROR but NOT for a graceful low-space stop): the out-of-window surface for AC-9 is the UserNotification; the in-app state is informational and does not force-open the window. `reset()` on new record clears both `diskWarning` and `stoppedDueToLowSpace`.
  - integration point: within the existing `startTickLoop` (:708-718) which already `await`s `currentDrops()` — insert (in order, without disturbing the existing elapsed/drops readout): (1) `monitor.tickRefresh(outputURL:)` (non-awaited; Monitor throttles + single-flights internally); (2) read `monitor.currentVerdict` synchronously; (3) act on it (warning post / critical break+`Task{stop}`). All decision logic lives on the tick (MainActor-serial), NOT in the refresh task.
- acceptance:
  - AC-2: the tick calls `monitor.tickRefresh` (non-awaited; Monitor throttles to `readEvery` + single-flights) and reads the **cached** verdict synchronously — so slow XPC never delays the existing elapsed/drops readout; no new high-freq timer (verified by diff — no new `Timer`/`Task.sleep` loop); all warning/stop DECISIONS are on the tick, not in the refresh task.
  - AC-4/AC-8: on `critical` verdict the loop breaks and hands off via `Task { await self.stop() }` (NOT inline `await self.stop()`; precedent `:956`, contrast `:774` await); auto-stop routes through the single idempotent `stop()` exactly once; both files finalize valid (existing completed-result fixtures).
  - AC-4/spurious-guard: after `await` in the refresh task, the monitor's **generation-token match** (not just `phase == .recording`, which is ambiguous across sessions) + `Task.isCancelled` is checked before processing the verdict or posting a warning — a manual stop racing a refresh, or a pre-reset refresh landing in a new session, does NOT post a spurious warning or trigger a false stop. (test: stop-during-refresh → no warning, single teardown; `reset()` invalidates prior generation)
  - AC-3: on `warning` verdict, recording continues and the actionable warning state is set with the correct reason.
  - AC-11: warning state de-escalates when capacity/ETA recovers above the release threshold.
  - AC-9: on disk-critical stop, `diskWarningNotifier.notifyAutoStopped(filesSaved:)` is called (asserted on fake).
  - **AC-7 (last-resort)**: Given a writer surfacing `AVError.Code.diskFull` (or a completed `failedWriteResult`), When the pipeline faults, Then recording finalizes gracefully through the existing `lastWriteError` channel (NOT a raw abort) — regression test; AND an external output-volume unplug degrades to the writer-fault path (same channel, not a disk-space stop). (extend `CoordinatorFixtures.failedWriteResult()`)
  - AC-1 clear: initiating a new recording clears prior disk-stop state (no stuck alert/block).
  - check: `xcodebuild test` — coordinator tests pass driving `FakeDiskSpaceProvider` to warning+critical; idempotent-stop test (single teardown under disk-stop racing manual stop); AC-7 last-resort regression; diff shows no new timer, `Task { await self.stop() }` (not inline), and tick not `await`ing the disk read.

## T-7 — Pre-flight idle estimate «≈N мин» (AC-1)
- after: T-6
- files: `Onset/UI/RecordingCoordinator.swift`, `Onset/UI/Main/MainViewModel.swift`, `Onset/UI/Main/MainView*.swift`
- interface:
  - consumes: `DiskSpaceMonitor.idleEstimate` (T-4), coordinator-owned provider (T-6).
  - produces: coordinator computes idle estimate (owns provider, reads off-main) from resolved plan + `config.baseOutputDirectory` (volume resolved from nearest existing ancestor — dir may not exist yet) before a session exists; on one snapshot it calls BOTH `monitor.idleEstimate` (→ «≈ N мин» headline) AND the idle `evaluate` (→ idle `DiskVerdict` for a system/output-free warning at idle per AC-3); **cadence = one-shot on main-screen appear + recompute on record initiation** (idle polling out of scope — staleness accepted); `MainViewModel` exposes the displayed value (computed/published, mirroring `recordDisabledReason:531`) — «≈ N мин» / «> 60 мин» / «оценка недоступна». Start is NOT blocked (Open Question → option A).
- acceptance:
  - Given the idle main screen appears, When shown, Then «≈ N мин» (whole minutes, `>60 мин` allowed) appears, computed by the coordinator and only displayed by `MainViewModel` (VM does not read disk synchronously). (AC-1)
  - Given a volume read failure, Then «оценка недоступна» (no false number). (AC-1)
  - Given a new record initiated, Then the estimate re-computes and any prior disk-stop state is cleared. (AC-1)
  - check: `xcodebuild test` (VM display logic with fake) + L5 screenshot of the idle estimate (T-11).

## T-8 — MenuBarExtra badge reflects warning (AC-12a)
- after: T-6
- files: `Onset/UI/MenuBar/*` (+ `MenuBarLabelMapper` if pure-mappable)
- interface:
  - consumes: coordinator `diskWarning` state (T-6, Equatable-guarded).
  - produces: MenuBarExtra label/badge reflects the warning state (behavior, not visual design); pure mapping in `MenuBarLabelMapper` where possible; no per-tick churn (state already Equatable-guarded at source).
- acceptance: Given a warning verdict during recording, When the menu-bar label is derived, Then it reflects the low-space warning; When de-escalated, Then it clears. (AC-12a)
  - check: unit test on `MenuBarLabelMapper` (pure) for warning→label mapping; L5 visual confirm (T-11).

## T-9 — Composition-root wiring (OnsetApp)
- after: T-6, T-7
- files: `Onset/OnsetApp.swift`
- interface:
  - consumes: `LiveDiskSpaceProvider` (T-2), coordinator/MainViewModel init seams.
  - produces: single `LiveDiskSpaceProvider` constructed at the composition root and injected into the coordinator (which shares it with its `MainViewModel`). **NOT threaded into `RecordingSession`** — no consumer there (pre-flight is UI-layer per AC-1; removing the dead wiring flagged in review). (M3)
- acceptance: THE SYSTEM SHALL construct exactly one `LiveDiskSpaceProvider` at `OnsetApp` and inject it into the coordinator/MainViewModel; `RecordingSession` init is NOT modified for the provider.
  - check: build green; `grep` shows a single `LiveDiskSpaceProvider(` construction site in production code; `RecordingSession` signature unchanged for disk; app launches.

## T-10 — docs/architecture.md update
- after: T-6 (types stable)
- files: `docs/architecture.md`
- acceptance: THE DOC SHALL list `DiskSpaceEstimator`, `DiskSpaceProviding`/`LiveDiskSpaceProvider`, `DiskSpaceMonitor`, `DiskSpaceWarningNotifying`/`DiskSpaceNotifier`, `DiskThresholds`/`DiskVerdict`/`ETAEstimate` in the type-level map (Russian).
  - check: doc updated in the same PR; `grep` finds the new type names.

## T-11 — L5 calibration & acceptance (AC-10) [hardware-gated]
- after: T-6, T-7, T-8, T-9
- files: — (verification; threshold edits in `RecordingConfiguration` if calibration demands)
- interface: consumes the full integrated feature on reference HW (MX Brio, signed build).
- acceptance (AC-10; closes on target Mac only, via `scripts/hw-lock.sh`):
  - Output volume routed to a size-capped APFS volume / sparse disk image with a quota (isolates from system volume); filled to the needed remainder.
  - (a) auto-stop graceful with valid files (ffprobe: moov present, durations match ± movieFragmentInterval);
  - (b) the 2GB critical margin covers BOTH terms: `finalization_bytes + (readEvery + measured_worst_XPC_latency) × max_representative_speed ≤ outputStopBytes` — i.e. detection staleness (cached verdict lags `readEvery` + near-full XPC latency, measured in (d)) PLUS real finalization time of both files. If the sum approaches 2GB at max representative bitrate, calibrate `outputStopBytes` up or `readEvery` down before merge;
  - (c) purgeable/OS behavior near-full does not break the estimate;
  - (d) **perf budget as a DELTA to a WITHOUT-baseline** (not an absolute 250ms threshold — perf-review: 250ms is orders weaker than the sub-ms design budget): run N iterations WITH vs WITHOUT disk monitoring under representative load; criteria — «no NEW hangs vs baseline» + hard on-main verdict-processing micro-budget **< 1–2 ms** (os_signpost) + a stated tolerance band on the `encoderBackpressureDrops` delta; ALSO capture provider-read latency (signpost) and confirm no async encoder-throughput degradation near-full;
  - (e) **slope SNR**: measure the −Δ free-space slope SNR at real bitrates near-full; if SNR < 1, ETA-warning is gated on slope confidence and the byte-floor is the primary stop signal (verify floor still stops correctly).
  - Divergence in any of (a)–(e) → adjust thresholds / ETA gating before merge.
  - check: L5 outputs verified with `scripts/verify-cfr.sh` + ffprobe; perf delta + signpost latencies + SNR captured; screenshots for T-7/T-8 UI. This is the L5 gate — build + unit alone do NOT close it.
