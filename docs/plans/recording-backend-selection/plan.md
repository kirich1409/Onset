---
type: plan
slug: recording-backend-selection
date: 2026-06-23
status: approved
spec: none
risk_areas:
  - concurrency (Swift 6 strict, default MainActor isolation, nonisolated pure resolver)
  - test-store-isolation (#227/#247 — UserDefaults.standard под XCTest запрещён)
  - privacy-manifest (Required-Reason для UserDefaults)
  - minimal-diff (не сломать существующий test-seam инъекции фабрик)
review_verdict: PASS
review_blockers: []
---

# План: config-driven персистентный выбор бэкенда записи

## Context & Decision

Конвейер записи Onset уже имеет три независимых DI-seam'а, инжектируемых в
`RecordingSession.init` (`Onset/Recording/Pipeline/RecordingSession.swift:194-196`),
каждый с дефолтом на live-реализацию:

- `sourceFactory: any SourceFactory = LiveSourceFactory()` — захват (`VideoFrameSource`)
- `encoderFactory: any EncoderFactory = LiveEncoderFactory()` — кодирование (VideoToolbox)
- `writerFactory: (any WriterFactory)? = nil` — мукс в файл (`AVAssetWriter`)

Composition root `RecordingCoordinator.swift:317` строит сессию **без** передачи
фабрик, поэтому production всегда получает `Live*`. Выбор бэкенда сейчас захардкожен
дефолтами аргументов Swift.

**Решённое изменение** (подтверждено пользователем): добавить config-driven
**персистентный** выбор реализации **по каждой стадии независимо** (source / encoder /
writer), чтобы можно было переключать и сравнивать технологии записи. Это позволит
будущим альтернативам (CMIO-источник для #177/#178, альтернативный muxer) встать в
готовый seam без правки `RecordingSession`.

**Scope: ТОЛЬКО механизм выбора + проводка + персистентность + fallback.** Никаких
новых реализаций бэкендов в этом плане.

Источника-спеки нет (изменение меньше фичи); план работает от описания задачи. Связь с
архитектурным долгом #155 (multi-source) ортогональна: #155 про набор пайплайнов, здесь
про выбор реализации стадии внутри пайплайна.

## Technical Approach

Зеркалим существующий, проверенный в проекте паттерн выбора устройства:
**persisted record → pure resolver → decision value**, аналог
`DeviceSelectionStore` + `DeviceSelectionResolver` (`Onset/Storage/`).

1. **Per-stage enum'ы выбора** (`SourceBackend`, `EncoderBackend`, `WriterBackend`) —
   single-case сейчас (`.live`), по precedent'у `VideoCodec`/`Container`
   (`RecordingPolicyTypes.swift`): ручной `nonisolated static func ==`, без raw type,
   без `Hashable`. Плюс агрегат `ResolvedBackendSelection` (три выбранных значения,
   fallback уже применён) и `PersistedBackendSelection` (Codable сырой формат для prefs).

2. **Pure-резолвер** `RecordingBackendResolver` (`Onset/Storage/`), `nonisolated enum`,
   зеркало `DeviceSelectionResolver`:
   `resolve(persisted: PersistedBackendSelection?, supported: SupportedBackends) -> ResolvedBackendSelection`.
   Логика: nil / неизвестная строка / неподдержанная на этом железе реализация →
   fallback на `.live`, с `os.Logger` `warning`-логом в ветке fallback (имя
   нераспознанного/неподдержанного бэкенда — без PII), чтобы расхождение persisted vs
   supported не было невидимым. **Это load-bearing тестируемая поверхность плана**
   (аналог `.disconnected`-пути в `DeviceSelectionResolver`).

3. **Persisted store** — `protocol BackendSelectionPersisting` + struct
   `UserDefaultsBackendSelectionStore(defaults: UserDefaults = .standard)` в
   `Onset/Storage/`, зеркало `UserDefaultsDeviceSelectionStore`. Обязателен guard
   `isRunningUnderXCTest && defaults === .standard → assertionFailure` (#227/#247).
   Ключи — в `Onset/Configuration/` рядом с `DeviceSelectionKeys.swift`.

4. **Проводка решения — выбор целиком в composition root, НЕ в сессии.** В
   `sessionFactory`-замыкании (`RecordingCoordinator.swift:317`): прочитать store →
   `RecordingBackendResolver.resolve(...)` → получить `ResolvedBackendSelection`. Дальше
   root сам конструирует реализации из enum'ов и передаёт их в `RecordingSession.init`
   через **существующие** параметры:
   - `source`/`encoder`: zero-param фабрики — root строит `switch` по
     `SourceBackend`/`EncoderBackend` (сейчас `.live → LiveSourceFactory()` /
     `LiveEncoderFactory()` напрямую, без wrapper) и передаёт через существующие
     `sourceFactory`/`encoderFactory`. `RecordingSession.init` НЕ получает enum выбора —
     для этих стадий параметр-фабрика остаётся единственным источником истины.
   - `writer`: зависит от внутреннего `urlProvider`, поэтому root передаёт **builder-
     замыкание** через опциональный параметр
     `writerFactoryBuilder: (@escaping @Sendable (@escaping @Sendable (RecordingPipelineKind) -> URL) -> any WriterFactory)? = nil`,
     выбранное `switch`'ем по `WriterBackend` (сейчас `.live → { urlProvider in LiveWriterFactory(configuration: config, urlProvider: urlProvider) }`).
     Сессия вызывает builder со своим `urlProvider` (`RecordingSession.swift:250-256`,
     владение timestamp-сегментом #198 не вытаскивается из сессии). Точная precedence —
     см. test-seam ниже (трёхзвенная цепочка).

   Выбор enum→concrete-backend живёт в root; `RecordingSession` получает готовые
   source/encoder фабрики и опциональный writer-builder. Inline live-fallback writer'а
   остаётся в сессии как дефолт — по аналогии с Live-дефолтами `sourceFactory`/
   `encoderFactory` (см. test-seam ниже), это не регрессия и не «второй composition
   root»; *выбор* бэкенда там не происходит. Параметра `backendSelection` в init НЕТ (он
   был бы мёртвым кодом при non-nil Live-дефолтах фабрик).

### Семантика test-seam (источник истины в init)

- `sourceFactory`/`encoderFactory`: один параметр на стадию — он И есть выбор. Тесты
  инжектят `Fake*`; production передаёт резолвнутый `Live*`. Никакой второй источник
  истины не вводится.
- `writer`: **трёхзвенная precedence-цепочка** (Swift не даёт дефолту параметра
  ссылаться на другой параметр `config`, поэтому live-fallback строится в теле init, где
  `config`/`sessionDir`/`startDate` в скоупе — текущие `RecordingSession.swift:250-256`):

  ```
  self.writerFactory = explicitWriterFactory           // 1. explicit override (тесты), default nil
                    ?? writerFactoryBuilder?(urlProvider) // 2. production builder, параметр default nil
                    ?? inlineLiveDefault(urlProvider)     // 3. inline LiveWriterFactory(config, urlProvider) в теле init
  ```

  Оба новых параметра объявлены опциональными с `= nil`. Порядок: explicit override →
  production builder → inline live default. Контракт — acceptance с **двумя** именованными
  тестами (T-4): negative (explicit выигрывает, builder не вызван) И positive (при
  `writerFactory == nil` используется builder, вызван с `urlProvider` сессии).

## Affected Modules & Files

| Path | Change | Note |
|---|---|---|
| `Onset/Configuration/BackendSelectionTypes.swift` | new | enum'ы `SourceBackend`/`EncoderBackend`/`WriterBackend` (single-case `.live`) + ручной `nonisolated ==`; `ResolvedBackendSelection` (+ `.allLive`); `PersistedBackendSelection` (Codable). |
| `Onset/Configuration/BackendSelectionKeys.swift` | new | UserDefaults-ключи, рядом с `DeviceSelectionKeys.swift`. |
| `Onset/Storage/BackendSelectionStore.swift` | new | `BackendSelectionPersisting` + `UserDefaultsBackendSelectionStore`. XCTest-guard. |
| `Onset/Storage/RecordingBackendResolver.swift` | new | pure `nonisolated enum`, `resolve(persisted:supported:)`, fallback → `.live`. + `SupportedBackends`. |
| `Onset/Recording/Pipeline/RecordingSession.swift` | modify | НЕТ параметра `backendSelection`. Существующие `sourceFactory`/`encoderFactory` (+ Live-дефолты) сохранены. `writerFactory: (any WriterFactory)?` сохранён (explicit override); ДОБАВИТЬ опциональный `writerFactoryBuilder: (...)? = nil`; init: трёхзвенная цепочка `explicit ?? builder?(urlProvider) ?? inlineLiveDefault(urlProvider)` (см. test-seam). |
| `Onset/UI/RecordingCoordinator.swift` | modify | ДОБАВИТЬ `backendStore: any BackendSelectionPersisting = UserDefaultsBackendSelectionStore()` param (Swift-дефолт замыкания `sessionFactory` не может захватить store). Резолв в `start(_:)` (там доступен `self.backendStore`); `sessionFactory` расширяется до `(RecordingRequest, ResolvedBackendSelection) -> any RecordingControlling`; default-замыкание строит `Live*` source/encoder (в существующие параметры) + writer-builder из `resolved`. Здесь живёт всё enum→concrete-знание. Тест-инъекции `sessionFactory` обновляют сигнатуру (2 арг). |
| `OnsetTests/RecordingBackendResolverTests.swift` | new | L2 на fallback/validation резолвера (pure, без железа). |
| `OnsetTests/BackendSelectionStoreTests.swift` | new | L2 save/load/clear round-trip на `InMemoryUserDefaults`. |
| `docs/architecture.md` | modify | раздел про selection seam (русский). |
| `PrivacyInfo.xcprivacy` | verify | новый ключ читается существующим UserDefaults-механизмом; проверить, что Required-Reason уже покрывает (новый КОД скорее не нужен — новый ключ, не новый API-доступ). `scripts/check-privacy-manifest.sh` остаётся зелёным. |

## Decisions Made

- **D-1: Per-stage выбор (Option B), не единый `RecordingBackend` (Option A).**
  Стадии уже независимы в коде; protocol'ы стадий — и есть контракт совместимости; на
  роадмапе нет невалидных комбинаций (codec pinned `.hevc`, AC-4). B масштабируется
  аддитивно **в рамках трёхстадийной топологии** (один case на реализацию стадии);
  fused-бэкенд (SCRecordingOutput) — смена топологии, НЕ drop-in case (см. Out of Scope).
  Известный roadmap (CMIO #177/#178) — замена source, топологически совместим. Имена
  per-stage (`SourceBackend`/…), НЕ singular `RecordingBackend` (тот подразумевает A).
  Источник: architecture-expert.
- **D-2: Резолвер возвращает decision-значения, не фабрики.** Конструирование фабрик
  тянет runtime/closure (`urlProvider`) через nonisolated-границу и ломает правило
  «pure logic + impure actor». Pure-тип только решает.
- **D-3: Выбор реализации целиком в composition root, не в `RecordingSession`.**
  Source/encoder — zero-param, root строит их из enum и передаёт через существующие
  параметры; для них в сессию выбор не входит вовсе. Writer зависит от внутреннего
  `urlProvider` (`RecordingSession.swift:250-256`, #198) → root передаёт builder-замыкание
  `(urlProvider) -> any WriterFactory`, сессия вызывает его со своим url-provider. Сессия
  остаётся чистым DI-приёмником; всё enum→concrete-знание в одном месте (root). Параметра
  `backendSelection` в init НЕТ — при non-nil Live-дефолтах фабрик он был бы мёртвым кодом
  (поправлено по architecture-expert cycle 1).
- **D-4: Backend selection НЕ кладём в `RecordingConfiguration`.** Тот тип — value
  *policy*; backend identity — *behavior-selection*. Персист храним per-stage (отдельный
  store), чтобы будущая смена топологии не инвалидировала сохранённые prefs.
- **D-5: Single-case enum сейчас** (scaffold), по precedent'у `VideoCodec`/`Container`.
  Команда уже так скаффолдит (#82). Второй case добавит соответствующий backend-тикет.
- **D-6: Без UI в этом плане.** Выбор персистится и резолвится; пользовательский
  контрол (Settings, #79/#80) — отдельная задача. Сейчас выбор задаётся программно/в
  тестах/вручную в prefs. (UI агентами не делается — принцип проекта.)

## Risks & Mitigations

- **R-1 — «нечего тестировать» (один impl на стадию).** Митигация: тестируем
  fallback/validation резолвера сейчас (nil/unknown/unsupported→`.live`); честно
  заявляем, что end-to-end переключение не воспроизводимо до второй реализации (D-5).
- **R-2 — загрязнение `UserDefaults.standard` в тестах.** Митигация: XCTest-guard в
  store + `InMemoryUserDefaults` в тестах (#227/#247).
- **R-3 — поломка test-seam.** Существующие тесты инжектят все три фабрики напрямую.
  Митигация: `sourceFactory`/`encoderFactory` (+Live-дефолты) и `writerFactory`-override
  параметр остаются; добавляется только `writerFactoryBuilder` (default nil → текущий
  live-builder). Без `backendSelection` в init нет двух источников истины для
  source/encoder. L0/L2 прогон существующей suite без правок тестов подтверждает
  behavior-identical (доказывает корректность проводки).
- **R-4 — privacy manifest (вероятно no-op).** Required-Reason декларации per-API-type, не
  per-key; UserDefaults уже используется (`DeviceSelectionStore`), значит код причины уже в
  манифесте — новый ключ правок не требует. Митигация: проверить наличие кода; если есть —
  снять как работу (T-5 verify-only); `check-privacy-manifest.sh` остаётся зелёным.
- **R-5 — concurrency (enum под default MainActor isolation).** Митигация: ручной
  `nonisolated static func ==` на enum'ах (precedent); резолвер `nonisolated`.

## Out of Scope

- Реализация любого второго бэкенда: CMIO/IOKit-источник (#177/#178), `SCRecordingOutput`,
  кастомный muxer.
- Fused capture+encode бэкенд (`SCRecordingOutput`) — не раскладывается на три стадии;
  это смена *топологии* seam'а, отдельная задача на уровне composition root, НЕ case в
  этих enum'ах.
- Параметризация текущих `FileWriter`/`VideoEncoder`: кодек/контейнер (#82), HDR (#169),
  timecode (#231) — это config-параметры, не свап бэкенда.
- UI выбора бэкенда (Settings, #79/#80).

## Open Questions

- **(non-blocking)** Нужен ли `SupportedBackends` уже сейчас при одном impl на стадию?
  Минимально — да, как точка для будущей host-capability проверки; сейчас возвращает
  «все известные поддержаны». Заложить тип, не раздувать логику.
