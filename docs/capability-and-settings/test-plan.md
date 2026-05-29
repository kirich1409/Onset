---
type: test-plan
slug: capability-and-settings
parent: docs/spec/overview.md
source_spec: docs/capability-and-settings/spec.md
date: 2026-05-29
status: draft
---

# Test Plan: Capability & Settings

Команды верификации и log-маппинг — `docs/spec/testing.md`; TC-id стабильны across feature-планов. Срез по фиче.

## Test Cases (owned)

#### TC-1 — Запуск открывает окно настроек
P0 · ui-instrumentation · Smoke · Запустить Onset → окно с секциями Экран/Камера/Микрофон/Вывод + Record. Spec §AC-1

#### TC-4 — Validator: валидная конфигурация → RecordingConfiguration
P0 · unit · Feature · Синтетический snapshot + валидные Selections → `.success`; конфиг только через Validator. Spec §AC-15

#### TC-5 — Validator: fps выше refresh авто-корректируется
P1 · unit · Feature · display maxRefresh=60, Selection fps=120 → скламплен до 60 + `ValidationIssue(.autoCorrected)`. Spec §AC-15

#### TC-6 — Validator: невозможная комбинация кодек×разрешение
P1 · unit · Feature · H.264 + 5K → отклонена/недоступна с причиной; не стартует. Spec §AC-5,16

#### TC-7 — CapabilityMatrix: неизвестный чип → консервативный fallback
P2 · unit · Feature · `ChipTier.unknown` → бюджет по P-ядрам; single-stream из probe. Spec §AC-15

#### TC-8 — Кодек по умолчанию = аппаратный HEVC
P0 · integration · Feature · `VTCopyVideoEncoderList`/probe → HW HEVC (`IsHardwareAccelerated`); не SW по умолчанию. Spec §AC-16

#### TC-18 — UI: недоступные кодек/контейнер задизейблены с причиной
P2 · ui-instrumentation · Feature · неподдерживаемая комбинация → серая + причина, не скрыта. Spec §AC-5

#### TC-19 — UI: Record активна только при ≥1 видеоисточнике
P0 · ui-instrumentation · Feature · «Без камеры»+экран выкл → Record неактивна с подсказкой; включить экран → активна. Spec §AC-6

#### TC-27 — TOCTOU: устройство исчезло между настройкой и Record
P1 · integration · Regression · отключить камеру до Record → re-validate generation, сообщение, не стартует с битым конфигом. Spec §Technical Approach, AC-2

#### TC-34 — Нет подключённых камер/микрофонов
P2 · ui-instrumentation · Feature · камера «Без камеры»+плейсхолдер, микрофон «Без звука»; экран всё ещё доступен. Spec §AC-1,6

#### TC-36 — Hotplug устройства в окне настроек
P2 · integration · Regression · подключить/отключить камеру → список обновился (generation bump). Spec §AC-2

## Shared / cross-feature TC
- **TC-16** (UI-пикеры форматов камеры) — `camera-capture`.
- **TC-2** (happy-path) — `recording-session`.

## Coverage Matrix
| AC | TC |
|---|---|
| AC-1 | TC-1, TC-34 |
| AC-2 | TC-27, TC-36 |
| AC-5 | TC-6, TC-18 |
| AC-6 | TC-19, TC-34 |
| AC-15 | TC-4, TC-5, TC-7 |
| AC-16 | TC-6, TC-8 |
