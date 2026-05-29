---
type: spec
slug: screen-capture
product: Onset
parent: docs/spec/overview.md
date: 2026-05-29
status: approved
platform: [desktop]
acceptance_criteria_ids: [AC-10]
depends_on: [capability-and-settings, recording-session, permissions]
provides_to: [recording-session, performance-and-degradation]
---

# Feature: Screen Capture

Захват **всего выбранного дисплея** через ScreenCaptureKit в оригинальном разрешении/fps, SDR-пайплайн. Общая основа — [`docs/spec/architecture.md`](../spec/architecture.md).

## Context
Источник видео экрана для записи. MVP — только весь дисплей (область/окно — Phase 2). Отдаёт timestamped `CMSampleBuffer` в `recording-session` через `SampleSink`. SDR, без HDR.

## Acceptance Criteria
- [ ] **AC-10** — Запись экрана идёт в оригинальном разрешении выбранного дисплея (`captureResolution = .best`) с целевым FPS (`minimumFrameInterval`), не превышающим refresh дисплея. SDR-пайплайн: 8-битный pixelFormat, без HDR/`captureDynamicRange`.

## Affected Modules
| Module | Change | Notes |
|---|---|---|
| `Infrastructure/Capture/ScreenCaptureSource.swift` | New | `SCStream` + `SCStreamConfiguration` + `SCContentFilter(display:excludingWindows:)`; реализует `CaptureSource` |

## Technical Approach
`SCContentFilter` для всего дисплея; `SCStreamConfiguration`: `captureResolution = .best`, `width/height` = нативный пиксельный размер, `minimumFrameInterval = CMTime(1, fps)` (≤ `NSScreen.maximumFramesPerSecond`), 8-битный pixelFormat (`32BGRA`/`420v`), без `captureDynamicRange`, `queueDepth` 5–6. Callback на `com.app.capture.screen`, только retain/enqueue (см. architecture § hot path). Capture-layer дропы экрана учитываются через `SCFrameStatus` в attachments (см. `performance-and-degradation`).

## Dependencies / связи с другими фичами
| Направление | Фича | Характер связи |
|---|---|---|
| depends-on | `capability-and-settings` | получает resolved конфиг: какой дисплей, разрешение, fps |
| depends-on | `permissions` | требует Screen Recording (TCC); без него источник недоступен |
| depends-on | `recording-session` | эмитит `CMSampleBuffer` в его `SampleSink`; T/старт задаёт координатор |
| depends-on | `docs/spec/architecture.md` | host-clock шкала, hot-path правила |
| provides-to | `recording-session` | видеопоток экрана |
| provides-to | `performance-and-degradation` | источник capture-layer дропов + цель деградации (fps/downscale-input) |

## Decisions
| Decision | Choice | Rationale |
|---|---|---|
| Режим захвата | Весь дисплей | Область/окно → Phase 2 |
| Динамический диапазон | SDR (8-bit) | Референс SDR; HDR вне v1 |

## Out of Scope
- Область (`sourceRect`) и окно (`desktopIndependentWindow`) — Phase 2.
- HDR/10-bit, несколько дисплеев одновременно — вне v1.
