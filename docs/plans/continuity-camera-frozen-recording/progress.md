---
type: progress
slug: continuity-camera-frozen-recording
---

# Progress: фикс заморозки записи Continuity Camera (#268)

## Tasks
- [x] T-1 — Чистый `LatencyGraceEstimator` (огибающая + пессимистичный init) + pure L2
- [ ] T-2 — Интеграция в VideoEncoder: Δ на всех кадрах до ветвления + effectiveGrace в ОБОИХ потребителях grace
- [ ] T-3 — (investigate) camera grid-fps по активированному формату
- [ ] T-4 — Observability: dup-drop эмитит DropEvent → tech-info виден (degraded-safe)
- [ ] T-5 — Encoder-уровневый регресс-тест (cold-start гонка) + observability
- [ ] T-6 — L5: iPhone Continuity live + no-regress (FaceTime built-in, Brio 4K, screen)

## Learnings
- T-1: `LatencyGraceEstimator` — peak-detector (max-with-decay): fast-attack up, geometric slow-decay (factor 0.95) down, pessimistic init=ceiling(0.5s). `effectiveGrace` clamps envelope into `[max(floor, defaultGrace(fps)), ceiling]`. 4 pure L2 tests (a–d) green; lint clean.
