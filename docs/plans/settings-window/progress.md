# Progress: окно «Настройки» (⌘,) — v1

> Plan: ./plan.md · Tasks: ./tasks.md

## Status
- [x] T-1 — Доменные типы в Configuration/ (SettingApplyPolicy, SettingsKeys) ✅ build+L2 зелёные
- [x] T-2 — Хранилище настроек по-ключно (таймер, зеркало) ✅ build+L2 зелёные
- [x] T-3 — Общая @Observable AppSettings (in-memory источник истины) ✅ build+L2 зелёные (901 тест)
- [x] T-4 — Добавить cameraMirror в RecordingConfiguration ✅ build+L2 зелёные
- [x] T-5 — Читать зеркало на seam записи + дать AppSettings превью ✅ build зелёный
- [x] T-6 — Тоггл таймера в menu bar (потребитель) ✅ build+L2 зелёные (suite тоггла таймера)
- [x] T-7 — Зеркалирование камеры (путь записи + живое превью) ✅ impl+build зелёные; L5 PASS — записанный camera.mp4 детерминированно переворачивается в обе стороны; живое превью переворачивается
- [x] T-8 — Observable recording-active + классификатор доступности ✅ impl+классификатор+регрессия координатора (6 тестов) зелёные
- [x] T-9a — Сцена Settings, вкладки, обнаружимость, реальные контролы ✅ build зелёный; L5 PASS — и SettingsLink, и ⌘, открывают окно, открывается сначала на Индикации / помнит последнюю вкладку
- [x] T-9b — Панели read-only-заглушек + гейтинг во время записи ✅ build зелёный; заглушка иконки Dock на месте; L5 PASS — зеркало гейтится+подпись во время записи, строки-заглушки = AXStaticText
- [x] T-10 — Docs + L5-верификация + CLAUDE.md ✅ docs/architecture.md + CLAUDE.md готовы; L5 на MX Brio (signed-build) PASS — все 8 e2e-шагов; см. swarm-report/settings-window-e2e-scenario.md

> Профиль качества ВЫКИНУТ из v1 (владелец) — отложен в следующую задачу с аппаратной калибровкой.

**Status:** DONE. Все задачи реализованы + L5-верифицированы на MX Brio (signed-build). Build + 907 unit-тестов зелёные; `/finalize` PASS; L5 PASS (переворот зеркала в обе стороны, CFR-каденс gap_count=0 за 8.7 мин, живое скрытие таймера, гейтинг, персистентность-через-рестарт, AX static-text заглушки).
**Next:** промоутнуть PR #274 → ready; нужно РЕВЬЮ ВЛАДЕЛЬЦА (трогает CLAUDE.md + UI → никогда не авто-мержить по политике meta-merge проекта).

## L5 results (2026-06-29, MX Brio, signed build TeamID 9PULX5QX5Y)
- Переворот зеркала: записанный camera.mp4 OFF=шкаф СЛЕВА (естественно), ON=шкаф СПРАВА (перевёрнуто) — детерминированно в обе стороны на MX Brio (метаданные ffprobe этого не видят; использовано pixel frame-extraction). ⚠ Встроенная фронт-камера FaceTime mirror-OFF (кейс, на который нацелен auto-adjust фикс из finalize) НЕ ПРОТЕСТИРОВАНА — встроенная камера isSuspended (clamshell/внешний дисплей), не выбираема в picker; нужен открытый клапан. Фикс — корректный defensive-код; путь недостижим в этой конфигурации.
- Cadence gate (verify-cfr): packet-rate 60/30 PASS, PTS-uniformity gap_count=0 ОБА потока ОБА прогона (зеркало-ON 526s) → НЕТ регрессии frame-drop/каденса от зеркала. (gap_count=0 доказывает отсутствие дропов, не сам механизм zero-copy; powermetrics не сработал, sudo заблокирован.) C/D fresh-content FAIL одинаково (статичный субъект — ограничение скрипта, не регрессия).
- Тоггл таймера: вживую скрывает/показывает elapsed в menu bar во время записи, точка сохраняется; переживает рестарт.
- Во время записи: зеркало `.disabled` + «Недоступно во время записи»; таймер остаётся включённым.
- AX: строки-заглушки = AXStaticText (не кнопки); живые тогглы = AXCheckBox.
- Персистентность: @AppStorage последняя вкладка + mirror-состояние SettingsStore восстановлены после полного quit/relaunch.

## Learnings
- Wave 1 (T-1,T-2,T-4,T-8) реализована swift-engineer; lint зелёный; build+L2 верифицируются. Чекбоксы отмечены после зелёных.
- T-8: `isRecordingActive` также сбрасывается в false на путях сбоя start() (throw/cancel/denial-timeout), не только в stop — иначе гейт залипает `true`, когда ничего не пишется. Места: decl 146, true@462, false@478(catch)/498(!activated cleanup)/778(stop). isStarting defer не тронут.
- T-4: `cameraMirror` — обычный `let` (без inline-default, поэтому остаётся в memberwise init); default `false` живёт на параметре `makeMVPDefault`. Принудительно обновлены 4 call-site'а `RecordingConfiguration(...)` в ScreenStreamConfigurationBuilderTests + RecordingSessionTests (L0).
- T-2: `SettingsDefaults` — единственный источник default'ов; default `showMenuBarTimer` **true**, `cameraMirror` **false**. `AppSettings` (T-3) обязана грузиться через `SettingsPersisting.load*()`, не сырой UserDefaults. Fake = `InMemorySettingsStore`.
- FOLLOW-UP (открыт): регрессионный тест координатора T-8 (isRecordingActive остаётся true на протяжении окна старта; сбрасывается при denied/cancelled старте) ПОКА не написан — назначить на следующую тестовую волну (владеет RecordingCoordinatorTests.swift).
- Xcode использует filesystem-synchronized groups — новые файлы авто-компилируются, правки pbxproj не нужны.
