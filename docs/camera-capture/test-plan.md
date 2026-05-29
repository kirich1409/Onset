---
type: test-plan
slug: camera-capture
parent: docs/spec/overview.md
source_spec: docs/camera-capture/spec.md
date: 2026-05-29
status: draft
---

# Test Plan: Camera Capture

Консолидированный план — `docs/testplans/macos-screen-camera-recorder-test-plan.md` (TC-ids стабильны). Здесь — срез по фиче.

## Test Cases (owned)

#### TC-15 — Камера отдаёт только реально поддерживаемые форматы
| | |
|---|---|
| Priority | P1 | Type | integration | Tier | Feature |
| Preconditions | MX Brio подключена |
| Steps | Перечислить `device.formats` → combos |
| Expected Result | Инвариант: список = только из `device.formats`. Baseline MX Brio: {4K@30, 1080p@60, 720p@90}, 4K@60 нет |
| Source | Spec §AC-3 |

#### TC-16 — UI: пикеры разрешения/fps показывают только поддерживаемое
| | |
|---|---|
| Priority | P1 | Type | ui-instrumentation | Tier | Feature |
| Preconditions | MX Brio выбрана |
| Steps | Открыть пикеры разрешения и fps |
| Expected Result | Только {4K@30, 1080p@60, 720p@90}; невозможные отсутствуют |
| Source | Spec §AC-3 |

#### TC-17 — Превью камеры показывается/переключается/скрывается
| | |
|---|---|
| Priority | P1 | Type | ui-instrumentation | Tier | Feature |
| Preconditions | ≥1 камера + «Без камеры» |
| Steps | Выбрать камеру → сменить → «Без камеры» |
| Expected Result | Превью появилось; переключилось; при «Без камеры» скрыто/плейсхолдер |
| Source | Spec §AC-4 |

## Shared / cross-feature TC
- **TC-2** (happy-path) — `recording-session`.
- **TC-26a** (unplug камеры mid-recording → частичный camera.*, экран продолжает) — `recording-session`.
- **TC-34** (нет камер → только «Без камеры») — `capability-and-settings`.

## Coverage Matrix
| AC | TC |
|---|---|
| AC-3 | TC-15, TC-16 |
| AC-4 | TC-17 |
