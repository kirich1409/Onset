# Tasks: critical-recording-signals

Зависимости в скобках. Реализация — swift-инженер (или general-purpose, если
swift-агент недоступен), L2-тесты в той же задаче. Тесты — Swift Testing, конвенции
`OnsetTests/CLAUDE.md`. Инвариант: каждая задача оставляет проект компилируемым и
зелёным по L0-L2.

## P0 — Prerequisites
- [ ] T0.1 Аудит пост-стоп пути после #246: фактическое поведение `degradedWarning` /
  `postStopDropWarningThreshold` (`RecordingCoordinator:172,685–700`,
  `RecordingSession:869`). → verify: задокументировано здесь, решено reuse vs обход
  (известно: существующая ветка только логирует + reveal, UI-warning поверхности нет).
  (gate для C)

## A — Foundations (pure/contract, L2) — parallel with B
- [ ] T-A.1 Константы в `RecordingConfiguration` (9 шт. из спеки) + комментарий
  calibrate/future-Settings. → verify: build; значения совпадают со спекой.
- [ ] T-A.2 `CriticalIncident` + `CriticalIncidentScope` в `PipelineTypes.swift` с
  nonisolated `==` и `hash(into:)` (образец `RecordingState`). → verify: off-actor
  использование компилируется; L2 на Equatable/Hashable.
- [ ] T-A.3 `FpsCollapseDetector.swift` (new, pure): baseline-окно
  `cameraBaselineWindowSeconds`, skip `cameraBaselineSkipSeconds`, freeze-on-candidate,
  AND (delivered<ratio×baseline ≥ window И drop/gap), время аргументом, устаревший
  по возрасту snapshot отбрасывается. → verify: L2 AC-5/AC-6 (коллапс+drop/gap → да;
  спад без drop/gap → нет; устойчивый коллапс ≥2×window не самовосстанавливается).
  (deps T-A.1)
- [ ] T-A.4 `SustainedDropDetector.swift` (new, pure): degraded ≥
  `criticalSustainSeconds` (live), нормированный drop-rate ≥ `criticalDropRatePerMin`
  И длительность ≥ `criticalDropRateMinSessionSeconds` (пост-стоп), время аргументом.
  → verify: L2 AC-3(а) порог; AC-4 (включая floor: 2-сек клип не срабатывает).
  (deps T-A.1)
- [ ] T-A.5 **Контракт нотифаера** (до C): расширить протокол `RecordingStartNotifying`
  методами критики (live по тиру + пост-стоп), реализовать в `RecordingStartNotifier`
  (уровень по тиру: hard `timeSensitive` / soft `active`; контент/identifier),
  обновить `FakeRecordingStartNotifier` (запись вызовов для L2). → verify: build; L2
  через Fake — уровень соответствует тиру. (deps T-A.2) [actionable reveal +
  entitlement — в E; дедуп/cap решает координатор — в C]

## B — Live-seam (P1) — parallel with A
- [ ] T-B.1 latest-snapshot камеры (struct: fps/gap rate + возраст/tick-id) в
  `StageRateAggregator`, обновляется внутри существующего `flush`/`rateLock` БЕЗ reset
  окна; **атомарно** — смена сигнатуры `flush` И миграция всех 4 call-site
  (VideoEncoder:510, CameraSource:277, ScreenSource:344, FileWriter:459) в этой же
  задаче. → verify: build зелёный; существующие StageRateAggregator-тесты зелёные;
  L2: flush обновляет snapshot, reset лог-строки snapshot не трогает.
- [ ] T-B.2 `RecordingSession.currentRates()` — pull camera-снимка под существующим
  lock (рядом с `currentDrops():470`). encoder/writer-снимок НЕ пробрасывать.
  → verify: build; нет второго acquire/нового stream/нового subscriber. (deps T-B.1)

## C — Coordinator integration (deps A, B, T0.1; P2)
- [ ] T-C.1 Два значения на координаторе: live critical view (де-эскалируемый вердикт
  детекторов) + session max-severity latch (отдельно, только для пост-стопа).
  → verify: L2 AC-3(в) — windowed-hard де-эскалирует live, session-latch держит max
  для пост-стопа.
- [ ] T-C.2 Детекторы в tick-loop на монотонном `elapsed` (не `Date():627`; Date()
  только UI). → verify: L2 на детекторах с инжектированным временем; код-ревью что
  tick не питает окна `Date()`.
- [ ] T-C.3 Маппинг `cameraLost(scope)` из `.sourceRevoked(.camera)` /
  `.allVideoSourcesLost` (`:595–614`) → soft/hard. → verify: L2 AC-1/AC-2 маппинг
  scope→тир. (deps T-C.1)
- [ ] T-C.4 Пост-стоп ветка по max-severity (2 текста: hard / soft-only) + дедуп
  live-уведомлений (suppress + severity-override) + session-level cap (макс. одно
  live-уведомление тира за сессию). → verify (раздельно):
  · AC-9 — windowed-дедуп: два hard в окне → одно; soft затем hard → hard доставлен;
  · AC-3(б) session-cap — рецидив hard после де-эскалации второго live-баннера не шлёт;
  · AC-13 — soft-only сессия → мягкая нота, не «серьёзные проблемы»;
  · AC-8 — суб-пороговые дропы → live view = normal/degraded, latch пуст, notifier
    (Fake) не вызван, disk-only путь #246 сохранён;
  · AC-10 / soft+denied — при denied-уведомлениях октагон всё равно отражает hard;
    soft+denied → notifier не доставляет, остаётся disk-only by design; запись цела.
  (deps T-C.1, T-A.5)

## D — UI (deps C) — parallel with E
- [ ] T-D.1 `MenuBarLabel`: глиф `exclamationmark.octagon.fill`, различитель
  внутр.глиф+цвет (опц. пульсация — не несущая). → verify: build; grayscale-снимок в
  реальном размере status-item отличим от degraded/normal (AC-11).
- [ ] T-D.2 `MenuBarLabelMapper`: hard-вид от live view (второй вход) + per-инцидент
  a11y-label. → verify: L2 AC-11 (label критики ≠ degraded). (deps T-D.1)

## E — Notifications finish + entitlement (deps T-A.5, C; P3) — parallel with D
- [ ] T-E.1 Actionable пост-стоп: действие уведомления → reveal отчёта в Finder
  (обработчик клика). → verify: L5 AC-12 (клик открывает отчёт) — наблюдается в G.
- [ ] T-E.2 Capability Time Sensitive в `Onset.entitlements` + обновить
  `scripts/check-entitlements.sh`. → verify: `check-entitlements.sh <Onset.app>`
  зелёный на built .app; `check-no-network.sh` всё ещё зелёный.

## F — Docs (deps C-E)
- [ ] T-F.1 Обновить docs. → verify (бинарно): `docs/architecture.md` содержит
  `CriticalIncident`/`FpsCollapseDetector`/`SustainedDropDetector`/`currentRates()` +
  описание потока сигнала; `docs/quality/production-quality-bar.md` содержит таблицу
  9 порогов и пункт L5-калибровки AC-7.

## G — Verification (L5, MX Brio)
- [x] T-G.1 `scripts/preflight.sh` зелёный (L0-L2 + lint + privacy). → verify: exit 0.
      Выполнено 2026-07-19: exit 0, 1059 тестов в 189 сюитах, swiftformat 0/192,
      swiftlint --strict 0 нарушений, privacy manifest PASS.
- [~] T-G.2 **частично; остаток отложен в #339 решением владельца.** Закрыто L5-прогоном
      2026-07-19: половина AC-7 «cold-start ramp» (запись 357 с с разгоном камеры —
      ни одного срабатывания коллапса) и замер разрывов в нормальном свете
      (`gap_ms_avg` 34.5 мс, `gap_ms_max` 100 мс при пороге 250 мс).
      Не закрыто (требует физического доступа к камере): AC-1, AC-2, низкосветовая
      половина AC-7, AC-12, AC-13. Пять способов индуцировать отвал/столл софтом
      проверены эмпирически и все закрыты — детали в #339.
      Исходная формулировка задачи ниже.
- [ ] T-G.2 L5 на Brio: AC-1 (камера+экран отвал → active-уведомление, без октагона),
  AC-2 (камера-only отвал → timeSensitive + октагон-латч), AC-7 (затемнение не
  срабатывает / stall срабатывает), AC-12 (клик пост-стоп → reveal в Finder), AC-13
  (soft-сессия → мягкая нота). Перед запуском `pgrep -la Onset` / signed build / один
  test за раз. → verify: каждый AC наблюдён вживую; доказательства в PR body.
