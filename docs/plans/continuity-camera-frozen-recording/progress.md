---
type: progress
slug: continuity-camera-frozen-recording
---

# Progress: фикс заморозки записи Continuity Camera (#268)

## Tasks
- [ ] T-1 — Чистый `LatencyGraceEstimator` (огибающая + пессимистичный init) + pure L2
- [ ] T-2 — Интеграция в VideoEncoder: Δ на всех кадрах до ветвления + effectiveGrace в ОБОИХ потребителях grace
- [ ] T-3 — (investigate) camera grid-fps по активированному формату
- [ ] T-4 — Observability: dup-drop эмитит DropEvent → tech-info виден (degraded-safe)
- [ ] T-5 — Encoder-уровневый регресс-тест (cold-start гонка) + observability
- [ ] T-6 — L5: iPhone Continuity live + no-regress (FaceTime built-in, Brio 4K, screen)

## Learnings
(append one line per completed task)
