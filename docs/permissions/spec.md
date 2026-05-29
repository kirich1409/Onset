---
type: spec
slug: permissions
product: Onset
parent: docs/spec/overview.md
date: 2026-05-29
status: approved
platform: [desktop]
acceptance_criteria_ids: [AC-18]
depends_on: []
provides_to: [screen-capture, camera-capture, audio-capture, capability-and-settings, recording-control-ui]
---

# Feature: Permissions (TCC)

Запрос и проверка разрешений Screen Recording, Camera, Microphone, Notifications; понятные denied-состояния. Foundation-фича (ни от кого не зависит). Общая основа — [`docs/spec/architecture.md`](../spec/architecture.md).

## Context
До использования источников нужны TCC-разрешения. Уведомления несут критическую информацию при свёрнутом окне (ошибки источника/writer'а) — поэтому Notifications тоже входит, с fallback при отказе.

## Acceptance Criteria
- [ ] **AC-18** — При первом запросе приложение корректно запрашивает Screen Recording (TCC), Camera, Microphone, Notifications; при отсутствии разрешения соответствующий источник недоступен с понятной подсказкой (CTA «Открыть Системные настройки»). Если Notifications не выданы — факт ошибки/частичного отказа всё равно обнаружим: индикатор в `NSStatusItem` (fallback к AC-21/AC-8).

## Affected Modules
| Module | Change | Notes |
|---|---|---|
| `Infrastructure/Permissions/PermissionsManager.swift` | New | TCC: Screen Recording, Camera, Microphone, Notifications; статусы + запрос |

## Technical Approach
Screen Recording — диалог вызывается первым обращением к `SCShareableContent.get*` (программного запроса нет). Camera/Microphone — `AVCaptureDevice.requestAccess`; `Info.plist`: `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`. Notifications — `UNUserNotificationCenter.requestAuthorization`. Denied-состояния показываются инлайн-баннером в окне настроек с CTA. Проверка статусов до перехода `configuring→ready`. Bundle-приложение (не plain executable) — иначе Screen Recording не отображается в System Settings (macOS 26.1).

## Dependencies / связи с другими фичами
| Направление | Фича | Характер связи |
|---|---|---|
| depends-on | — | foundation, ни от кого не зависит |
| provides-to | `screen-capture` | Screen Recording |
| provides-to | `camera-capture` | Camera |
| provides-to | `audio-capture` | Microphone |
| provides-to | `capability-and-settings` | доступ для enumeration + статусы в UI |
| provides-to | `recording-control-ui` | Notifications (+ fallback при отказе) |

## Decisions
| Decision | Choice | Rationale |
|---|---|---|
| App Sandbox | По умолчанию без sandbox в v1 (прямое распространение) | Проще с правами захвата; пересмотр при публикации в App Store |
| Notifications | Запрашиваются | Канал ошибок при свёрнутом окне (с fallback в menu bar) |

## Out of Scope
- `com.apple.developer.persistent-content-capture` (захват без повторных диалогов) — вне v1.
