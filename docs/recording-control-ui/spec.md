---
type: spec
slug: recording-control-ui
product: Onset
parent: docs/spec/overview.md
date: 2026-05-29
status: approved
platform: [desktop]
surfaces: [ui]
acceptance_criteria_ids: [AC-8, AC-19]
depends_on: [recording-session, performance-and-degradation, permissions]
provides_to: [recording-session]
---

# Feature: Recording Control UI

Управление записью при свёрнутом окне: menu bar (`NSStatusItem`), глобальный hotkey, Dock-иконка, окно во время записи, системные уведомления. Общая основа — [`docs/spec/architecture.md`](../spec/architecture.md).

## Context
Во время записи главное окно свёрнуто; индикатор и управление живут в menu bar. Запись должна быть всегда обнаружима и останавливаема несколькими способами. Уведомления доносят ошибки источника/writer'а при свёрнутом окне.

## Acceptance Criteria
- [ ] **AC-8** — Во время записи в `NSStatusItem`: прошедшее время, счётчик дропнутых кадров (с причиной), пункт Stop с key-equivalent глобального hotkey; при ненулевых дропах — заметный признак деградации (иконка/цвет + не только цвет).
- [ ] **AC-19** — Остановка ≥3 способами при свёрнутом окне: пункт Stop в menu bar, глобальный hotkey, клик по Dock-иконке (возвращает окно с активной Stop). Состояние «идёт запись» всегда обнаружимо; запись не «теряется».

## Affected Modules
| Module | Change | Notes |
|---|---|---|
| `Presentation/MenuBarController.swift` | New | `NSStatusItem`: индикатор + таймер + счётчик дропов + Stop |
| `Presentation/GlobalHotkeyService.swift` | New | глобальный hotkey остановки (Carbon `RegisterEventHotKey`) |
| `Presentation/NotificationManager.swift` | New | UserNotifications: старт/стоп/ошибки источника/writer'а |
| `Presentation/SettingsView.swift` (recording-mode) | Modified | восстановленное во время записи окно: таймер+Stop+счётчик, контролы задизейблены |

## Technical Approach
Главное окно при Record — **minimize** (не hide), чтобы Dock-клик восстанавливал. Hotkey — `RegisterEventHotKey` (без доп. TCC), default-сочетание (кандидат `⌘⌥⇧R`), показывается как key-equivalent; при конфликте регистрации — видно в настройках, остановка остаётся через menu bar + Dock. Activation policy `.regular` (Dock-иконка обязательна). Уведомления через `NotificationManager`; при запрете Notifications — fallback: признак ошибки в `NSStatusItem` до возврата в окно. Счётчик дропов читается из `performance-and-degradation` (`DroppedFrameStats`).

## Dependencies / связи с другими фичами
| Направление | Фича | Характер связи |
|---|---|---|
| depends-on | `recording-session` | состояние записи, прошедшее время, триггеры stop |
| depends-on | `performance-and-degradation` | `DroppedFrameStats` для отображения + признак деградации |
| depends-on | `permissions` | Notifications (TCC); fallback при отказе |
| provides-to | `recording-session` | команды Record/Stop (3 способа) |

## Decisions
| Decision | Choice | Rationale |
|---|---|---|
| Свёртывание окна | minimize (не hide) | Dock-клик восстанавливает (AC-19) |
| Hotkey API | Carbon `RegisterEventHotKey` | Без Input-Monitoring TCC-гейта |
| Activation policy | `.regular` | Нужна Dock-иконка для 3-го способа |

## Out of Scope
- Настройка сочетания hotkey пользователем — опционально (по умолчанию фикс с обоснованием).
- Countdown, pause/resume — вне v1.
