---
type: test-plan
slug: performance-and-degradation
parent: docs/spec/overview.md
source_spec: docs/performance-and-degradation/spec.md
date: 2026-05-29
status: draft
---

# Test Plan: Performance & Degradation

Команды верификации и log-маппинг — `docs/spec/testing.md`; TC-id стабильны across feature-планов. Срез по фиче.

## Test Cases (owned)

#### TC-28 — DroppedFrameStats учитывает capture-layer и consumer-layer
P1 · integration · Regression · инъекция poolExhausted (камера) + переполнение очереди (encoderBound) → оба класса учтены с причинами; ничего молча. Spec §AC-21

#### TC-29 — Аудио-путь лосслесс: backpressure видео не «обкусывает» mic
P0 · unit · Regression · переполнение видео-очереди при mic-потоке → видео drop-oldest, mic не дропнут, bit-identity цела. Spec §AC-21,9,12

#### TC-30 — Dual-stream 4K60+4K30 HEVC ≥10 мин без дропов
P0 · e2e · Acceptance (L5) · M3 Max + 4K60; pass = DroppedFrameStats==0 (capture+consumer) + Δ PTS ≤1.5×interval + нет деградации в окне + callback hold-time < `minimumFrameInterval×(queueDepth−1)`. Spec §AC-14

#### TC-37 — Адаптивная деградация под нагрузкой (отдельно от AC-14)
P1 · e2e · Acceptance (L5) · нагрузка до срабатывания ladder → шаги по триггерам (порядок камера fps→экран fps→битрейт→откл. камеры); дропы вскрыты; ratchet/cooldown без осцилляции. + unit на decider-автомат. Spec §AC-15

#### TC-39 — Memory footprint в пределах бюджета (10 мин)
P1 · e2e · Acceptance (L5) · peak footprint ≤ потолок (queueDepth×~33МБ×2+база); нет линейного роста. Spec §Technical Constraints, AC-21

#### TC-40 — 1-движковый чип: dual-stream → деградация/видимые дропы
P1 · e2e · Acceptance (L5) · base/Pro чип → срабатывает ladder ИЛИ ненулевой `DroppedFrameStats(encoderBound)` в NSStatusItem; mic bit-identity цела. Spec §sla (1-движковая ветка), AC-15,21

## Shared / cross-feature TC
- **TC-31** (sync ≤1 кадр) — `recording-session`.
- **TC-20** (отображение счётчика дропов) — `recording-control-ui`.

## Coverage Matrix
| AC | TC |
|---|---|
| AC-14 | TC-30, TC-39 |
| AC-21 | TC-28, TC-29, TC-40 (+ TC-20 display) |
| AC-15 (runtime) | TC-37, TC-40 |
