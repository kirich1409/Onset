---
type: tasks
slug: recording-backend-selection
---

# Tasks: recording-backend-selection

Порядок учитывает зависимости. Каждая задача — один сфокусированный проход.

## T-1 — Типы выбора бэкенда

**Files:** `Onset/Configuration/BackendSelectionTypes.swift` (new),
`Onset/Configuration/BackendSelectionKeys.swift` (new)

THE SYSTEM SHALL определить per-stage enum'ы `SourceBackend`, `EncoderBackend`,
`WriterBackend` (каждый single-case `.live`), агрегат `ResolvedBackendSelection` (три
поля), сырой `PersistedBackendSelection`, и ОДИН UserDefaults-ключ.

- Каждый enum: ручной `nonisolated static func ==` (precedent `VideoCodec`/`Container`,
  `RecordingPolicyTypes.swift`), без raw type, без `Hashable`.
- **Canonical raw-строка на кейс** для (де)сериализации — явная, не зависящая от имени
  Swift-кейса: `var rawString: String` / `init?(rawString:)` (напр. `.live → "live"`).
  Резолвер сверяет именно эту строку; без канонизации «unknown string» сработает на смену
  регистра.
- `PersistedBackendSelection`: `Codable, Equatable` (synthesized; T-3 round-trip `==` это
  требует). Поля — именованные опциональные строки `source: String?`, `encoder: String?`,
  `writer: String?` (имена полей = Codable-ключи, зафиксированы).
- `ResolvedBackendSelection` — три поля `SourceBackend`/`EncoderBackend`/`WriterBackend`.
  `.allLive` НЕ вводится (резолвер возвращает all-`.live` для nil; отдельная константа не
  потребляется → была бы unused под strict lint).
- **Один ключ** в `BackendSelectionKeys.swift`: весь `PersistedBackendSelection` хранится
  как единый JSON-блоб (не три ключа).
- **Doc-comments на ВСЕ non-private декларации**, включая enum-кейсы и stored properties
  struct'ов (`missing_docs` strict — иначе build error).
- **Acceptance:** L0 build зелёный; `swiftlint --strict` (включая `missing_docs`) и
  `swiftformat --lint .` зелёные. Типы компилируются под default MainActor isolation без
  warning (warnings-as-errors).

## T-2 — Pure-резолвер + L2-тесты `after: T-1`

**Files:** `Onset/Storage/RecordingBackendResolver.swift` (new),
`OnsetTests/RecordingBackendResolverTests.swift` (new)

THE SYSTEM SHALL предоставить `nonisolated enum RecordingBackendResolver` с
`resolve(persisted: PersistedBackendSelection?, supported: SupportedBackends) -> ResolvedBackendSelection`,
который для каждой стадии: nil → `.live`; неизвестная сырая строка → `.live`;
известная но `!supported` → `.live`; известная и supported → выбранное значение.
Каждая fallback-ветка пишет `os.Logger` `warning` (имя нераспознанного/неподдержанного
бэкенда, без PII).

Плюс value-тип `SupportedBackends` — **конкретная форма**: struct с Bool-полями на стадию
(`isSourceLiveSupported`/`isEncoderLiveSupported`/`isWriterLiveSupported`) + `static let
allSupported` (все `true`). Bool-форма позволяет тесту «known-but-unsupported» собрать
instance с ровно одним `false`. (По АНАЛОГИИ с `DeviceSelectionResolver`, НЕ дословное
зеркало: там второй параметр — `[String] availableIDs`, здесь — этот struct; семантика
второго параметра отличается.)

- Given persisted=nil, When resolve, Then все стадии `.live`.
- Given persisted с неизвестной строкой в одной стадии, When resolve, Then та стадия
  `.live`, остальные по записи.
- Given known-but-unsupported, When resolve, Then `.live` fallback.
- **Acceptance / check:** новый suite `RecordingBackendResolverTests` зелёный в Swift
  Testing summary; покрывает все четыре ветки. Резолвер `nonisolated`, без обращения к
  фреймворкам/железу (чистая функция).

## T-3 — Persisted store + L2-тесты `after: T-1`

**Files:** `Onset/Storage/BackendSelectionStore.swift` (new),
`OnsetTests/BackendSelectionStoreTests.swift` (new)

THE SYSTEM SHALL предоставить `protocol BackendSelectionPersisting: Sendable` с
сигнатурами `func save(_ selection: PersistedBackendSelection)`,
`func load() -> PersistedBackendSelection?`, `func clear()`; и
`struct UserDefaultsBackendSelectionStore(defaults: UserDefaults = .standard)`, зеркало
`UserDefaultsDeviceSelectionStore` (`DeviceSelectionStore.swift:92`): один ключ, весь
struct как JSON (`JSONEncoder`/`JSONDecoder`), включая guard
`isRunningUnderXCTest && defaults === .standard → assertionFailure`.

- Given сохранённый `PersistedBackendSelection`, When load, Then равен сохранённому
  (round-trip на `InMemoryUserDefaults`).
- Given clear, When load, Then nil.
- Given повреждённые/legacy-данные под ключом, When load, Then nil (не падение).
- **Acceptance / check:** `BackendSelectionStoreTests` зелёный, использует
  `InMemoryUserDefaults` (`OnsetTests/ScopedDefaults.swift`), НЕ `UserDefaults.standard`.

## T-4 — Проводка в `RecordingSession` + composition root `after: T-2, T-3`

**Files:** `Onset/Recording/Pipeline/RecordingSession.swift` (modify),
`Onset/UI/RecordingCoordinator.swift` (modify)

THE SYSTEM SHALL держать выбор реализации ЦЕЛИКОМ в composition root, не в сессии.

**DI-механика store (важно — Swift-ограничение):** default-значение замыкания
`sessionFactory` НЕ может ссылаться на другой параметр `RecordingCoordinator.init`
(включая store). Поэтому резолв НЕ делается внутри default-замыкания. Вместо этого:
- `RecordingCoordinator.init` получает параметр `backendStore: any BackendSelectionPersisting = UserDefaultsBackendSelectionStore()`, сохраняемый как property.
- Резолв происходит в `start(_:)` (там доступен `self.backendStore`): `let resolved = RecordingBackendResolver.resolve(persisted: backendStore.load(), supported: .allSupported)`.
- Сигнатура `sessionFactory` расширяется до `(RecordingRequest, ResolvedBackendSelection) -> any RecordingControlling`; `start` вызывает `sessionFactory(request, resolved)`. Default-замыкание строит из `resolved`: `switch` по source/encoder → `Live*` фабрики (в существующие параметры), `switch` по writer → writer-builder (в `writerFactoryBuilder`). Тесты, инжектящие `sessionFactory`, обновляют сигнатуру на 2 аргумента (второй игнорируют).

`RecordingSession.init` НЕ получает параметр `backendSelection`. Новый параметр —
ОПЦИОНАЛЬНЫЙ `writerFactoryBuilder: (@escaping @Sendable (@escaping @Sendable (RecordingPipelineKind) -> URL) -> any WriterFactory)? = nil`
(внешнее замыкание `@escaping` — хранится как stored property; без него не скомпилируется).
Swift-дефолт не может ссылаться на `config`, поэтому live-fallback строится в теле init.
Трёхзвенная precedence-цепочка:
`self.writerFactory = explicitWriterFactory ?? writerFactoryBuilder?(urlProvider) ?? inlineLiveDefault(urlProvider)`
(explicit override → production builder → inline `LiveWriterFactory(config, urlProvider)`).

- Существующие `sourceFactory`/`encoderFactory` (+Live-дефолты) и `writerFactory`-override
  сохранены; для source/encoder параметр-фабрика — единственный источник истины.
- Production-путь со всеми `.live` строит ровно текущие `Live*` фабрики (включая
  `LiveWriterFactory` с внутренним `urlProvider`) — поведение 1:1 с текущим.
- **Acceptance / check:**
  - L0 build зелёный; **вся существующая L2 suite зелёная без правок тестов** (тесты
    инжектят `Fake*` фабрики напрямую) — доказывает behavior-identical проводку.
  - **Negative** named-тест `writerExplicitFactoryWinsOverBuilder`: Given явный
    `writerFactory` И `writerFactoryBuilder`, When init, Then используется явный (builder
    НЕ вызван).
  - **Positive** named-тест `writerBuilderUsedWhenNoExplicitFactory`: Given
    `writerFactory == nil` И заданный `writerFactoryBuilder`, When init, Then используется
    фабрика из builder'а, и builder вызван с `urlProvider` сессии. (Покрывает новый
    production-путь — существующая suite его НЕ исполняет, т.к. инжектит explicit Fake.)
    Механика: `writerFactory` приватен (`RecordingSession.swift:128`) и не Equatable →
    тест строит **спай на самом builder-замыкании** (box фиксирует `invoked` + захватывает
    `urlProvider`); ассерт `invoked == true` и что вызов захваченного `urlProvider` даёт
    URL под `sessionDir`. Не вскрывать приватное свойство. Конструкция: передать `config`
    с известным tmp `baseOutputDirectory`, проверить
    `capturedUrlProvider(kind).path.hasPrefix(session.sessionDirectory.path)`.
  - `git diff`: дефолты `sourceFactory`/`encoderFactory` не удалены; параметра
    `backendSelection` в init нет.

## T-5 — Документация `after: T-4`

**Files:** `docs/architecture.md` (modify); `PrivacyInfo.xcprivacy` (verify)

THE SYSTEM SHALL задокументировать selection seam в `docs/architecture.md` (русский):
per-stage enum'ы, резолвер, store, точка проводки; явно — что fused-бэкенд вне этой
модели. Проверить privacy manifest.

- **Acceptance / check:** `scripts/check-privacy-manifest.sh` зелёный (подтвердить: новый
  ключ покрыт существующим Required-Reason, или добавить корректный код из
  `USERDEFAULTS_VALID_REASONS`). `docs/architecture.md` описывает seam. Полный
  `scripts/preflight.sh` зелёный.
