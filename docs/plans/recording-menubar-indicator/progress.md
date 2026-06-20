# Progress: Запись в фоне — menu-bar-first

> Plan: ./plan.md · Tasks: ./tasks.md · Issue #242 · Follow-ups #243 #244

## Status
- [x] T-1 — Старт не открывает окно записи
- [x] T-2 — Transient-подтверждение старта записи (уведомление)
- [x] T-3 — Закрытие окна таймера не останавливает запись
- [x] T-4 — Menu bar: хоткей остановки + accessibility
- [x] T-5 — Обновить юнит-тесты под menu-bar-first
- [x] T-6 — Обновить spec и architecture docs
- [ ] T-7 — L5: живая проверка на MX Brio

## Learnings
- T-1/T-2: `notifyRecordingStarted()` сделан синхронным в протоколе, async-работа внутри `LiveRecordingStartNotifier` через `Task {}` — spy в тестах инкрементит счётчик синхронно, нет гонки.
- T-2: UN API — только completion-handler в ObjC header; async формы это Swift compiler wrappers (подтверждено компиляцией); app не в sandbox → entitlement для локальных уведомлений не нужен.
- T-2: `PBXFileSystemSynchronizedRootGroup` у обоих таргетов — новые файлы в директории подхватываются автоматически, ничего не нужно добавлять в pbxproj.
- T-4: `accessibilityLabel` добавлен в `MenuBarLabelDescriptor` и генерируется в маппере — логика не дублируется в view.
- T-5: Флипнуты только `openedRecording` assertions; `dismissedMain == true` сохранён в обоих тестах (dismissMain по-прежнему зовётся).
- T-5: Второй тест (`start_doesNotTransitionToRecording_beforeFirstFrame`) — post-activation `openedRecording` тоже флипнут в `false`, т.к. `activateRecording()` больше не вызывает `openRecordingWindow()`.
- T-4 (fix): как только в `.recording`-ветке появляется `let elapsedString = ...` перед inner switch, функция перестаёт быть single-expression switch и Swift требует явных `return` перед каждым `MenuBarLabelDescriptor(...)` — иначе компилятор трактует их как unused expression statements и выдаёт предупреждение (=ошибку при warnings-as-errors).
