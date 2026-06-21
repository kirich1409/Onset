---
type: plan
slug: recording-menubar-indicator
date: 2026-06-20
status: approved
spec: docs/specs/2026-06-02-onset-recording-mvp.md
risk_areas: []
review_verdict: conditional
review_blockers: []
---

# Plan: Запись в фоне — menu-bar-first (старт без окна, окно таймера по требованию)

## Context & Decision

Решение принято (issue #242 + research `swarm-report/research/research-recording-menubar-indicator.md`,
Approach 1). Сейчас старт записи открывает окно таймера, которое перекрывает записываемый
контент, а закрытие окна останавливает запись. Нужно menu-bar-first поведение: старт не
открывает окно (приложение уходит в `.idle` — только menu bar с индикатором и таймером),
окно таймера открывается по требованию из menu bar, закрытие окна запись не останавливает.
Это совпадает с индустриальным стандартом для фоновых macOS-рекордеров и реализуется малым
diff'ом в существующую архитектуру (`RecordingCoordinator` — единственный владелец состояния;
фаза `.idle` уже = «только menu bar»; пункт menu bar «Открыть окно записи» уже существует).

## Technical Approach

Изменение разрывает две точки связи окна с жизненным циклом записи и оставляет всю остальную
оркестровку нетронутой.

1. **Старт не открывает окно.** В `RecordingCoordinator.activateRecording()`
   (`Onset/UI/RecordingCoordinator.swift:493-516`) сейчас в конце вызывается
   `self.dismissMainWindow()` (стр. 514) + `self.openRecordingWindow()` (стр. 515). Убрать
   вызов `openRecordingWindow()`; `dismissMainWindow()` остаётся (главное окно прячется).
   После старта при `origin == .main` главное окно скрыто и ничего не открывается → только
   menu bar. Сама фаза `.recording` ставится как и раньше (стр. 504); индикатор menu bar
   (`MenuBarLabelMapper`, `Onset/UI/MenuBar/MenuBarLabel*.swift`) уже реагирует на `.recording`
   и показывает red/yellow dot + таймер.

2. **Закрытие окна не останавливает запись.** В `RecordingView`
   (`Onset/UI/Recording/RecordingView.swift:55-60`) `.onDisappear` при `phase == .recording`
   вызывает `coordinator.stop()`. Убрать этот блок. Тогда закрытие окна таймера красной
   кнопкой лишь **скрывает** окно (запись идёт) — это намеренная смена семантики красной
   кнопки заголовка с «закрыть = остановить» на «закрыть = убрать с глаз». Обновить
   doc-comment `RecordingView` (который сейчас документирует перехват закрытия через
   `.onDisappear`) под новое поведение. Best-effort комментарий про Cmd-Q (стр. 50-54)
   переписать честно: удаление этой связи **уменьшает** покрытие graceful-финализации —
   правильную финализацию при завершении приложения ведёт **#243** (прежняя ссылка на #38
   устарела: #38 закрыт и про MenuBarController). Стек захвата окна — см. Risks (#244).

3. **Окно по требованию — уже есть.** Пункт menu bar «Открыть окно записи» в
   `MenuBarMenu.swift:99-102` уже вызывает `openWindow(id: WindowID.recording)` +
   `AppActivation.bringToFront()`. Окно объявлено `.defaultLaunchBehavior(.suppressed)`
   (`OnsetApp.swift:117-128`) — на старте не презентуется. По Apple-докам `openWindow(id:)`
   на `Window` поднимает существующее окно на передний план, повторных копий не плодит, и
   закрытие вторичного `Window` приложение не завершает. Новый код для on-demand открытия не
   нужен.

4. **Остановка — без изменений.** Три пути stop() (кнопка в окне `RecordingView:39-42`,
   хоткей ⌘⌥⌃R, menu bar «Остановить» `MenuBarMenu:91-98`) сходятся в `stop()`
   (`RecordingCoordinator.swift:629-703`). Постостановочная хореография (стр. 688
   `dismissRecordingWindow()` + возврат по `origin` 689-703) остаётся как есть.

5. **Seam `openRecordingWindow` сохраняется, но координатор окном записи больше не управляет.**
   On-demand открытие идёт **напрямую** `openWindow(id: WindowID.recording)` в
   `MenuBarMenu.swift:100`, минуя seam координатора. После удаления вызова на стр. 515 у
   замыкания `openRecordingWindow` (биндится `OnsetApp.swift:162-173`, объявляется в
   `bindWindowActions` `RecordingCoordinator.swift:343-353`) ноль prod-потребителей
   (`ast-index usages` = 0) — оно выживает только как тест-spy. Намеренно НЕ удаляем
   (минимальный diff; упрощает правку теста). Явно фиксируем смену контракта: **открытие
   окна записи теперь принадлежит menu bar, не координатору** (см. Decisions).

6. **Доступность и обнаружимость остановки.** Поскольку `MenuBarExtra` становится
   единственной всегда-доступной поверхностью во время записи: (а) пункт menu bar
   «Остановить» получает `.keyboardShortcut` ⌘⌥⌃R (совпадает с глобальным хоткеем) — macOS
   отрисует комбинацию в меню, обучая пользователя; (б) accessibility label индикатора
   (`MenuBarLabel`) озвучивает состояние для VoiceOver («Onset, идёт запись, 04:17» /
   «…запись деградирована…»), а не только строку таймера.

8. **Transient-подтверждение старта (выбор пользователя — вариант B).** При старте записи
   постить локальное уведомление «Запись началась • Остановить: ⌘⌥⌃R или меню Onset» через
   `UNUserNotificationCenter` — явное подтверждение старта + обучение хоткею, без постоянного
   окна и без попадания в запись. Авторизация (`requestAuthorization(options: [.alert, .sound?])`)
   запрашивается один раз (лениво при первом старте либо в существующем permissions-флоу —
   согласовать с `PermissionsService`, не плодить второй флоу). Нотификатор — тонкий impure-сервис
   за протоколом (DI-seam, `Fake*` в тестах), вызывается из `activateRecording` (там же, где
   удалён `openRecordingWindow`). Если разрешение не выдано — **fallback на индикатор menu bar**
   (вариант A), без ошибки. Локальное уведомление не нарушает no-network инвариант.

7. **State restoration окна записи.** `.defaultLaunchBehavior(.suppressed)` управляет
   первичной презентацией, но macOS State Restoration может восстановить ранее открытое
   окно записи после перезапуска — что в фазе `.idle` покажет устаревший `RecordingView`.
   Проверить эмпирически в L5 (relaunch после того, как окно записи было открыто); при
   подтверждении — добавить `.restorationBehavior(.disabled)` на сцену окна записи.

## Affected Modules & Files

| Path | Change | Note |
|---|---|---|
| `Onset/UI/RecordingCoordinator.swift` | Modified | Удалить `self.openRecordingWindow()` (стр. 515); обновить комментарий window-choreography (AC-3); вызвать start-notifier из `activateRecording` |
| `Onset/Permissions/` или `Onset/UI/` (новый) | New | `RecordingStartNotifier` (протокол + impure-реализация на `UNUserNotificationCenter`): авторизация (once) + пост уведомления старта; `Fake*` в тестах |
| `Onset/UI/Recording/RecordingView.swift` | Modified | Удалить `.onDisappear`→`stop()` (стр. 55-60); обновить doc-comment (красная кнопка = скрыть, не стоп); переписать Cmd-Q комментарий (#38 → #243) |
| `Onset/UI/MenuBar/MenuBarMenu.swift` | Modified | Добавить `.keyboardShortcut` ⌘⌥⌃R пункту «Остановить» |
| `Onset/UI/MenuBar/MenuBarLabel*.swift` | Modified | Accessibility label индикатора озвучивает состояние записи (VoiceOver) |
| `OnsetTests/RecordingCoordinatorTests.swift` | Modified | `start_transitionsToRecording()` (стр. 283/304): ассерт «окно открыто на старте» → «окно НЕ открыто», обновить failure-message и doc-comment теста (только разрыв №1 юнит-тестируем; разрыв №2 — L5-only) |
| `docs/specs/2026-06-02-onset-recording-mvp.md` | Modified | AC-3 (стр. 34) и раздел «Окна и menu bar» (стр. 178-184): старт не открывает окно; окно по требованию; закрытие не останавливает |
| `docs/architecture.md` | Modified | Обновить описание оконного жизненного цикла записи (menu-bar-first) |

## Decisions Made

| Decision | Rationale | Alternatives rejected |
|---|---|---|
| Удалить только вызов `openRecordingWindow()` на старте, не трогая `dismissMainWindow()` | Главное окно должно скрываться, окно записи — не появляться; минимальный diff | Открывать маленький плавающий HUD на старте — противоречит требованию «никакого окна», дороже |
| Удалить `.onDisappear`→`stop()`; остановка только через явные 3 пути | Закрытие окна = «убрать с глаз», не «остановить»; durable-поверхности (menu bar/хоткей) держат stop | Гейтить onDisappear по флагу «пользователь подтвердил» — лишняя логика, не нужна |
| Исключение on-demand окна из захвата — НЕ в этом issue | Стабильность (приоритет #1): динамический `SCStream.updateContentFilter` на живом стриме — риск; окно появляется только по явному действию пользователя; ядро проблемы (окно на старте) решено | Сразу делать exclude через `SCContentFilter(excludingWindows:)` — расширяет scope и L5-риск |
| Сохранить seam `openRecordingWindow` (не удалять), зафиксировав смену контракта | Минимальный diff; тесты используют его как spy. Контракт: окно записи открывает menu bar напрямую, координатор им не управляет | Удалить closure + параметр `bindWindowActions` — churn в OnsetApp + тестах ради косметики |
| Финализацию при Cmd-Q классифицировать как осознанную регрессию, вынести в #243 (новый), не в #38 | #38 закрыт и про MenuBarController; митигация — fragment-recovery (AC-10); правильное решение (`applicationWillTerminate` await-stop) — отдельная работа #243 | Чинить прямо здесь — расширяет scope #242 (UX-изменение тащит data-loss-фикс); молча оставить «без изменений» — ложь в риск-таблице |
| ⌘⌥⌃R как `.keyboardShortcut` пункта «Остановить» | menu bar — единственная всегда-доступная поверхность; macOS отрисует хоткей, обучая пользователю | Оставить без хоткея — пользователь, не открывавший окно, не узнает о ⌘⌥⌃R |
| Подтверждение старта — transient `UNUserNotification` (выбор пользователя, вариант B) | Явное подтверждение «запись пошла» + обучение хоткею без окна; защищает от сценария «выглядит как краш» | Полагаться только на индикатор (вариант A) — пользователь отклонил; HUD-окно — попадает в запись |
| При отказе в notification-разрешении — fallback на индикатор menu bar | Запись не должна зависеть от уведомлений; деградация молчаливая, не блокирующая | Блокировать старт без разрешения — недопустимо для core-функции |
| `NSWindow.sharingType = .none` не использовать | Apple помечает legacy: «Don't use this value to hide or omit content from being captured» | — |

## Risks & Mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| **Регрессия финализации при завершении приложения (graceful Cmd-Q)** — раньше окно всегда было открыто → `onDisappear`→`stop()` всегда взведён; теперь обоих путей нет → graceful-выход уходит в recovery-only без `stop()` | **major** | Осознанная, принятая деградация: митигирована fragment-recovery `movieFragmentInterval` (AC-10, файл восстановим); правильное решение (best-effort stop в `applicationWillTerminate`) — **#243**. Cmd-Q комментарий в `RecordingView` переписать честно (не «без изменений») |
| Дискаверабилити остановки — пользователь не знает, как остановить без окна | minor | Системный индикатор macOS 26 + app-овый индикатор menu bar (red dot+таймер появляется сразу) + 3 пути stop; ⌘⌥⌃R как `.keyboardShortcut` пункта «Остановить» (виден в меню) |
| On-demand окно таймера, открытое во время записи, попадает в запись, если перекрывает дисплей | minor | Out of scope; окно только по явному действию; follow-up **#244** (`SCContentFilter(excludingWindows:)`, стек уже ScreenCaptureKit). Частичность зафиксирована: старт чист, ручное открытие — нет |
| State restoration восстанавливает окно записи после relaunch в фазе `.idle` (устаревший RecordingView) | minor | Проверить в L5; при подтверждении — `.restorationBehavior(.disabled)` на сцену окна записи |
| Notification-разрешение отклонено / не запрошено → нет подтверждения старта | minor | Fallback на индикатор menu bar (вариант A); старт не зависит от уведомления; L5 покрывает оба случая. Размер задачи: S→M (новый TCC-флоу) |
| Регрессия существующих тестов на «старт открывает окно» / «закрытие → stop» | minor | T-5 обновляет `RecordingCoordinatorTests` — **два** теста ассертят `openedRecording==true` (стр. 304 и стр. 987 beforeFirstFrame/#171), оба флипаются; только разрыв №1 юнит-тестируем; `/check` ловит остальное |
| notch/overflow может скрыть индикатор menu bar | minor | Known limitation macOS; ⌘⌥⌃R работает без видимого индикатора; зафиксировать в docs |

## Out of Scope

- Исключение on-demand окна таймера из захвата экрана → **#244** (`SCContentFilter(excludingWindows:)`;
  стек уже ScreenCaptureKit).
- Best-effort финализация записи при завершении приложения → **#243** (`applicationWillTerminate`
  await-stop).
- Превращение Onset в чистый agent/LSUIElement-app (без Dock-иконки) — не требуется; текущая
  `.regular` политика + MenuBarExtra + фаза `.idle` уже дают «только menu bar» во время записи.
- Плавающий HUD-контроллер на старте (Approach 2) — возможен post-MVP как опция.
- First-time confirmation-диалог «запись продолжается в фоне» при первом закрытии окна
  (UX nice-to-have) — отложено; стандартное macOS-поведение красной кнопки достаточно для MVP.

## Open Questions

- [resolved] **Подтверждение старта записи** → выбран вариант B: transient `UNUserNotification`
  «Запись началась • ⌘⌥⌃R», с fallback на индикатор menu bar при отказе в разрешении. См.
  Technical Approach п.8, Decisions, задача T-2.
- [non-blocking] Удалять ли неиспользуемый после изменения seam `openRecordingWindow`
  (closure + параметр `bindWindowActions`)? План оставляет его; если code-review сочтёт мёртвым
  кодом — убрать в том же PR.
