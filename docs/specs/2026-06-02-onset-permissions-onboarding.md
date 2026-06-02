---
type: spec
slug: onset-permissions-onboarding
date: 2026-06-02
status: approved
platform: [desktop]
surfaces: [ui]
risk_areas: [pii]
non_functional:
  sla:
  a11y:
acceptance_criteria_ids: [AC-1, AC-2, AC-3, AC-4, AC-5, AC-6, AC-7, AC-8, AC-9]
design:
  figma:
  design_system: docs/design-ref/request-permissions/
---

# Spec: Onset — Permissions & Onboarding

Date: 2026-06-02
Status: approved
Slug: onset-permissions-onboarding

---

## Context and Motivation

Onset не может записывать без трёх TCC-разрешений macOS: **Запись экрана**, **Камера**, **Микрофон**. Онбординг — первое, что видит пользователь, и он должен довести до состояния «всё готово» без чтения документации, корректно обработав главную ловушку macOS: разрешение на запись экрана **нельзя** получить системным prompt'ом (только через System Settings) и оно **требует перезапуска приложения**. Источник истины UI — макеты `docs/design-ref/request-permissions/`. Часть продукта — см. [`onset-product-overview`](2026-06-02-onset-product-overview.md).

## Acceptance Criteria

- [ ] **AC-1** — При первом запуске (или когда не выданы все три разрешения) показывается окно онбординга: заголовок «Onset нужны разрешения», подпись «Onset один раз попросит доступ… Данные никуда не отправляются», три карточки (Запись экрана / Камера / Микрофон) с индивидуальными статусами и прогресс «N из 3».
- [ ] **AC-2** — Камера и Микрофон запрашиваются нативным системным prompt'ом по кнопке «Разрешить» (через `AVCaptureDevice.requestAccess`); по выдаче карточка переходит в статус ✓ без перезапуска.
- [ ] **AC-3** — Для записи экрана кнопка «Открыть настройки» открывает именно раздел System Settings → Конфиденциальность → Запись экрана; в карточке показана пронумерованная инструкция (1-2-3).
- [ ] **AC-4** — После включения тумблера Onset в System Settings статус записи экрана определяется **автоматически** (polling), без ручного возврата в приложение; карточка из «Ожидание…» переходит в ✓.
- [ ] **AC-5** — Доступ к записи экрана вступает в силу только после перезапуска процесса (особенность TCC). После обнаружения выданного доступа Onset перезапускает себя, передавая **одноразовый transient launch-argument** (напр. `--post-screen-grant`). Роутинг после старта: при наличии arg **И** подтверждённом доступе (preflight == true) → экран «Всё готово» один раз; при наличии arg, но доступ ещё не виден (preflight == false) → роутинг по фактическим статусам (Ожидание/Запрещён), без повторного перезапуска (анти-петля); без arg → по статусам. Persisted-флага «онбординг пройден» нет. После перезапуска не должно появляться повторного системного prompt / Gatekeeper-диалога.
- [ ] **AC-6** — Если запись экрана **отклонена** (denied): показывается красный баннер «Доступ к записи экрана запрещён… можно записывать только камеру и звук», карточка со статусом «Запрещён» и единственным путём «Открыть настройки» + ручная инструкция (системный prompt больше не появляется); доступна опция «Продолжить без экрана».
- [ ] **AC-7** — Graceful-варианты работают: «Продолжить без экрана» → переход к записи только камеры + звука; «Записать без звука» (микрофон не выдан) → переход к записи без аудио-дорожки. Кнопка перехода к записи активна при наличии достаточного подмножества разрешений.
- [ ] **AC-8** — Когда все три разрешения выданы: экран «Всё готово · 3 из 3 · все разрешения активны», и онбординг **больше не показывается** при последующих запусках — приложение открывается сразу на главном экране записи.
- [ ] **AC-9** — Повторный запуск при уже выданных разрешениях: онбординг пропускается полностью (≤ один кадр проверки статусов), сразу главный экран.

**Authoritative definition of done.** Реализующий агент валидирует против этого списка.

## Prerequisites

| Prerequisite | Status | Owner | Notes |
|--------------|--------|-------|-------|
| `NSCameraUsageDescription` в Info.plist | ⬜ Todo | Agent | Текст: зачем камера (показывается в системном prompt) |
| `NSMicrophoneUsageDescription` в Info.plist | ⬜ Todo | Agent | Текст: зачем микрофон |
| Hardened Runtime entitlements: camera, microphone (screen capture — через TCC) | ⬜ Todo | Agent | Developer ID, **без App Sandbox** (решено в overview); relaunch и `~/Movies` работают без sandbox-ограничений |

## Affected Modules and Files

| Module / File | Change type | Notes |
|---------------|-------------|-------|
| `Permissions/PermissionsService` | New | Источник истины по трём разрешениям: статусы, запрос, polling-детект |
| `Permissions/PermissionStatus` | New | enum: `notDetermined / authorized / denied / restricted` (+ для экрана: `awaitingRestart`) |
| `Permissions/ScreenRecordingPermission` | New | `CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()`; deep-link в Settings; polling |
| `Permissions/CaptureDevicePermission` | New | `AVCaptureDevice.authorizationStatus(for:)` / `requestAccess(for:)` для `.video` и `.audio` |
| `UI/Onboarding/OnboardingView` | New | Окно онбординга, карточки, прогресс, baner, graceful-кнопки (по макетам) |
| `UI/Onboarding/OnboardingViewModel` | New | Состояние онбординга, реакция на изменения PermissionsService |
| `OnsetApp` | Modified | Маршрутизация при старте: онбординг vs главный экран по статусам |
| App relaunch helper | New | Перезапуск процесса после выдачи screen recording |

Key integration points:
- `PermissionsService.allGranted` / `effectivePermissions` → роутинг старта приложения и доступность режимов записи (см. [`onset-recording-mvp`](2026-06-02-onset-recording-mvp.md)).

## Technical Approach

**Модель разрешений.** Три независимых разрешения, каждое со статусом. Камера и Микрофон одинаковы (AVFoundation TCC); Запись экрана — особый случай.

**Камера / Микрофон:**
- Статус: `AVCaptureDevice.authorizationStatus(for: .video|.audio)`.
- Запрос: `AVCaptureDevice.requestAccess(for:)` (системный prompt, один раз; после denied — только Settings, prompt не повторяется).
- При `denied` — кнопка «Открыть настройки» (deep-link в соответствующий раздел Privacy).

**Запись экрана (главная ловушка macOS):**
- Статус: `CGPreflightScreenCaptureAccess()` (Bool) — без побочных эффектов.
- Первичный запрос: `CGRequestScreenCaptureAccess()` — единожды может показать системный prompt; при denied больше не показывает.
- Нет prompt-flow как у AVFoundation: основной путь — направить в System Settings и **детектить включение поллингом**.
- Deep-link: `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture` (через `NSWorkspace.open`).
- **Перезапуск обязателен**: доступ к захвату экрана вступает в силу только после перезапуска процесса (известная особенность TCC ScreenCapture). После того как polling обнаружил `CGPreflightScreenCaptureAccess() == true`, приложение перезапускает себя (макет: «приложение перезапустится само»).

**Авто-детект (polling).** Пока онбординг открыт и ждёт разрешение экрана — периодический опрос (`CGPreflightScreenCaptureAccess()` + `authorizationStatus`) с разумным интервалом (напр. 1 c) или по `NSApplication.didBecomeActiveNotification` при возврате фокуса. Карточка показывает «Ожидание…». Без ручного «Проверить снова», но кнопка «Проверить снова» доступна как явный триггер.

**Состояния карточки:** `Требуется` (notDetermined) · `Ожидание…` (запрос идёт / ждём Settings) · `Запрещён` (denied) · `✓` (authorized). Прогресс «N из 3» = число authorized. Пока висит системный prompt камеры/микрофона — кнопка «Разрешить» в состоянии disabled/loading (защита от повторного нажатия), карточка в `Ожидание…`.

**Кнопка «Позже» (на стартовом экране 0/3).** Ведёт на главный экран без выдачи разрешений. Поскольку по graceful-правилу запись невозможна без хотя бы одного видео-источника, главный экран в этом состоянии показывает заблокированный/пустой вид с явным сообщением «Запись недоступна — выдайте разрешения» и кнопкой возврата в онбординг (контракт пустого состояния — в [`onset-recording-mvp`](2026-06-02-onset-recording-mvp.md), таблица состояний источников).

**Graceful degradation (effective permissions).** Запись возможна с подмножеством:
- Нет экрана → только камера + (микрофон) — «Продолжить без экрана».
- Нет микрофона → запись без аудио — «Записать без звука».
- Нет камеры → только экран.
- Нет ни экрана, ни камеры → запись невозможна, переход к записи заблокирован.

**Роутинг старта.** Развести два понятия:
- **Persisted-флага «онбординг пройден» НЕТ** — обычный роутинг всегда по фактическим статусам: все три authorized → главный экран; иначе → онбординг (отзыв разрешения в Settings возвращает онбординг).
- **Transient launch-reason** — relaunch-helper передаёт перезапущенному процессу одноразовый launch-argument `--post-screen-grant`. Если он присутствует → показать экран «Всё готово» один раз (затем «Перейти к записи»); аргумент не персистится. Это снимает противоречие «status-only роутинг ведёт на главный экран, а не на Всё готово» после авто-перезапуска (AC-5).

**Механизм авто-перезапуска (решено: Developer ID, без App Sandbox).** Relaunch запускает **ровно ту же подписанную бандл-копию** (`Bundle.main.bundlePath`) через `NSWorkspace.openApplication` / `Process`, затем текущий процесс завершается. Защита от relaunch-петли: перед перезапуском в `UserDefaults` ставится флаг `pendingScreenGrantRelaunch`; после старта с `--post-screen-grant` он очищается, и повторный relaunch не запускается, даже если preflight ещё false (тогда показывается состояние «Запрещён»/«Ожидание», не цикл). Поскольку та же нотаризованная копия — повторного Gatekeeper-prompt быть не должно.

**Ошибки/edge.** Отзыв разрешения во время работы приложения → отразить в статусах; повторный вход в онбординг при следующем запуске или немедленно, если запись невозможна.

## Technical Constraints

- API: `CoreGraphics` (`CGPreflightScreenCaptureAccess`/`CGRequestScreenCaptureAccess`), `AVFoundation` (`AVCaptureDevice` auth), `AppKit`/`NSWorkspace` (deep-link, relaunch). UI — SwiftUI.
- Логирование статусов разрешений — `os.Logger`; **не логировать** имена устройств как PII без необходимости.
- Не вызывать `CGRequestScreenCaptureAccess()` повторно в цикле (prompt появляется максимум раз) — основной путь через Settings + polling.
- Polling-интервал разумный (не чаще 1 c), останавливать когда онбординг закрыт.
- Перезапуск процесса — только после явного обнаружения выданного screen-доступа; сохранить пользовательский контекст (вернуться на «Всё готово»).

## Decisions Made

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Детект включения screen recording | Polling `CGPreflightScreenCaptureAccess()` + кнопка «Проверить снова» | Системного callback нет; макет обещает «статус обновится сам» |
| Перезапуск после screen-доступа | Авто-перезапуск приложения | TCC ScreenCapture требует перезапуск процесса; макет это обещает |
| Камера/микрофон | Нативный `requestAccess` prompt | Стандартный TCC-путь для AVFoundation |
| Запись без полного набора | Разрешена с подмножеством (graceful) | Макеты «Продолжить без экрана» / «Записать без звука» |
| Повторный показ онбординга | По фактическим статусам, без «пройдено»-флага | Отзыв разрешения в Settings должен возвращать онбординг |

## Out of Scope

- Локализация текстов онбординга (MVP — русский, как в макетах) — *(target: позже)*
- Объяснительные экраны/туры сверх карточек разрешений — *(не планируется)*
- Хранение истории отказов / аналитика разрешений — *(out)*

## Open Questions

- [ ] Требуется ли перезапуск процесса под ScreenCaptureKit на macOS 26.x именно для уже-запущенного приложения — *non-blocking, implementation-time*
  - Recommendation: подтвердить по release notes/поведению на этапе реализации; механизм relaunch (та же подписанная копия + transient arg + анти-петля) уже специфицирован и применяется при положительном результате preflight
- [ ] Поведение при отзыве разрешения во время записи (не на старте) — *non-blocking*
  - Recommendation: остановить затронутый поток, финализировать его файл валидным; см. AC в [`onset-recording-mvp`](2026-06-02-onset-recording-mvp.md)

## Future Phases

Расширения онбординга (если потребуются) специфицируются отдельно; ядро TCC-flow стабильно.
