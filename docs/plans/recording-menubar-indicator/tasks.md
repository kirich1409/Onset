# Tasks: Запись в фоне — menu-bar-first

> Plan: ./plan.md · Spec: docs/specs/2026-06-02-onset-recording-mvp.md · AC referenced inline
> Follow-ups: #243 (финализация при завершении app), #244 (исключение окна из захвата)

## T-1 — Старт не открывает окно записи
- after: none
- files: `Onset/UI/RecordingCoordinator.swift`
- acceptance: GIVEN запись запускается через `start()`/`activateRecording()` WHEN активация
  завершается THEN окно `WindowID.recording` не открывается (вызов `openRecordingWindow()` удалён),
  при этом `dismissMainWindow()` по-прежнему вызывается и `phase == .recording`.
- check: `grep -n "openRecordingWindow" Onset/UI/RecordingCoordinator.swift` — в теле
  `activateRecording` вызова нет (остаётся только объявление/binding); `xcodebuild build` зелёный.
  ВНИМАНИЕ: `xcodebuild test` намеренно красный до T-5 — `start_transitionsToRecording` (стр. 304)
  и beforeFirstFrame-тест (стр. 987) ассертят открытие окна; запускать тесты только после T-5. (уточняет AC-3)

## T-2 — Transient-подтверждение старта записи (уведомление)
- after: T-1
- files: `Onset/Permissions/RecordingStartNotifier.swift` (новый, протокол `RecordingStartNotifying` + impure `LiveRecordingStartNotifier`), `Onset/UI/RecordingCoordinator.swift`, `OnsetTests/Fake*` (новый `FakeRecordingStartNotifier`), `OnsetTests/RecordingCoordinatorTests.swift` (новый тест-кейс notifier-spy — туда же, что и T-5)
- acceptance: GIVEN старт записи WHEN `activateRecording` выполняется THEN постится локальное
  уведомление «Запись началась • Остановить: ⌘⌥⌃R или меню Onset» через `UNUserNotificationCenter`.
  Авторизация — **lazy внутри** `notifyRecordingStarted()`: `getNotificationSettings` → `notDetermined`
  → `requestAuthorization(options: [.alert, .sound])`; `authorized` → постить; `denied` → молчаливый
  fallback на индикатор menu bar (без ошибки, запись идёт). Entitlement для локальных уведомлений в
  sandbox на macOS 26 НЕ требуется (подтвердить сборкой; если потребуется — добавить в `.entitlements`).
  DI: параметр `notifier: any RecordingStartNotifying = LiveRecordingStartNotifier()` добавляется в
  `RecordingCoordinator.init` **с default-значением** (иначе все существующие вызовы
  `RecordingCoordinator(sessionFactory:)` в тестах не скомпилируются); тесты передают
  `FakeRecordingStartNotifier`.
- check: юнит-тест в `RecordingCoordinatorTests.swift`: `activateRecording` вызывает
  `notifier.notifyRecordingStarted()` (через Fake-spy); при denied-ветке старт не падает;
  `scripts/check-no-network.sh` зелёный; `scripts/check-privacy-manifest.sh` зелёный; L5 (T-7 п.1)
  — баннер виден. (уточняет AC-3)

## T-3 — Закрытие окна таймера не останавливает запись
- after: none
- files: `Onset/UI/Recording/RecordingView.swift`
- acceptance: THE SYSTEM SHALL не вызывать `coordinator.stop()` из `.onDisappear` окна записи;
  закрытие окна во время записи лишь скрывает окно, запись продолжается. Doc-comment `RecordingView`
  обновлён: красная кнопка заголовка = «скрыть», не «остановить». Cmd-Q комментарий (стр. 50-54)
  переписан честно — удаление связи уменьшает graceful-финализацию, правильное решение ведёт #243
  (прежняя ссылка на закрытый #38 убрана).
- check: `grep -n "onDisappear" Onset/UI/Recording/RecordingView.swift` не находит вызова `stop()`;
  `grep -n "#38" Onset/UI/Recording/RecordingView.swift` пуст; сборка зелёная; L5 (T-7 п.4).
  (уточняет AC-9 — stop только явными путями)

## T-4 — Menu bar: хоткей остановки + accessibility
- after: none
- files: `Onset/UI/MenuBar/MenuBarMenu.swift`, `Onset/UI/MenuBar/MenuBarLabel.swift`
- acceptance: THE SYSTEM SHALL (а) пункт menu bar «Остановить» имеет
  `.keyboardShortcut(KeyEquivalent("r"), modifiers: [.command, .option, .control])` (macOS отрисует
  комбинацию в меню). ПРИМЕЧАНИЕ: Carbon `RegisterEventHotKey` (`GlobalHotKeyMonitor`) и NSMenuItem
  shortcut — разные event paths, двойного триггера stop нет архитектурно (не городить защиту);
  (б) accessibility label индикатора `MenuBarLabel` озвучивает состояние для VoiceOver — в `.recording`
  например `"Onset — запись идёт • 01:23"`, в degraded `"Onset — запись деградирована • 01:23"`, в idle
  `"Onset — не записывает"`, а не только строку таймера.
- check: `grep -n "keyboardShortcut" Onset/UI/MenuBar/MenuBarMenu.swift` находит ⌘⌥⌃R на «Остановить»;
  `grep -n "accessibilityLabel\|accessibilityValue" Onset/UI/MenuBar/MenuBarLabel.swift` находит
  state-aware label; `xcodebuild build` зелёный; L5 (T-7 п.6 VoiceOver).

## T-5 — Обновить юнит-тесты под menu-bar-first
- after: T-1, T-2, T-3
- files: `OnsetTests/RecordingCoordinatorTests.swift`
- acceptance: GIVEN **оба** теста, ассертящих `openedRecording==true` — `start_transitionsToRecording()`
  (стр. ~304) И beforeFirstFrame/#171-тест (стр. ~987, `"recording window must open after first frame"`)
  — WHEN `start()` завершился THEN ассерты флипнуты на `#expect(!openedRecording, ...)` с обновлёнными
  failure-message и doc-comment («…must NOT open, even after first frame (menu-bar-first)»);
  `phase == .recording` сохранён; добавлен ассерт, что вызван start-notifier (T-2). Конструктор в тестах
  обновлён под новый параметр: `RecordingCoordinator(sessionFactory: { _ in fake }, notifier: FakeRecordingStartNotifier())`.
  ЯВНО: только разрыв №1 (старт не открывает окно) юнит-тестируем; разрыв №2 (закрытие не останавливает)
  — SwiftUI view-lifecycle, юнит-тестом не достижим, L5-only (T-7 п.4). Cancel-ветки (`openedRecording==false`)
  остаются валидными.
- check: `xcodebuild test -scheme Onset -destination 'platform=macOS' -configuration Debug
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO` — Swift Testing summary зелёный.

## T-6 — Обновить spec и architecture docs
- after: T-1, T-2, T-3, T-4
- files: `docs/specs/2026-06-02-onset-recording-mvp.md`, `docs/architecture.md`
- acceptance: THE SYSTEM SHALL отражать новое поведение: AC-3 (стр. 34) переписан — старт НЕ
  открывает окно, переход в menu-bar-only, transient-уведомление подтверждает старт; раздел «Окна и
  menu bar» (стр. 178-184) — окно записи по требованию, закрытие не останавливает; AC-9 (три пути
  stop, ⌘⌥⌃R виден в меню) актуализирован; notch/overflow и notification-permission зафиксированы;
  `docs/architecture.md` оконный жизненный цикл + `RecordingStartNotifier` добавлены.
- check: `grep` отсутствия «открывается окно записи» на старте в AC-3; ревью на согласованность.

## T-7 — L5: живая проверка на MX Brio
- after: T-1, T-2, T-3, T-4, T-5, T-6
- files: — (verification only)
- acceptance: GIVEN собранный SIGNED .app на reference-железе (MX Brio) WHEN стартуется запись THEN
  (1) окно не появляется; config-окно закрывается; индикатор menu bar (red dot + таймер) появляется
  сразу; transient-уведомление «Запись началась • ⌘⌥⌃R» показано (и проверить путь denied → только
  индикатор);
  (2) пункт menu bar «Открыть окно записи» открывает окно таймера; повторный вызов поднимает то же
  окно, копий не плодит;
  (3) закрытие окна красной кнопкой НЕ останавливает запись — индикатор продолжает тикать,
  `phase == .recording`;
  (4) остановка без открытия окна (menu bar / ⌘⌥⌃R) — без краша, корректный переход фазы, файл валиден;
  (5) перезапуск app после открытого окна записи — окно НЕ восстанавливается (иначе
  `.restorationBehavior(.disabled)`);
  (6) пункт «Остановить» показывает ⌘⌥⌃R; VoiceOver озвучивает состояние индикатора.
- check: `scripts/preflight.sh` зелёный; UI-цикл build→launch→drive→screencapture подтверждает 1-6;
  ffprobe/verify-cfr на выходном файле. Скриншоты индикатора, уведомления и отсутствия окна — в PR.
