---
type: plan
slug: disk-space-management
date: 2026-07-18
status: approved
spec: docs/specs/2026-07-18-disk-space-management.md
risk_areas: [data-loss, concurrency, main-actor-stall, merge-collision]
review_verdict: pass
review_blockers: []
---

# Plan: Контроль свободного места — оценка длительности и безопасная остановка записи (#88)

## Context & Decision

Реализация approved-спеки `docs/specs/2026-07-18-disk-space-management.md` (12 AC). Что
строим — определено спекой; этот план фиксирует *как*: типы, границы, порядок задач и
проверяемое «готово» на каждую задачу. План НЕ переопределяет требования спеки — ссылается
на её `AC-N`.

Фича добавляет проактивный контроль диска в идущую запись (два HEVC + аудио): idle-оценка
«≈N мин» до старта, заблаговременное предупреждение (запись продолжается), штатный авто-стоп
до исчерпания места (валидные файлы), не мешая macOS. Главный приоритет проекта —
**стабильность** — правит каждое решение ниже (особенно авто-стоп и не-блокировка MainActor).

Расследование (Explore + architecture-expert) + multiexpert-review плана (architecture-expert +
performance-expert) подтвердили швы спеки и внесли реализационные уточнения, зафиксированные в
«Decisions Made»: (1) live-провайдер — **actor** с блокирующим чтением на **выделенном serial
executor** (не общий cooperative-pool); (2) выделенный collaborator `DiskSpaceMonitor`;
(3) tick НЕ awaitит XPC inline — читает кэшированный вердикт, обновление fire-and-forget;
(4) инъекция часов в чистый калькулятор; (5) на общем томе — одно дорогое чтение; (6) byte-floor
как первичный сигнал стопа, ETA — вторичный.

## Technical Approach

Поток данных (соответствует спеке §Technical Approach):

```
RecordingConfiguration / RecordingPolicyTypes  (pure data: пороги, DiskThresholds, DiskVerdict, ETAEstimate)
        ▲                                   ▲
        │                                   │ uses (fallback averageBitrate)
DiskSpaceEstimator (pure, nonisolated)  ────┘   — сглаживание −Δ free-space, ETA (secondary, slope-gated),
        ▲                                          per-volume verdict, гистерезис, same-volume «строжайший»,
        │ evaluate(bytesFree×2, smoothedSpeed, ...) через inject-часы   byte-floor (primary stop)
DiskSpaceMonitor (@MainActor collaborator, owned by coordinator)
        │  caches latest DiskVerdict; fires non-awaited refresh Task at readEvery
        │  tick reads cached verdict SYNCHRONOUSLY (no inline XPC await)
        ▼                                        ▼ (fire-and-forget refresh)
RecordingCoordinator.tickTask (~1 Hz, MainActor)      DiskSpaceProviding (nonisolated protocol, async)
        │  cached verdict → warning UI-state / badge / notify;   ▲
        │  critical → break loop + Task { await self.stop() }    │
        ▼                                                  actor LiveDiskSpaceProvider
RecordingCoordinator.stop()  (idempotent, single funnel #243)      blocking read on DEDICATED serial executor;
                                                                   cheap volumeIdentifier compare FIRST,
                                                                   ONE ImportantUsage read when volumes equal
```

Ключевые механики:
- **Скорость** = сглаженная `−Δ(свободное место тома вывода)` (ловит нашу запись + сторонний
  расход + ОС). Окно `≥ 4× movieFragmentInterval` (~16с) при `readEvery ≈ movieFragmentInterval`
  → окно содержит **≥ 4 сэмпла** (2 сэмпла = отсутствие демпфирования; исправлено по
  perf-review). При скорости ≤ 0 абсолютный **byte-floor** остаётся активной страховкой.
  Источник — **только Δ free-space, без stat файлов** (спека). Никакого нового высокочастотного
  таймера — хук на существующем `tickTask`.
- **ETA — вторичный сигнал**: `...ImportantUsage` включает purgeable, чьи recompute-свинги
  (сотни МБ) могут ПРЕВЫШАТЬ истинную скорость (десятки МБ/интервал) → наклон −Δ зашумлён.
  Поэтому **byte-floor — первичный сигнал критического стопа**; ETA-производные пороги (warning
  ETA≤10мин, стоп ETA≤2мин) и headline «≈N мин» — вторичны и гейтятся по уверенности/монотонности
  наклона. L5 (AC-10) измеряет фактический SNR наклона при реальных битрейтах у заполнения; при
  SNR<1 ETA-warning гейтится, стоп остаётся на byte-floor.
- **I/O off-main, не крадёт cooperative-pool**: единственная блокирующая операция — синхронный
  XPC-читатель `volumeAvailableCapacityForImportantUsage` (вблизи заполнения дёргает CacheDelete и
  может спайкнуть до секунд). Изолирован в `actor LiveDiskSpaceProvider`, чей блокирующий read
  выполняется на **выделенном serial executor / DispatchQueue** (не на общем cooperative-пуле —
  иначе секундный блок крадёт поток у async-энкодера под load). `tickTask` НЕ awaitит XPC inline:
  монитор кэширует последний `DiskVerdict`, обновление идёт **fire-and-forget** task'ом с каденцией
  `readEvery`; tick читает кэшированный вердикт синхронно (elapsed/drops-каденция не проседает).
  **Дисциплина конкурентности refresh** (иначе near-full, где XPC-спайк > `readEvery`, задачи
  копятся и применяются out-of-order): (1) **single-in-flight** — новый refresh не стартует, пока
  предыдущий в полёте; (2) **generation-token** — монотонный счётчик, инкрементируемый в
  `reset()`/на старте сессии; продолжение refresh применяет результат ТОЛЬКО при совпадении
  поколения (`phase == .recording` недостаточен — неоднозначен между сессиями: pre-reset refresh
  мог бы контаминировать свежую сессию устаревшей near-full ёмкостью → ложный мгновенный стоп);
  (3) сэмплы ключуются инъектированным elapsed/счётчиком — estimator игнорирует out-of-order/дубли,
  окно сглаживания не портится. Off-main + on-dedicated-executor проверяется **эмпирически** (debug
  `assert(!Thread.isMainThread)` + `dispatchPrecondition(.onQueue(dedicatedQueue))` на пути чтения +
  os_signpost латентности), не постулируется «это actor».
- **Авто-стоп** — только через идемпотентный `stop()` и только `Task { await self.stop() }` вне
  тела tick (inline `await self.stop()` = дедлок: `performStopTeardown:774` ждёт `await tick?.value`).
  Прецедент именно `Task { await stop() }` — `RecordingCoordinator.swift:956` (`handleHotKey`).
  Контраст: revocation-путь `:700` использует INLINE `await self.stop()` и это безопасно ТОЛЬКО
  потому, что `revocationTask` НЕ ожидается в teardown (`:765-766`), в отличие от `tickTask`,
  который ожидается на `:774`. После `await` в fire-and-forget refresh — re-check
  `Task.isCancelled` / `phase == .recording` перед обработкой вердикта и постингом warning (иначе
  на останавливающейся сессии возможен спурьёзный warning).
- **Два тома**: `LiveDiskSpaceProvider` резолвит том вывода (`config.baseOutputDirectory`) и
  системный (`/System/Volumes/Data`). Сначала сравнивает ДЕШЁВЫЙ `volumeIdentifierKey` (локальный
  атрибут, не XPC); при совпадении (частый кейс — запись на внутренний диск) выполняет **ОДНО**
  дорогое `...ImportantUsage`-чтение и применяет обе политики к одному значению (строжайший
  вердикт — ветка в **чистом** калькуляторе); при разных томах — два чтения.
- **Доставка сигнала**: warning → MenuBarExtra бейдж + РАЗОВАЯ UserNotification (fullscreen
  скрывает строку меню); авто-стоп → UserNotification (причина + оба файла сохранены). Обе — по
  паттерну существующего `RecordingStartNotifier` (fire-and-forget Task, lazy UN-auth, silent
  fallback на denied, PII-free `os.Logger`), но в ОТДЕЛЬНОМ `DiskSpaceNotifier.swift` (не
  расширение `RecordingStartNotifier.swift` — снижает площадь merge-конфликта с sibling-веткой).
- **Ошибки/last-resort (AC-7)**: `AVError.Code.diskFull` (существует на macOS) → штатная
  финализация через существующий `lastWriteError`-канал; unplug внешнего тома вывода деградирует в
  writer-fault → тот же путь (НЕ disk-space-стоп). Ошибка чтения тома → монитор сохраняет
  последнее достоверное состояние (не мигает), idle → «оценка недоступна», авто-стоп по
  недостоверным данным ЗАПРЕЩЁН.

## Affected Modules & Files

| Path | Change | Note |
|---|---|---|
| `Onset/Configuration/RecordingConfiguration.swift` | Modified | Пороги (warn/critical по томам, ETA-пороги, окно ≥4× movieFragmentInterval, readEvery, warmupTicks, hysteresis) рядом с `movieFragmentInterval`/degraded-констант (:153-169) |
| `Onset/Recording/Pipeline/RecordingPolicyTypes.swift` | Modified | Pure `nonisolated`: `DiskThresholds`, `DiskVerdict` (`none/warning(reason)/critical(reason)` + явный `nonisolated static func ==`), `ETAEstimate` |
| `Onset/Recording/Pipeline/DiskSpaceEstimator.swift` | New | Pure `nonisolated` рядом с `CapabilityResolver` (:36): сглаживание (≥4 сэмпла) + ETA (slope-gated, secondary) + byte-floor (primary) + per-volume verdict + гистерезис + same-volume strictest + idle-оценка; fallback `averageBitrate(:203)` |
| `Onset/Recording/Pipeline/DiskSpaceProviding.swift` | New | `nonisolated protocol DiskSpaceProviding: Sendable` (async snapshot двух томов: free bytes + volume id); **`actor LiveDiskSpaceProvider`** — блокирующий read на выделенном serial executor, cheap volume-id compare → single read on same-volume, debug off-main assert |
| `Onset/UI/DiskSpaceMonitor.swift` | New | `@MainActor` collaborator: кэш последнего `DiskVerdict`, fire-and-forget refresh (readEvery), rolling free-space sample + injectable clock + one-shot warning guard + last-good state; Equatable-guard на запись состояния |
| `Onset/Permissions/DiskSpaceNotifier.swift` | New | `DiskSpaceWarningNotifying` seam + `Live*` + `Fake*` — ОТДЕЛЬНЫЙ файл (не расширение `RecordingStartNotifier.swift`); AC-9 (авто-стоп) + AC-12 (разовый warning) |
| `Onset/UI/RecordingCoordinator.swift` | Modified | New init deps `diskSpaceProvider`/`diskWarningNotifier` (live defaults; seam для fakes) + owned `DiskSpaceMonitor`; tick читает КЭШИРОВАННЫЙ вердикт (не awaitит XPC) + fire-and-forget refresh; warning state (Equatable-guarded) + de-escalation; auto-stop `Task { await self.stop() }` (break loop, прецедент :956); post-await isCancelled/phase re-check; disk-stop cause state; clear on new record; idle-оценка AC-1 |
| `Onset/UI/Main/MainViewModel.swift` | Modified | Отображает готовую idle-оценку «≈N мин»/«оценка недоступна» (по образцу `recordDisabledReason:531`); НЕ читает диск сам |
| `Onset/UI/MenuBar/*` (+ `MenuBarLabelMapper`) | Modified | Бейдж/лейбл отражает warning (AC-12a; поведение, не визуал), Equatable-guarded |
| `Onset/UI/Main/MainView*.swift`, `Onset/UI/Recording/*` | Modified | Pre-flight индикатор + warning-состояние (поведение/состояния) |
| `Onset/OnsetApp.swift` | Modified | Composition root: один `LiveDiskSpaceProvider` → coordinator (который делит его с `MainViewModel`). **НЕ в `RecordingSession`** (нет потребителя — pre-flight в UI-слое) |
| `docs/architecture.md` | Modified | Новые типы в type-level карте (CLAUDE.md: docs в том же PR) |
| `OnsetTests/*` | New | `FakeDiskSpaceProvider` (шаблон `FakeDisplaySleepPreventer`), `FakeDiskSpaceWarningNotifier`; unit-тесты пер-задача (см. `tasks.md`) |

## Decisions Made

| Decision | Choice | Rationale |
|---|---|---|
| Live-провайдер isolation | **`actor LiveDiskSpaceProvider`**, блокирующий read на **выделенном serial executor** | Actor — **безусловная** гарантия off-main независимо от upcoming-feature флагов (SE-0338/`NonisolatedNonsendingByDefault` — не полагаемся на них). Выделенный executor (не общий cooperative-пул) — чтобы секундный XPC вблизи заполнения не крал поток у async-энкодера под load. **Уточняет** спек-допущение «отдельный executor НЕ требуется» (perf-review flagged pool-starvation; стабильность-first). Off-main проверяется эмпирически (assert + signpost). |
| Disk-sample в tick | Tick читает КЭШИРОВАННЫЙ вердикт; refresh — fire-and-forget task (readEvery) | `await monitor.sample` inline в общем tick задержал бы elapsed/drops при медленном XPC. Кэш + non-awaited refresh сохраняет каденцию readout и остаётся на существующем tick (нового таймера нет — AC-2). |
| Конкурентность refresh | Single-in-flight (сброс `refreshInFlight` через `defer`) + generation-token + сэмплы по инъектированному счётчику | Fire-and-forget без дисциплины: near-full XPC-спайк > readEvery → backlog задач, out-of-order применение (перезапись свежего вердикта устаревшим), и pre-reset refresh на границе сессий даёт ложный стоп. Generation-token — единственный однозначный признак сессии (phase неоднозначен). `defer`-сброс обязателен — иначе reset во время медленного refresh навсегда заклинит refresh. |
| Разделение refresh/tick | refresh ТОЛЬКО пишет кэш-вердикт (под generation-guard); TICK читает кэш и РЕШАЕТ (warning-пост one-shot, critical break+`Task{stop}`) | Убирает противоречие diagram vs acceptance; все решения — на MainActor-serial tick, refresh не постит. |
| Тип snapshot через actor-границу | Только `Sendable` (`outputFreeBytes: Int64?`, `systemFreeBytes: Int64?`, `sameVolume: Bool`); raw `volumeIdentifier` НЕ пересекает границу | `URLResourceValues.volumeIdentifier` = `(NSCopying & NSObjectProtocol)?`, НЕ Sendable → не скомпилируется под strict concurrency. Actor резолвит id внутри, считает `sameVolume`, отдаёт наружу только Sendable. |
| Механизм off-pool чтения | Блокирующий read бриджится через `withCheckedContinuation` на приватную serial `DispatchQueue` (НЕ custom actor-wide `SerialExecutor`) | Обёртывает только блокирующий вызов — проще и менее инвазивно, чем custom executor на весь actor. `dispatchPrecondition(.onQueue(...))` доказывает on-dedicated-queue. |
| Сглаживание | EWMA по `Δ(free)/Δt`, time-constant = `ewmaTimeConstantSeconds` ≥4× movieFragmentInterval; pure `SmoothingState` (аккумулятор + variance), обновляется чистой функцией estimator'а | Один аккумулятор проще ring-buffer, естественно time-weighted; pure-функция → AC-5 тесты на чистом коде. `slopeConfidence` = SNR-прокси `|ewmaSpeed|/stddev(recentΔ)`, гейтит ETA при SNR<cutoff. |
| Disk-stop cause state | Отдельный НЕ-error `stoppedDueToLowSpace`; UserNotification (AC-9) — основная поверхность; НЕ реюзать `hasPendingAlert` (force-open окна для write-error) | Disk-stop graceful (файлы сохранены), не ошибка; force-open окна как у write-error здесь неуместен. |
| Idle DiskVerdict | idle-путь зовёт `idleEstimate` (headline «≈N мин») И `evaluate` (idle-вердикт для system/output warning) на одном snapshot; volume от ближайшего существующего предка | `idleEstimate` отдаёт только ETA; AC-3 допускает system-warning на idle → нужен и вердикт. `baseOutputDirectory` может не существовать → подниматься к предку. |
| Same-volume чтение | Cheap `volumeIdentifier` compare FIRST → ОДНО дорогое `...ImportantUsage` при совпадении | На внутреннем диске (частый кейс) оба тома совпадают; два одинаковых дорогих XPC впустую. Half XPC-стоимости. |
| Сглаживание | Окно `≥ 4× movieFragmentInterval` (~16с), readEvery ≈ movieFragmentInterval → **≥4 сэмпла** | 2 сэмпла (минимум из спеки) ≈ последняя дельта — не гасит flush-пачки. ≥4 даёт реальное демпфирование. Перф-компромисс: больше сэмплов = больше XPC (покрыт dedup + executor). |
| Сигнал стопа | byte-floor **primary**; ETA **secondary** (slope-confidence-gated) | purgeable recompute-свинги (сотни МБ) могут превышать истинную скорость (десятки МБ) → ETA-наклон зашумлён. Floor — надёжен; ETA гейтится по уверенности наклона; SNR меряется на L5. |
| Время для ETA | Инъектируемые часы / `(bytes, elapsedSeconds)` в чистый калькулятор | Bare `Date()` (:713) делает L2 ETA/oscillation-тесты wall-clock-зависимыми. Детерминизм для AC-5/AC-11. |
| Мониторинг-collaborator | Выделенный `DiskSpaceMonitor` (@MainActor, owned) | Rolling-sample + кэш + one-shot guard как loose-поля на ~1000-строчном координаторе эродируют cohesion. Координатор растёт на 1 property + 1 call, остаётся sole session-lifecycle state owner. |
| Источник скорости | Только `−Δ free-space`, без stat файлов | Спека: `RecordingControlling` не даёт размеры файлов; Δ free-space покрывает и нашу запись, и сторонний расход. |
| Путь авто-стопа | `Task { await self.stop() }` вне tick (прецедент :956), break loop | Inline `await self.stop()` в tick = self-await дедлок (teardown ждёт `tick.value`:774). :700 (revocation) — INLINE и безопасен лишь потому, что revocationTask НЕ awaited; tickTask awaited → нужен `Task {}`. |
| Same-volume «строжайший» | Ветка в **чистом** калькуляторе, не в провайдере | Провайдер отдаёт сырые ёмкости + volume id; политика (строжайший) — pure-логика (тестируема без I/O). |
| Warning notifier | ОТДЕЛЬНЫЙ `DiskSpaceNotifier.swift` (не расширяем `RecordingStartNotifier`) | Разные тексты/жизненный цикл; + снижает merge-конфликт с sibling-веткой `critical-recording-signals` (правит `RecordingStartNotifier.swift`). |
| Доставка сигнала | warning = badge + разовая UN; авто-стоп = UN | Окна в фоне; fullscreen скрывает строку меню, баннеры UN показываются. |
| Idle-оценка (AC-1) владелец / каденция | Координатор считает (владеет провайдером), MainViewModel отображает; **one-shot по появлению экрана** + пересчёт при инициации записи (staleness на idle принимается) | idle-read `...ImportantUsage` синхронно на MainActor = блокирующий XPC. Polling на idle = невидимый scope + XPC-стоимость; one-shot проще, staleness несущественна на idle. Через тот же off-main провайдер. |
| Пороги (числа) | Сист. warn ≤10ГБ/стоп ≤5ГБ; вывод warn ETA≤10мин\|≤10ГБ/стоп ≤2ГБ\|ETA≤2мин | Reasoned defaults (гипотеза); калибровка AC-10. В конфиг-слое, не хардкод. |

## Risks & Mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| Авто-стоп из tick self-дедлочит teardown | Critical | `Task { await self.stop() }` вне tick + break loop; прецедент :956; тест идемпотентного стопа (T6) |
| Блокирующий XPC стопорит MainActor / крадёт cooperative-pool под load | Critical | `actor` + **выделенный serial executor**; fire-and-forget refresh (tick не awaitит); `readEvery` каденция; эмпирика: assert off-main + os_signpost латентности + encoder-throughput у заполнения (AC-10 T11) |
| **Merge-collision с sibling-веткой `critical-recording-signals`** (unmerged f087d5a правит `RecordingCoordinator.swift`, `RecordingStartNotifier.swift`, тесты, `FakeRecordingStartNotifier`) | Major | Отдельный `DiskSpaceNotifier.swift` (не трогаем `RecordingStartNotifier`); дождаться мержа critical-recording-signals ИЛИ ребейз-первым; после мержа любой из веток — обновить branch (memory: #118 vs #104 прецедент) |
| ETA-наклон тонет в purgeable-шуме (SNR<1) | Major | byte-floor primary; ETA secondary + slope-confidence gate; L5 меряет SNR (AC-10) |
| `...ImportantUsage` переоценивает (purgeable + APFS shared free) | Major | Консервативный floor поглощает; калибровка вблизи заполнения (AC-10) |
| VBR-всплески / flush-пачки → ложный порог | Major | Сглаживание ≥4 сэмпла (окно ≥4× movieFragmentInterval); гистерезис (AC-11 oscillation-тест) |
| Преждевременный авто-стоп теряет сессию | Major (product) | Асимметрия к сохранности: warning заблаговременно (10мин/10ГБ), авто-стоп крайняя мера |
| Ошибка чтения тома → авто-стоп по мусору | Major | Не авто-стопить по недостоверным данным; last-good состояние (не мигать); idle → «оценка недоступна» |
| DiskVerdict enum под `InferIsolatedConformances` инферит `@MainActor ==` | Major (build) | Явный `nonisolated static func ==` witness |
| **Out-of-order / cross-session refresh** (fire-and-forget + near-full XPC-спайк > readEvery): устаревший сэмпл перезаписывает свежий; pre-reset refresh контаминирует новую сессию → ложный стоп | Major | Single-in-flight guard + **generation-token** (совпадение поколения, не только phase) + сэмплы по инъектированному счётчику; тесты «overlapping slow refresh не портит окно», «pre-reset refresh не контаминирует новую сессию» (T-4) |
| **Detection-staleness съедает 2ГБ-запас**: лаг детекции = `readEvery` + XPC-латентность до стопа, поверх времени финализации | Major | AC-10 калибрует `outputStopBytes` от `finalization_bytes + (readEvery + worst_XPC_latency) × max_speed`, не только от времени финализации (T-11) |
| Спурьёзный warning на останавливающейся сессии (stop во время refresh) | Minor | Post-await generation/`phase` re-check перед постингом; тест stop-during-refresh |
| Per-tick `@Observable` churn от безусловной записи warning-state | Minor | Equatable-guard: писать только при изменении вердикта |

## Verification & Sources

- **Источник истины**: approved spec `docs/specs/2026-07-18-disk-space-management.md` (12 AC,
  authoritative definition of done) + research `swarm-report/research/research-disk-space-thresholds.md`.
  Собран и достаточен: каждый AC фальсифицируем; `tasks.md` даёт implementation-level проверку на
  каждый AC-N (полная трассировка AC-1…AC-12 → задачи — см. §Traceability в `tasks.md`).
- **Prerequisites (verify-library-api gate, до кода)**: `...ImportantUsage` тип Int64? + `volumeIdentifierKey`
  на macOS 26 → T-2 (Xcode Quick Help); `AVError.Code.diskFull` (подтверждён apple-docs, есть на
  macOS) → T-6 AC-7; UserNotifications-инфра (подтверждена в main: `RecordingStartNotifier.swift`)
  → T-5. Каждый прикреплён к acceptance своей задачи.
- **Тип задачи**: Фича с UI-поверхностью → пирамида **L0 → L1 → L2 → L5**. L3/L4 не применяются —
  UI-часть (бейдж, текст оценки) проверяется L5 + скриншот; логика — L2.
- **L0/L1**: `scripts/preflight.sh` (build + swiftformat `--lint .` + swiftlint `--strict` +
  privacy-manifest) — gate на каждый push.
- **L2 (unit, Swift Testing)**: чистый `DiskSpaceEstimator` (ETA, byte-floor, сглаживание ≥4
  сэмпла, гистерезис на осциллирующем вводе — AC-5/AC-11) с инъектируемыми часами; `DiskSpaceMonitor`
  с `FakeDiskSpaceProvider` (кэш/refresh/last-good); идемпотентный авто-стоп + валидная финализация
  (AC-4/AC-8); AC-7 last-resort regression; де-эскалация (AC-11); two-volume strictest (AC-6).
  TDD для калькулятора.
- **L5 (reference HW, MX Brio, signed build, `ONSET_RUN_L5_CAPTURE=1`)**: калибровка AC-10 —
  том вывода на size-capped APFS-том / sparse disk image с квотой. Подтвердить: (а) штатный стоп +
  валидные файлы (ffprobe moov, длительности ± movieFragmentInterval); (б) время финализации в
  2ГБ-запасе — **учитывая ОБА слагаемых против запаса: `finalization_bytes + (readEvery +
  measured_worst_XPC_latency) × max_representative_speed ≤ outputStopBytes`** (детекция кэш-вердикта
  устаревает на `readEvery` + near-full XPC-латентность — место расходуется всё это время; при
  недостаточности запаса калибровать `outputStopBytes` вверх или `readEvery` вниз до merge);
  (в) purgeable у заполнения; (г) **перф-бюджет как ДЕЛЬТА к WITHOUT-baseline**: N
  прогонов WITH-vs-WITHOUT под representative-load — критерий «нет НОВЫХ hang'ов относительно
  baseline» + жёсткий микро-бюджет on-main обработки вердикта (<1-2 мс, os_signpost) + полоса
  допуска на дельту `encoderBackpressureDrops`; + латентность провайдер-чтения (signpost) и
  отсутствие деградации async-throughput энкодера у заполнения; (д) SNR наклона −Δ при реальных
  битрейтах. Расхождения → правка порогов / гейтинг ETA до merge. Порог 250мс из спеки заменён на
  delta-baseline + суб-мс микро-бюджет (perf-review: 250мс на 2-3 порядка слабее заявленного
  бюджета). L5 закрывается на target Mac.
- **Before-state**: не миграция — новая фича; baseline не требуется. Существующий disk-full
  postмортем (`lastWriteError`) сохраняется как last-resort (AC-7), не регрессирует (T-6 тест).

## Out of Scope

Наследует спеку: визуальный дизайн индикаторов (owner: владелец через Claude Design service);
процентные/`clamp`-пороги; блокировка старта при малом месте (только предупреждение); выбор
контейнера (MKV vs MP4); автоочистка/предложение удалить файлы; покадровый реальный битрейт
энкодера как источник ETA. Плюс план-уровень: никакого нового высокочастотного таймера; никакого
filesystem-stat растущих файлов; polling idle-оценки (one-shot по появлению экрана).

## Open Questions

- [non-blocking] Pre-flight при КРИТИЧЕСКИ малом месте на старте: (A) предупредить, разрешить старт;
  (B) заблокировать. **Применяется (A)** (спека Open Question recommendation — согласуется с AC-1 +
  асимметрией; last-resort всё равно защитит). Владелец может переопределить; реализуется в T7.
