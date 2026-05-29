---
type: test-plan
slug: recording-control-ui
parent: docs/spec/overview.md
source_spec: docs/recording-control-ui/spec.md
date: 2026-05-29
status: draft
---

# Test Plan: Recording Control UI

Команды верификации и log-маппинг — `docs/spec/testing.md`; TC-id стабильны across feature-планов. Срез по фиче.

## Test Cases (owned)

#### TC-20 — Menu bar: таймер, счётчик дропов, Stop + hotkey
P0 · ui-instrumentation · Feature · открыть dropdown → прошедшее время, счётчик дропов с причиной, Stop с key-equivalent; при дропах — признак деградации. Spec §AC-8

#### TC-21 — Остановка тремя способами при свёрнутом окне
P0 · ui-scenario · Feature · menu bar / hotkey / Dock-клик (возврат окна → Stop) — все останавливают и финализируют; индикатор всегда виден. Spec §AC-19

#### TC-22 — Восстановленное во время записи окно: контролы задизейблены
P2 · ui-instrumentation · Feature · окно из Dock → таймер+Stop+счётчик; конфиг-контролы disabled с пояснением. Spec §AC-19

#### TC-43 — Конфликт регистрации глобального hotkey (негатив AC-19)
P2 · ui-instrumentation · Regression · занятое сочетание → факт недоступности виден в настройках; остановка через menu bar+Dock работает. Spec §AC-19

## Shared / cross-feature TC
- **TC-38** (a11y: клавиатура+VoiceOver окна и menu bar) — `performance-and-degradation`? нет → owned здесь как UX, см. ниже.
- **TC-23** (permissions, в т.ч. Notifications) — `permissions`.

> Примечание: TC-38 (a11y) затрагивает окно настроек и menu bar — числится за `recording-control-ui`/`capability-and-settings` совместно; в консолидированном плане owned как UX-кейс.

## Coverage Matrix
| AC | TC |
|---|---|
| AC-8 | TC-20 |
| AC-19 | TC-21, TC-22, TC-43 (+ TC-38 a11y) |
