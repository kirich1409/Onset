---
type: spec
slug: disk-space-management
date: 2026-07-18
status: approved
platform: [desktop]
surfaces: [ui, menu-bar, notification, background-job]
risk_areas: [data-loss]
non_functional:
  perf: тело disk-мониторинга на существующем tickTask НЕ блокирует MainActor (I/O на фоновом executor); новый высокочастотный таймер не добавляется; wall-time обработки вердикта на MainActor пренебрежимо мал
acceptance_criteria_ids: [AC-1, AC-2, AC-3, AC-4, AC-5, AC-6, AC-7, AC-8, AC-9, AC-10, AC-11, AC-12]
design:
  figma:
---

# Spec: Контроль свободного места — оценка длительности и безопасная остановка записи

Date: 2026-07-18
Status: approved
Slug: disk-space-management

---

## Context and Motivation

Onset пишет длинные сессии (два HEVC-файла экрана и камеры + аудио) — при исчерпании диска запись обрывается, и хвост MP4 остаётся невалидным (moov-atom не дописан), теряя всю сессию. Сейчас нехватка места ловится только постфактум (`FileWriter` бросает `CocoaError` → алерт), без предупреждения и без штатной остановки. Фича добавляет проактивный контроль: оценку «на сколько хватит места» до и во время записи, заблаговременное предупреждение и штатную остановку с корректной финализацией обоих файлов — не мешая работе macOS (swap/temp/snapshots) и достигая пользователя, даже когда окна Onset в фоне (runtime-is-loaded). Соответствует главному приоритету — стабильность.

Основа — research `swarm-report/research/research-disk-space-thresholds.md` (консорциум + business-analyst review) + multiexpert-review spec (business-analyst, architecture-expert, ux-expert, performance-expert), 2026-07-18.

## Acceptance Criteria

Фича завершена, когда ВСЕ пункты истинны. Каждый критерий имеет стабильный `AC-N` id.

- [ ] **AC-1** — Pre-flight: до старта на главном экране показана оценка доступной длительности («≈ N мин», N округляется вниз до целых минут; при ETA > 60 мин допускается «> 60 мин»). Idle-оценку СЧИТАЕТ `RecordingCoordinator` (он владеет `diskSpaceProvider`), `MainViewModel` только ОТОБРАЖАЕТ готовое значение; чтение свободного места идёт через тот же async `DiskSpaceProviding` (вне MainActor — НЕ синхронный XPC на MainActor). Оценка считается ДО существования `RecordingSession`, по resolved-плану + output-URL, по fallback-битрейту (`averageBitrate` screen+camera+audio); читаются ОБА тома (вывод + системный) по контракту AC-3 — warning на idle возможен и по системному тому. При недостоверных данных — «оценка недоступна» (не ложное число). Старт НЕ блокируется (см. Open Question). При инициации новой записи disk-stop-состояние (AC-9) очищается и pre-flight переоценивается заново — залипшего алерта/блока нет.
- [ ] **AC-2** — Мониторинг встроен в существующий `RecordingCoordinator.tickTask` (~1 Гц); НОВЫЙ высокочастотный таймер НЕ добавляется (проверяется diff'ом); чтение свободного места и размеров выполняется вне MainActor (async-хоп), на MainActor остаётся только обработка готового `DiskVerdict`. Перф-бюджет мониторинга проверяется в рамках L5 (AC-10), не как субъективный порог.
- [ ] **AC-3** — Заблаговременное предупреждение (запись ПРОДОЛЖАЕТСЯ): при пересечении warning-порога — том вывода `ETA ≤ 10 мин ИЛИ свободно ≤ 10 ГБ`; системный том (если ≠ тому вывода) `свободно ≤ 10 ГБ`. Warning-состояние ACTIONABLE и РАЗЛИЧАЕТ ограниченный ресурс: при триггере по output-ETA — «≈ N мин осталось, запись продолжается и будет штатно остановлена, освободите место на диске записи»; при триггере по свободному месту тома вывода — аналогично про диск записи; при триггере по СИСТЕМНОМУ тому — «мало места на системном диске macOS, освободите место» БЕЗ «≈N мин» (ETA тома вывода тут вводит в заблуждение). Контент/поведение, не визуал.
- [ ] **AC-4** — Критический авто-стоп: при пересечении критического порога (сглаженная оценка, см. AC-5) — том вывода `свободно ≤ 2 ГБ ИЛИ ETA ≤ 2 мин`; системный том `свободно ≤ 5 ГБ` — запись останавливается ШТАТНО через `RecordingCoordinator.stop()`; оба файла валидны и воспроизводятся (moov на месте, длительности совпадают ± movieFragmentInterval). Авто-стоп инициируется НЕ inline (`await self.stop()` внутри тела tickTask запрещён — `performStopTeardown` ждёт `await tick?.value`, self-await из tick = дедлок), а отдельной задачей `Task { await self.stop() }` вне tick-тела (по образцу неожидаемого `revocationTask`).
- [ ] **AC-5** — Скорость потребления места = сглаженная `−Δ(свободное место тома вывода)` между тиками (ловит наши записи + сторонний расход + ОС/purgeable-шум — в отличие от дельты размера файла, которая сторонний расход НЕ видит). Сглаживание: скользящее окно в WALL-CLOCK секундах ≥ 2× `movieFragmentInterval` (≥ 8с) или EWMA (длина окна задаётся во времени, НЕ в числе тиков) — скачкообразный ввод (flush пачками ~4с) НЕ даёт ложного пересечения порога. Каденция чтения свободного места (`readEvery`) и прогрев (`warmupTicks`) — РАЗНЫЕ величины: `readEvery` ≤ окно/2 и Δt между чтениями ≥ `movieFragmentInterval` (окно содержит ≥ 2 сэмпла); до накопления окна (в течение `warmupTicks`) — fallback суммарный табличный битрейт. `ETA = свободно_на_томе_вывода / сглаженная_скорость`. При нулевой/отрицательной сглаженной скорости (статичная сцена VBR → скорость→0; или сторонний процесс освободил место) ETA НЕ уходит в ∞-пропуск: абсолютный floor по свободным байтам (AC-4) остаётся активной страховкой независимо от ETA.
- [ ] **AC-6** — Два тома независимо по роли: том вывода — место под файл; системный том (`/System/Volumes/Data` — Data-том, где swap/temp/snapshots) — здоровье ОС. Совпадение томов определяется по volume identifier (`URLResourceValues.volumeIdentifier` / `.volumeIdentifierKey`, НЕ сравнением строк путей); при совпадении применяются обе проверки, берётся строжайший вердикт. Floor «здоровья ОС» (5/10 ГБ) НЕ применяется к внешнему тому вывода.
- [ ] **AC-7** — Last-resort: если пороги не сработали и запись упёрлась в реальный disk-full, `AVError.Code.diskFull` от writer'а инициирует штатную финализацию (не сырой обрыв); поверхность — существующий `RecordingCoordinator.lastWriteError`. Отключение (unplug) внешнего тома вывода во время записи деградирует в writer-fault → тот же last-resort путь (не молчаливый обрыв); это НЕ disk-space-стоп.
- [ ] **AC-8** — Авто-стоп идемпотентен: инициируется ровно один раз, через тот же `stop()`, что ручной/hotkey/termination-стоп (не дёргает stop повторно, не гонится с другими путями).
- [ ] **AC-9** — Причина авто-стопа наблюдаема ВНЕ окна приложения: при авто-стопе постится user-notification (UserNotifications, паттерн существующего `RecordingStartNotifier`), которая (а) называет причину «мало места», И (б) подтверждает позитивный факт — запись завершена штатно и оба файла СОХРАНЕНЫ (по возможности с reveal/путём). Не молчаливый обрыв.
- [ ] **AC-10** — Пороги — reasoned defaults (гипотеза), откалиброваны эмпирически. L5-прогон: том вывода направляется на size-capped APFS-том / sparse disk image с квотой, заполняется до нужного остатка (изолирует от системного тома). Подтвердить: (а) штатная остановка с валидными файлами; (б) реальное время финализации двух файлов укладывается в критический запас 2ГБ; (в) поведение ОС/purgeable вблизи заполнения не ломает оценку; (г) перф-бюджет мониторинга (AC-2) — измеримая дельта, НЕ «нет фризов на глаз»: под representative-load сравнить прогон с включённым и выключенным disk-мониторингом — критерий «нет прироста `encoderBackpressureDrops` и нет hang > 250 мс» (Instruments Hangs / hang-tracking). Расхождения → правка порогов до merge.
- [ ] **AC-11** — Де-эскалация и анти-дребезг: при возврате свободного места/ETA выше warning-порога предупреждающее состояние снимается; переходы имеют гистерезис (порог снятия warning выше порога установки, или debounce ≥ окна сглаживания) — состояние НЕ мигает при колебаниях около порога. Покрыто unit-тестом на осциллирующий ввод.
- [ ] **AC-12** — Warning достигает пользователя вне окна и в fullscreen: при пересечении warning-порога (а) `MenuBarExtra`-лейбл/бейдж отражает предупреждение И (б) постится РАЗОВАЯ UserNotification (один раз на пересечение порога, не дублируется каждый тик, снимается/не повторяется при де-эскалации) — т.к. в fullscreen macOS скрывает строку меню (бейдж не виден), а баннеры уведомлений показываются. Иначе заблаговременный сигнал не дойдёт до fullscreen/фонового пользователя и он узнает о проблеме только в момент авто-стопа (поздно). Поведение, не визуал.

**Authoritative definition of done.** Реализующий агент валидирует против этого списка перед завершением задач.

## Prerequisites

| Prerequisite | Status | Owner | Notes |
|--------------|--------|-------|-------|
| Уточнить тип `URLResourceValues.volumeAvailableCapacityForImportantUsage` (Int vs Int64) | ⬜ Todo | Agent | Xcode Quick Help / ⌥-click (T1, недоступно внешним каналам) |
| Подтвердить macOS-SDK доступность `AVError.Code.diskFull` | ⬜ Todo | Agent | apple-docs / SDK header перед использованием (AC-7) |
| Подтвердить, что UserNotifications-инфраструктура (`RecordingStartNotifier`) доступна в main или её надо принести | ⬜ Todo | Agent | AC-9 доставка; паттерн из ветки critical-recording-signals |
| Подтвердить ключ идентичности тома для AC-6 (`URLResourceValues.volumeIdentifier` / `.volumeIdentifierKey`) на macOS 26 | ⬜ Todo | Agent | Xcode/apple-docs; используется для output==system детекции |

## Affected Modules and Files

| Module / File | Change type | Notes |
|---------------|-------------|-------|
| `Onset/Configuration/RecordingConfiguration.swift` | Modified | Пороги (warn/critical по томам, ETA-пороги, окно сглаживания) рядом с `movieFragmentInterval` |
| `Onset/Recording/Pipeline/RecordingPolicyTypes.swift` | Modified | Pure `nonisolated`: `DiskThresholds`, `DiskVerdict` (none/warning/critical, с явным `nonisolated static func ==`), `ETAEstimate` |
| `Onset/Recording/Pipeline/DiskSpaceEstimator.swift` | New | Pure `nonisolated` калькулятор: (Δ свободного места по двум томам + окно сглаживания + пороги + гистерезис) → `DiskVerdict` + ETA |
| `Onset/Recording/Pipeline/DiskSpaceProviding.swift` | New | DI-seam `nonisolated protocol DiskSpaceProviding: Sendable` с **async** методом чтения (хоп на фоновый executor); `LiveDiskSpaceProvider` (обёртка `URLResourceValues`), резолв тома вывода + системного по volume id |
| `Onset/App/OnsetApp.swift` (место конструирования координатора) | Modified | Wiring `LiveDiskSpaceProvider` в `init` координатора (DI-точка, как `notifier`/`sleepPreventer`) |
| `Onset/UI/RecordingCoordinator.swift` | Modified | Новый `init`-параметр `diskSpaceProvider` (дефолт `LiveDiskSpaceProvider`, seam для `FakeDiskSpaceProvider`); async disk-check на `tickTask` (весь I/O вне MainActor, в провайдере); авто-стоп через `Task { await self.stop() }` (НЕ inline); состояние «остановлено из-за места»; де-эскалация/гистерезис; idle-оценка AC-1 |
| `Onset/UI/Main/MainViewModel.swift` | Modified | Idle pre-flight оценка «≈N мин» до старта (владелец AC-1, до существования `RecordingSession`) |
| `Onset/UI/MenuBar/*` (MenuBarExtra) | Modified | Отражение warning-состояния в лейбле/бейдже (AC-12; поведение, не визуал) |
| `Onset/Permissions/RecordingStartNotifier.swift` (или аналог) | Modified/Reused | User-notification авто-стопа (AC-9); переиспользовать паттерн UNNotification |
| `Onset/UI/Main/MainView*.swift`, `Onset/UI/Recording/*` | Modified | Pre-flight индикатор + warning-состояние (поведение/состояния) |
| `docs/architecture.md` | Modified | Новые типы в type-level карте (CLAUDE.md: docs в том же PR) |
| `OnsetTests/*` | New | Unit: pure-калькулятор (ETA/пороги/сглаживание/гистерезис на осциллирующем вводе), idempotent авто-стоп, финализация; `FakeDiskSpaceProvider` |

Key integration points:
- `RecordingCoordinator.tickTask` (~стр.706-716) — хук мониторинга во время записи; весь I/O выносится в async-провайдер (не блокирует MainActor).
- `RecordingCoordinator.performStopTeardown` ждёт `await tick?.value` (~стр.767) → авто-стоп НЕ может быть inline `await self.stop()` в tick (дедлок); только `Task { await self.stop() }`.
- `RecordingCoordinator.stop()` (~стр.730) — идемпотентный авто-стоп.
- `MainViewModel` + `RecordingConfiguration.averageBitrate(...)` (~стр.203) + resolved-план — источник idle-оценки AC-1 (до сессии) и fallback до накопления окна скорости.

## Technical Approach

- **Pure/impure**: чистый `DiskSpaceEstimator` (nonisolated): вход — история Δ свободного места по двум томам + пороги + гистерезис-состояние; выход — `DiskVerdict` + `ETAEstimate`. Impure — `LiveDiskSpaceProvider` (async, читает `volumeAvailableCapacityForImportantUsageKey` вне MainActor) и мониторинг в координаторе.
- **Скорость потребления**: основной сигнал — сглаженная `−Δ(свободное место тома вывода)` (ловит наши записи + сторонний расход + ОС). Дельта РАЗМЕРА файла НЕ используется как «ловля стороннего расхода» (она этого не видит) — при необходимости кумулятивный байт-каунтер `FileWriter` служит лишь дешёвой оценкой НАШЕЙ компоненты. Сглаживание — окно ≥ 8с / EWMA (гасит flush-пачки movieFragmentInterval).
- **Источник скорости — только Δ free-space, без stat файлов**: `RecordingControlling` экспонирует лишь `sessionDirectory` (не размеры двух выходных файлов), а Δ free-space и так покрывает нашу запись + сторонний расход; отдельный filesystem-stat растущих файлов НЕ нужен и НЕ вводится. Весь I/O (чтение `...ImportantUsage` по двум томам) — в async `LiveDiskSpaceProvider`, вне MainActor.
- **Каденции (perf)**: свободное место допустимо читать раз в N тиков (не каждую секунду), пересчитывая ETA от последнего значения — снижает XPC-стоимость `...ImportantUsage`.
- **Политика скорости**: скользящее окно ≥8с (≥2× movieFragmentInterval) поверх Δ free-space; первые N тиков (N = окно/период) — fallback табличный битрейт; при скорости ≤ 0 — floor по свободным байтам остаётся активным (ETA не пропускает порог). При ошибке чтения тома — сохранить последнее достоверное состояние (не мигать), idle-индикатор → «оценка недоступна», авто-стоп по недостоверным данным ЗАПРЕЩЁН.
- **Два тома**: провайдер резолвит том вывода и системный (`/System/Volumes/Data`) по volume id; совпадение → обе проверки, строжайший вердикт.
- **Поток**: tickTask → (async, вне MainActor) прочитать свободное место + обновить окно скорости → `DiskSpaceEstimator.evaluate(...)` → вердикт (с гистерезисом), на MainActor только обработка вердикта. `warning` → UI-состояние + MenuBarExtra бейдж + разовая UserNotification (AC-12, для fullscreen/фона), запись идёт. `critical` → `Task { await self.stop() }` (НЕ inline await — дедлок с `performStopTeardown`), один раз. При stop из-за места — user-notification (AC-9). Idle-оценка AC-1 использует ТОТ ЖЕ async `DiskSpaceProviding` (координатор владеет им, читает вне MainActor, MainViewModel отображает).
- **Природа async-чтения**: `...ImportantUsage` — синхронный блокирующий XPC к демону CacheDelete; `async`/`nonisolated` убирает блокировку MainActor (исполняется на cooperative pool), но чтение остаётся блокирующим для потока пула. При каденции `readEvery` и единственном подписчике — пренебрежимо; отдельный executor/`DispatchQueue` НЕ требуется.
- **Асимметрия к сохранности**: авто-стоп — крайняя мера; warning (10 мин/10 ГБ) заблаговременно; критические пороги низкие на томе вывода, фиксированный floor — на системном.
- **Error handling**: `AVError.Code.diskFull` → штатная финализация (last-resort, AC-7). Ошибка чтения тома → мониторинг деградирует безопасно (лог PII-free, НЕ авто-стопит по недостоверным данным, не мешает записи).
- **State**: причина «диск» по образцу `lastWriteError`(212)→`hasPendingAlert`(221); notification + reveal сохранённых файлов.

## Technical Constraints

- Без новых зависимостей — Foundation (`URLResourceValues`) + существующий стек (UserNotifications уже используется в проекте).
- `volumeAvailableCapacityForImportantUsage` (учитывает purgeable → консервативный floor поглощает переоценку). disk-full — только `AVError.Code.diskFull`, НЕ numeric codes.
- **I/O чтения места/размеров — вне MainActor** (async-хоп); tickTask на MainActor не блокируется. Никакого нового высокочастотного таймера.
- Swift 6 strict concurrency, default MainActor; `DiskVerdict` enum — явный `nonisolated static func ==` witness (`InferIsolatedConformances`).
- Авто-стоп — ТОЛЬКО через идемпотентный `RecordingCoordinator.stop()` (единый путь #243), и вызывается из tickTask ТОЛЬКО как `Task { await self.stop() }` — inline `await self.stop()` в теле tick ЗАПРЕЩЁН (teardown ждёт `await tick?.value` → self-await дедлок).
- Весь filesystem/volume I/O — в async `LiveDiskSpaceProvider` вне MainActor; MainActor-tick не выполняет блокирующих чтений.
- Логи — `os.Logger(subsystem: "dev.androidbroadcast.Onset")`; НЕ логировать пути/PII.
- Пороги — в `RecordingConfiguration` (конфиг-слой), не хардкод.
- Warning/авто-стоп — текстовая семантика (accessibility label / при критическом VoiceOver-анонс), НЕ только цвет; передать требование в бриф дизайн-сервиса.

## Decisions Made

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Scope томов | Два тома (вывод + системный) | Владелец подтвердил; вывод может быть внешним 2ТБ, системный несёт swap/temp — разные заботы |
| Метрика | Абсолютный floor (ОС) + ETA (вывод); БЕЗ процента/clamp | ОС-нужды фиксированы → % избыток на 2ТБ; clamp = ложная точность |
| Источник скорости | Сглаженная `−Δ свободного места` тома вывода | Ловит сторонний расход + ОС (дельта размера файла — НЕ ловит); сглаживание гасит flush-осцилляцию |
| Сглаживание | Окно ≥ 2× movieFragmentInterval (≥8с) / EWMA | flush пачками ~4с при 1Гц-выборке даёт скачки → ложные срабатывания без сглаживания |
| Доставка сигнала | warning = MenuBarExtra бейдж + РАЗОВАЯ UserNotification; авто-стоп = UserNotification | Окна в фоне (runtime-is-loaded); в fullscreen macOS скрывает строку меню (бейдж не виден), а баннеры уведомлений показываются — иначе заблаговременный warning не дойдёт |
| Idle-оценка (AC-1) владелец | Считает `RecordingCoordinator` (владеет провайдером), `MainViewModel` отображает; чтение через async provider | idle-read `...ImportantUsage` синхронно на MainActor MainViewModel = блокирующий XPC (нарушение «main священен») |
| I/O мониторинга | async, вне MainActor | nonisolated не переносит с MainActor; блокирующее чтение на tick записи = риск фризов (приоритет стабильность) |
| Пороги (числа) | Сист. warn ≤10ГБ/стоп ≤5ГБ; вывод warn ETA≤10мин\|≤10ГБ/стоп ≤2ГБ\|ETA≤2мин | Reasoned defaults; калибровка AC-10 |
| Асимметрия | К сохранности; авто-стоп крайняя мера | Преждевременный стоп теряет сессию (хуже битого хвоста); гасить заблаговременным warning |
| Путь авто-стопа | Идемпотентный `stop()` через `Task {}` вне tick | inline `await stop()` в tick = дедлок (teardown ждёт `tick.value`) |
| Владелец idle-оценки AC-1 | UI-слой (`MainViewModel`/координатор), не `RecordingSession.start()` | Сессия не существует до старта; оценка нужна на idle-экране |
| Источник скорости | Только Δ free-space, без stat файлов | `RecordingControlling` не даёт размеры файлов; Δ free-space покрывает и нашу запись, и сторонний расход |

## Out of Scope

- Визуальный дизайн индикаторов (пре-флайт «≈N мин», warning-бейдж, notification-текст верстка) — *owner: владелец через Claude Design service; spec фиксирует поведение/состояния/семантику, не визуал*.
- Процентные / `clamp`-пороги — *отложено до данных, что фиксированный floor недостаточен*.
- Блокировка старта при малом месте — только предупреждение (AC-1; см. Open Question).
- Выбор контейнера/формата (MKV vs MP4, OBS-урок) — проект на MP4 + штатная финализация; *вне scope*.
- Автоочистка / предложение удалить файлы для освобождения — *будущая итерация*.
- Покадровый реальный битрейт энкодера как источник ETA — используется Δ free-space; *вне scope*.

## Open Questions

- [ ] Pre-flight при КРИТИЧЕСКИ малом месте на старте (ниже критического порога до записи) — *non-blocking*
  - Options: (A) предупредить, разрешить старт; (B) заблокировать старт
  - Recommendation: (A) — согласуется с AC-1 и асимметрией; last-resort всё равно защитит файл. Pre-flight в этом случае несёт тот же actionable-контент, что AC-3. Агент применяет (A), если владелец не переопределит.

## Future Phases

*(Единый MVP-контракт; ниже — возможные итерации вне scope.)*

**Итерация 2 — калибровка-driven тюнинг:** уточнение порогов/окна по данным L5 и телеметрии; процентный clamp, если floor недостаточен на краях.
**Итерация 3 — проактивное освобождение:** предложение очистить purgeable / удалить старые записи при приближении к порогу.
