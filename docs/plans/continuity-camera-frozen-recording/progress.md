---
type: progress
slug: continuity-camera-frozen-recording
---

# Progress: фикс заморозки записи Continuity Camera (#268)

## Tasks
- [x] T-1 — Чистый `LatencyGraceEstimator` (огибающая + пессимистичный init) + pure L2
- [x] T-2 — Интеграция в VideoEncoder: Δ на всех кадрах до ветвления + effectiveGrace в ОБОИХ потребителях grace (+ grace-pin константный режим, ingest Δ-шов)
- [>] T-3 — (investigate) camera grid-fps по активированному формату — разбор готов (рекомендация A); ОТЛОЖЕН отдельным issue #269 (product-visible: camera-файл всех камер 60→30fps; вне scope P0-фикса заморозки)
- [x] T-4 — Observability: dup-drop эмитит DropEvent → tech-info виден (degraded-safe)
- [x] T-5 — Encoder-уровневый регресс-тест (cold-start гонка) + observability (dup→DropEvent)
- [x] T-6 — L5 COMPLETE: iPhone Continuity LIVE ✓ + no-regress FaceTime built-in / Brio 4K / screen all LIVE ✓

## Gates
- L0 build ✓ / L1 lint ✓ / L2 880 tests ✓ / finalize PASS ✓ (swarm-report/continuity-camera-frozen-recording-finalize.md)
- **L5 — CORE PROVEN, no-regress partial:**
  - **iPhone Continuity (the P0 fix): LIVE ✓** — signed build, recorded `~/Movies/Onset 2026-06-28 17.51.01/…Camera.mp4` (1920×1080 HEVC, 91s). Decoded-frame md5: **1066/1066 unique** (freeze = 1, same held buffer); mpdecimate: **2118 survivors** of ~5489 (freeze → ~1); freezedetect: **0 events**. Bug FIXED on real hardware.
  - **Screen no-regress: LIVE ✓** — same session Screen.mp4 (3024×1964): 990/1064 unique decoded (74 near-dup = static terminal regions, no sensor noise — normal). Screen is a low-latency lane through the SAME adaptive-grace + cold-start path → empirical no-regress for low-latency lanes.
  - **FaceTime built-in no-regress: LIVE ✓** — `~/Movies/Onset 2026-06-28 18.11.08/…Camera.mp4` (1920×1080@30 HEVC, 19s): decoded md5 **1279/1279 unique** → pipeline live (freeze = 1 held buffer, impossible to be unique). mpdecimate 8 + freezedetect 2 events = STATIC-SCENE artifact (no motion in frame), NOT a pipeline freeze (a real freeze = one event spanning the whole file, not 2 short ones). Note: FaceTime grid=30 (no T-3 mismatch, consistent with #269 analysis).
  - **Brio 4K no-regress: LIVE ✓** — `~/Movies/Onset 2026-06-28 18.12.51/…Camera.mp4` (**3840×2160@30** HEVC, 18s): decoded md5 **1296/1296 unique**, mpdecimate **260 survivors**, freezedetect **0**. Clean.
  - Confirmatory deep-scan items (not blockers; fix proven live at current 0.5s ceiling): #1 ceiling — Continuity recorded live at the default ceiling → adequate for real latency (numeric Δ distribution not extracted); #2 busy-spin — all recordings completed cleanly (91s Continuity, no hang) + perf-expert verified absent by construction (Instruments CPU snapshot not taken); #3 static-screen cold-start cadence — screen recorded live (dedicated static-at-start check not isolated).

## Finalize review findings → T-6 L5 must-capture (deep-scan #1-4, deferred, not code-fixed)
- **#1 ceiling calibration (PLAUSIBLE):** 0.5s ceiling may clamp grace below real Δ if latency >500ms (Wi-Fi/BT handoff) → freeze persists above cap. T-6: snapshot Δ distribution, raise `defaultCeilingSeconds` if observed max Δ approaches 0.5s. Don't guess — measure.
- **#2 Δ contamination (PLAUSIBLE):** Δ = dequeue-time − capturePTS includes actor-queue/backpressure delay, not only delivery latency → may inflate grace under backpressure, prolonging stutter. T-6: observe grace/holds under induced backpressure; potential follow-up to timestamp at stream-enqueue.
- **#3 screen-lane cold-start (PLAUSIBLE):** pessimistic ceiling applies to screen lane too (out-of-scope), delaying synthetic holds ~0.5s at session start vs ~0.067s. Already on T-6 checklist (static-screen hold cadence). Accepted (cold-start not reopened).
- **#4 DropEvent UX:** per-dup `.cfrNormalizationDrops` makes tech-info «Нормализация CFR» non-zero (was 0). Deliberate (plan decision #6); after fix dup→~0 so non-zero = real event. Watch for noise in L5.

## Learnings
- T-1: `LatencyGraceEstimator` — peak-detector (max-with-decay): fast-attack up, geometric slow-decay (factor 0.95) down, pessimistic init=ceiling(0.5s). `effectiveGrace` clamps envelope into `[max(floor, defaultGrace(fps)), ceiling]`. 4 pure L2 tests (a–d) green; lint clean.
- T-2/T-4: integrated estimator into VideoEncoder (Δ once in ingest, observe on dup@slotS≥0 + valid path, effectiveGrace in both grace consumers, DropEvent on dup-drop via shared `.cfrNormalizationDrops`). REGRESSION found: pessimistic cold-start (envelope=ceiling) broke 6 existing hold-scheduler tests that pass `grace: 0.005` expecting it as effective grace — `grace:` only set floor, envelope=ceiling overrode it. Advisor: cold-start is intended (not reopened); real defect = plan's note that `grace:` "becomes floor" preserves determinism was false. Fix: explicit `grace:` → CONSTANT estimator (seed + observe no-op); `nil` → adaptive. Verified only prod call-site (RecordingComponentFactories.swift:166) passes no grace → safe. Also adding ingest Δ-injection seam now (mirror `clockTick(nowSeconds:)`) for T-5 determinism, to avoid reshaping ingest twice.
- T-3 (investigate): activated camera fps = minCameraFps=30 (Continuity 1080p, minDur 1/30) vs grid=Int(maxFps)=60 — contract-mismatch. Recommendation A: `CapabilityResolver.swift:159` `cameraPlan.fps = min(cameraFps, config.minCameraFps)`, keep budget (cameraRateInfo/cameraDimensions) @maxFps (conservative). FaceTime built-in/Brio/screen already grid==activated → no regression. SIDE-EFFECT (product-visible, all cameras): camera file becomes real 30fps (was fake 60 = 30 real+30 holds), bitrate 1080p@60→@30, verify-cfr camera expectation → 30, doc ResolvedCameraPlan.swift:15-17 + budget-test comment-rot. Not A1 (lowering budget would flip probe_4K60 .budgetExceeded→.ok). DECISION PENDING: include in this PR (plan sequences T-3 before T-6) vs defer (independent correctness change with output-contract blast radius beyond the freeze fix).
