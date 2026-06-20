# Progress: Запись в фоне — menu-bar-first

> Plan: ./plan.md · Tasks: ./tasks.md · Issue #242 · Follow-ups #243 #244

## Status
- [x] T-1 — Старт не открывает окно записи
- [x] T-2 — Transient-подтверждение старта записи (уведомление)
- [x] T-3 — Закрытие окна таймера не останавливает запись
- [x] T-4 — Menu bar: хоткей остановки + accessibility
- [x] T-5 — Обновить юнит-тесты под menu-bar-first
- [x] T-6 — Обновить spec и architecture docs
- [~] T-7 — L5: ядро подтверждено вживую (MX Brio); остаток — see Learnings

## Learnings
- T-1/T-2: `notifyRecordingStarted()` сделан синхронным в протоколе, async-работа внутри `LiveRecordingStartNotifier` через `Task {}` — spy в тестах инкрементит счётчик синхронно, нет гонки.
- T-2: UN API — только completion-handler в ObjC header; async формы это Swift compiler wrappers (подтверждено компиляцией); app не в sandbox → entitlement для локальных уведомлений не нужен.
- T-2: `PBXFileSystemSynchronizedRootGroup` у обоих таргетов — новые файлы в директории подхватываются автоматически, ничего не нужно добавлять в pbxproj.
- T-4: `accessibilityLabel` добавлен в `MenuBarLabelDescriptor` и генерируется в маппере — логика не дублируется в view.
- T-5: Флипнуты только `openedRecording` assertions; `dismissedMain == true` сохранён в обоих тестах (dismissMain по-прежнему зовётся).
- T-5: Второй тест (`start_doesNotTransitionToRecording_beforeFirstFrame`) — post-activation `openedRecording` тоже флипнут в `false`, т.к. `activateRecording()` больше не вызывает `openRecordingWindow()`.
- T-4 (fix): как только в `.recording`-ветке появляется `let elapsedString = ...` перед inner switch, функция перестаёт быть single-expression switch и Swift требует явных `return` перед каждым `MenuBarLabelDescriptor(...)` — иначе компилятор трактует их как unused expression statements и выдаёт предупреждение (=ошибку при warnings-as-errors).
- T-7 L5 (2026-06-20, подписанная .app, MX Brio): ядро ПОДТВЕРЖДЕНО вживую — старт не открывает окно (`title of windows` пусто), индикатор «Onset, идёт запись, 00:01» сразу; ⌘⌥⌃R виден у «Остановить» (AX cmdChar=R, mods=Option+Control+Command); «Открыть окно записи» открывает окно; ЗАКРЫТИЕ окна красной кнопкой НЕ останавливает запись (тикает дальше); стоп через меню → idle + возврат на главное (origin .main); 2 валидных HEVC (Camera 1080p30, Screen 4K, оба +aac, ~252.7s, finalized); AX-label индикатора state-aware. ОСТАТОК: (1) визуальный баннер уведомления — нужен one-time grant разрешения (пользователь); auth-промпт на старте появился = T-2 path подтверждён; (2) live-стоп ⌘⌥⌃R не тестим синтетикой (Carbon hotkey), покрыт юнит-тестом handleHotKey; (3) restoration после relaunch не проверен (kill/pkill заблокированы политикой). Детали: `swarm-report/recording-menubar-indicator-e2e-scenario.md`.
