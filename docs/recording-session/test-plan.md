---
type: test-plan
slug: recording-session
parent: docs/spec/overview.md
source_spec: docs/recording-session/spec.md
date: 2026-05-29
status: draft
---

# Test Plan: Recording Session

Консолидированный план — `docs/testplans/macos-screen-camera-recorder-test-plan.md`. Срез по фиче.

## Test Cases (owned)

#### TC-2 — Полный happy-path (экран + камера + микрофон)
P0 · ui-scenario · Smoke · configure→Record→~15c→Stop (menu bar) → папка `Recording <ts>/` с `screen.mov`+`camera.mov`, воспроизводятся. Spec §AC-7,11

#### TC-3 — Запись только экрана
P0 · ui-scenario · Smoke · «Без камеры/звука», экран → Record 10c → Stop → только `screen.mov`. Spec §AC-6,11

#### TC-11 — Атомарный старт: PTS<T отбрасываются
P0 · unit · Feature · fake writer; буферы до/после T → записаны только PTS≥T. Spec §AC-7

#### TC-12 — Warm-up: T после first-sample всех источников
P0 · unit · Feature · источники с разной задержкой → T после первого буфера каждого; нет «дыры». Spec §AC-7,12

#### TC-24 — Отказ writer'а: isolateAndContinue
P0 · integration · Regression · инъекция ошибки writer'а экрана → `screen.*` частичный, `camera.*` продолжает, уведомление (`writer.failure`). Spec §AC-17

#### TC-25 — SampleRouter прекращает fan-out в мёртвый writer (lock-free)
P0 · unit · Regression · `isAlive=false` → router шлёт только в живой; без блокировки/actor-хопа. Spec §AC-17,20

#### TC-26a — Unplug камеры (экран+камера): камера частична, экран продолжает
P0 · ui-scenario · Regression · отключить USB-камеру ~30c → `camera.*` частичен (читается), `screen.*` продолжил, уведомление, лог `source.failure`. Spec §AC-20

#### TC-26b — Unplug единственного видеоисточника → финализация в error
P0 · ui-scenario · Regression · запись только камеры → unplug → `camera.*` сохранён частичным, состояние `error`. Spec §AC-20

#### TC-31 — Синхронизация ≤1 кадр (объективно по audio-хешу)
P0 · integration · Acceptance (L5) · извлечь mic-дорожки обоих файлов → SHA-256 совпадают; старт-PTS на host-шкале; ≤1 кадр. Spec §AC-12,9

#### TC-35 — Папка вывода стала недоступной
P2 · integration · Regression · read-only папка → Record → понятная ошибка до старта, не стартует. Spec §AC-11,17

#### TC-41 — Force-quit mid-recording: файлы читаемы
P1 · ui-scenario · Regression · Force Quit во время записи → файлы открываются (могут быть обрезаны, не corrupted); иначе вопрос `movieFragmentInterval`. [inferred]

#### TC-42 — Сон/пробуждение системы mid-recording
P2 · ui-scenario · Regression · sleep → wake 30c → Stop → корректное продолжение или graceful-финал, без молчаливой потери. [inferred]

## Shared / cross-feature TC
- **TC-27** (TOCTOU re-validate) — `capability-and-settings`.
- **TC-30** (no-drops SLA), **TC-39** (memory) — `performance-and-degradation` (валидируют пайплайн записи).

## Coverage Matrix
| AC | TC |
|---|---|
| AC-7 | TC-2, TC-11, TC-12 |
| AC-11 | TC-2, TC-3, TC-35 |
| AC-12 | TC-12, TC-31 |
| AC-17 | TC-24, TC-25, TC-35 |
| AC-20 | TC-25, TC-26a, TC-26b |
