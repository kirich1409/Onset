---
type: test-plan
slug: permissions
parent: docs/spec/overview.md
source_spec: docs/permissions/spec.md
date: 2026-05-29
status: draft
---

# Test Plan: Permissions

Консолидированный план — `docs/testplans/macos-screen-camera-recorder-test-plan.md`. Срез по фиче.

## Test Cases (owned)

#### TC-23 — Разрешения TCC запрашиваются; denied-состояния понятны
| | |
|---|---|
| Priority | P1 | Type | ui-scenario | Tier | Feature |
| Preconditions | Чистый TCC: `tccutil reset ScreenCapture <bundle-id>` + `tccutil reset Camera <bundle-id>` + `tccutil reset Microphone <bundle-id>` (app-specific, без sudo); либо отдельный тестовый аккаунт |
| Steps | 1. Первый запуск → запросы Screen Recording, Camera, Microphone, Notifications. 2. Отклонить камеру |
| Expected Result | Запросы показаны; при отказе камеры источник недоступен с CTA «Открыть Системные настройки»; при отказе Notifications ошибки всё равно видны в `NSStatusItem` (fallback) |
| Source | Spec §AC-18 |

## Coverage Matrix
| AC | TC |
|---|---|
| AC-18 | TC-23 |
