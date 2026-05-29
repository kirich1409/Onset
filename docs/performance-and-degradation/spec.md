---
type: spec
slug: performance-and-degradation
product: Onset
parent: docs/spec/overview.md
date: 2026-05-29
status: approved
platform: [desktop]
risk_areas: [perf-critical]
non_functional:
  sla: "MacBook Pro 14\" M3 Max (2 HW encode engine): 0 dropped frames в steady state при dual-stream экран 4K60 + камера 4K30 HEVC HW; на 1-движковых чипах dual-stream через деградацию, дропы вскрываются. Real-time callback не блокируется. Измерение — AC-14."
acceptance_criteria_ids: [AC-14, AC-21]
depends_on: [recording-session, screen-capture, camera-capture, audio-capture]
provides_to: [recording-session, recording-control-ui, capability-and-settings]
---

# Feature: Performance & Degradation

No-drops SLA, учёт дропов (capture+consumer), бюджет памяти, рантайм-деградация (`RuntimeHealthMonitor` + `DegradationLadder`). Общая основа — [`docs/spec/architecture.md`](../spec/architecture.md) (§ Backpressure, § Адаптивная деградация).

## Context
Гарантирует отсутствие дропов на референс-железе и честное вскрытие/деградацию при перегрузке. Поставляет `DroppedFrameStats` для UI, исполняет шаги ladder в рантайме (применяет их через `recording-session`). Также владеет encoder-probe-частью бюджета для `capability-and-settings`.

## Acceptance Criteria
- [ ] **AC-14** — На M3 Max + внешний 4K60: dual-stream 4K60+4K30 HEVC ≥10 мин **без срабатывания DegradationLadder**; после warm-up 2 c суммарные `DroppedFrameStats` (capture+consumer) == 0; PTS-непрерывность без пропусков (Δ ≤ 1.5× интервала); max время удержания в capture-callback < `minimumFrameInterval×(queueDepth−1)`.
- [ ] **AC-21** — Дропы видео никогда не теряются молча: учитываются capture-layer (`didDrop`/`SCFrameStatus`) и consumer-layer (переполнение очереди/`!isReadyForMoreMediaData`/disk-stall) с причинами; счётчик виден во время и после записи. Disk-stall ≠ отказ тома (AC-17). Аудио-путь микрофона лосслесс (drop-oldest не применяется).

> **AC-15 (рантайм-часть):** исполнение `DegradationLadder` по измеримым триггерам — здесь; валидация до старта — в `capability-and-settings`.

## Affected Modules
| Module | Change | Notes |
|---|---|---|
| `Application/RuntimeHealthMonitor.swift` | New | поллинг `thermalState`, чтение `DroppedFrameStats`/memory watermark; предлагает шаги ladder Coordinator'у |
| `Domain/Capability.swift` (`DegradationLadder`, `DroppedFrameStats`) | Shared | типы ladder + per-source atomic-счётчики |
| `Infrastructure/Capability/CapabilityMatrix.swift` | Shared | encoder-бюджет (MJPEG-decode член) |

## Technical Approach
`DroppedFrameStats` — per-source atomic-счётчики, инкремент на hot path (capture-layer + consumer-layer), чтение монитором и ViewModel. `RuntimeHealthMonitor` (control plane) триггерит ladder: вниз при дропы>N/окно T или `thermalState>=.serious` или memory watermark; вверх после cooldown C при чистом окне; ratchet против осцилляции (детали — architecture). `DegradationLadder` — чистый decider-автомат (unit-тестируется без железа). Backpressure-контракт и lossless-audio — architecture § Backpressure.

## Dependencies / связи с другими фичами
| Направление | Фича | Характер связи |
|---|---|---|
| depends-on | `recording-session` | применяет шаги ladder к writers/sources; читает health |
| depends-on | `screen/camera/audio-capture` | источники дропов (capture-layer сигналы) |
| provides-to | `recording-session` | решение о деградации |
| provides-to | `recording-control-ui` | `DroppedFrameStats` + признак деградации для UI |
| provides-to | `capability-and-settings` | encoder-probe / `CapabilityMatrix` бюджет для Validator |

## Decisions
| Decision | Choice | Rationale |
|---|---|---|
| Деградация | Динамическая (monitor+ladder с гистерезисом) | «Дропы не молча»; статик-отказ ухудшает UX длинных записей |
| ladder-шаги | Только динамически-принимаемые (fps/битрейт/откл. камеры) | Смена output-разрешения требует нового сегмента — вне ladder v1 |
| Аудио | Лосслесс (без drop-oldest) | bit-identity (AC-9/12) |

## Out of Scope
- Смена выходного разрешения mid-recording (новый сегмент) — вне v1.
