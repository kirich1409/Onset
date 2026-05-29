---
type: test-plan
slug: screen-capture
parent: docs/spec/overview.md
source_spec: docs/screen-capture/spec.md
date: 2026-05-29
status: draft
---

# Test Plan: Screen Capture

Команды верификации и log-маппинг — `docs/spec/testing.md`. TC-id стабильны across feature-планов. Здесь — срез по фиче.

## Test Cases (owned)

#### TC-32 — Экран в оригинальном разрешении/fps дисплея, SDR
| | |
|---|---|
| Priority | P1 |
| Type | e2e |
| Tier | Acceptance (L5) |
| Preconditions | Внешний 4K60 |
| Steps | 1. Запись экрана. 2. Проверить свойства файла (Appendix-команды ffprobe в общем плане) |
| Expected Result | `screen.*` = 3840×2160 @ 60fps, 8-bit SDR (без HDR-метаданных) |
| Source | Spec §AC-10 |

## Shared / cross-feature TC
- **TC-2** (happy-path запись экран+камера+микрофон) — owned `recording-session`, затрагивает экран.
- **TC-3** (запись только экрана) — owned `recording-session`.
- **TC-28** (учёт capture-layer дропов, в т.ч. `SCFrameStatus` экрана) — owned `performance-and-degradation`.

## Coverage Matrix
| AC | TC |
|---|---|
| AC-10 | TC-32 (+ TC-2, TC-3 shared) |
