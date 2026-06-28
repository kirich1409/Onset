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
- [ ] T-6 — L5: iPhone Continuity live + no-regress (FaceTime built-in, Brio 4K, screen)

## Learnings
- T-1: `LatencyGraceEstimator` — peak-detector (max-with-decay): fast-attack up, geometric slow-decay (factor 0.95) down, pessimistic init=ceiling(0.5s). `effectiveGrace` clamps envelope into `[max(floor, defaultGrace(fps)), ceiling]`. 4 pure L2 tests (a–d) green; lint clean.
- T-2/T-4: integrated estimator into VideoEncoder (Δ once in ingest, observe on dup@slotS≥0 + valid path, effectiveGrace in both grace consumers, DropEvent on dup-drop via shared `.cfrNormalizationDrops`). REGRESSION found: pessimistic cold-start (envelope=ceiling) broke 6 existing hold-scheduler tests that pass `grace: 0.005` expecting it as effective grace — `grace:` only set floor, envelope=ceiling overrode it. Advisor: cold-start is intended (not reopened); real defect = plan's note that `grace:` "becomes floor" preserves determinism was false. Fix: explicit `grace:` → CONSTANT estimator (seed + observe no-op); `nil` → adaptive. Verified only prod call-site (RecordingComponentFactories.swift:166) passes no grace → safe. Also adding ingest Δ-injection seam now (mirror `clockTick(nowSeconds:)`) for T-5 determinism, to avoid reshaping ingest twice.
- T-3 (investigate): activated camera fps = minCameraFps=30 (Continuity 1080p, minDur 1/30) vs grid=Int(maxFps)=60 — contract-mismatch. Recommendation A: `CapabilityResolver.swift:159` `cameraPlan.fps = min(cameraFps, config.minCameraFps)`, keep budget (cameraRateInfo/cameraDimensions) @maxFps (conservative). FaceTime built-in/Brio/screen already grid==activated → no regression. SIDE-EFFECT (product-visible, all cameras): camera file becomes real 30fps (was fake 60 = 30 real+30 holds), bitrate 1080p@60→@30, verify-cfr camera expectation → 30, doc ResolvedCameraPlan.swift:15-17 + budget-test comment-rot. Not A1 (lowering budget would flip probe_4K60 .budgetExceeded→.ok). DECISION PENDING: include in this PR (plan sequences T-3 before T-6) vs defer (independent correctness change with output-contract blast radius beyond the freeze fix).
