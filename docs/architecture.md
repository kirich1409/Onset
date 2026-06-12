# Архитектура Onset — карта кода

Детальная карта подсистем: назначение, ключевые типы, навигационные указатели и
конвенции. Срез по состоянию `main`; обновляется в том же PR, что меняет структуру.
Сжатая версия для агентов — в корневом `CLAUDE.md` (раздел Project structure).

## Захват — `Onset/Recording/Capture/`

Получение видеокадров и аудиосэмплов с камер и дисплеев в `AsyncStream`,
с синхронизацией по host-clock и учётом drop'ов от backpressure.

| Тип | Файл | Роль |
|---|---|---|
| `VideoFrameSource` | `CaptureSource.swift` | Протокол видеоисточника: frames/drops/events через AsyncStream, actor-isolated start/stop |
| `AudioSampleSource` | `CaptureSource.swift` | Протокол аудиоисточника: samples/drops через AsyncStream |
| `CameraSource` | `CameraSource.swift` | Актор: камера+микрофон через `AVCaptureSession`, реализует оба протокола |
| `ScreenSource` | `ScreenSource.swift` | Актор: захват дисплея через ScreenCaptureKit, обрабатывает hot-plug отключение |
| `CameraDevice` | `CaptureDeviceModels.swift` | Иммутабельный снапшот камеры (uniqueID + форматы), без живых ссылок на `AVCaptureDevice` |
| `Display` | `CaptureDeviceModels.swift` | Иммутабельный снапшот дисплея: `CGDirectDisplayID`, размеры, частота |
| `DeviceDiscovery` | `DeviceDiscovery+Displays.swift`, `DeviceDiscovery+CaptureDevices.swift` | Nonisolated-перечисление устройств с чистыми мапперами для тестов; suspended-устройства (`isSuspended`, например FaceTime-камера при закрытой крышке) исключаются из результатов |
| `DeviceAvailabilityObserver` | `DeviceAvailabilityObserver.swift` | Поток событий топологии устройств (`DeviceChangeEvent`): NotificationCenter connect/disconnect + KVO `isSuspended`; время жизни привязано к стриму (teardown через `onTermination`) |
| `ScreenStreamConfigurationBuilder` | `ScreenStreamConfigurationBuilder.swift` | Чистый билдер `ResolvedRecordingPlan` → `SCStreamConfiguration` |

Где искать:

- Конвертация host-clock (`CMSyncConvertTime`) → `CameraSourceShims.swift`
  (`VideoOutputShim` / `AudioOutputShim` — делегатные мосты).
- Callback ScreenCaptureKit → `StreamOutputShim` в `ScreenSource.swift`.
- Классификация кадров (idle vs process) → `classifyFrameStatus` в `ScreenSource.swift`.

Конвенции:

- `CameraSource` реализует оба протокола с одним общим drops-стримом
  (камера и микрофон — один канал).
- Чистые nonisolated-функции выносятся для тестируемости (`classifyFrameStatus`,
  `shouldKeepFrame`, `backpressureDropEvent`, `makeDisplay`).
- Все PTS конвертируются в host-clock один раз — при приёме sample buffer в шимах;
  ниже по пайплайну переконвертаций нет.
- Буферы frames (4–8) и drops (8) развязаны: детекция backpressure не зависит от
  переполнения очереди кадров.

Подробнее о механизме записи камеры, испробованных подходах и известных ограничениях:
[`architecture/camera-recording-pipeline.md`](architecture/camera-recording-pipeline.md).

## Пайплайн — `Onset/Recording/Pipeline/`

Оркестрация двухфайловой записи: источники, кодеры, вывод в файлы, мониторинг
drop'ов, резолв возможностей железа.

| Тип | Файл | Роль |
|---|---|---|
| `RecordingSession` | `RecordingSession.swift` | Актор-оркестратор: владеет эпохой T0, строит источники/кодеры по плану, роутит, финализирует на stop |
| `DualFileOutputStage` | `DualFileOutputStage.swift` | Актор: фан-аут закодированных video/audio в два writer'а; ретайминг, replay отложенного аудио, ленивое создание writer'ов |
| `CapabilityResolver` | `CapabilityResolver.swift` | Чистая логика: размеры/fps экрана и камеры в рамках бюджета кодирования |
| `CapabilityProbe` | `CapabilityProbe.swift` | Преflight (AC-6): проверка HW-кодера, финальный план через `CapabilityResolver` |
| `DropMonitor` | `DropMonitor.swift` | Актор: учёт drop'ов и backpressure; эмитит `.normal` ↔ `.degraded` в UI; атрибутирует backpressure-потери по стадии и отдаёт `DropHealthSnapshot` (счётчики + доминирующая причина + latch `sessionEverDegraded`, на котором гейтится post-stop предупреждение) |
| `PipelineTypes` | `PipelineTypes.swift` | Общие value-типы: `HostTimeAnchor` (T0), `VideoFrame`, `AudioSample`, `EncodedSample`, `DropEvent`, `DropCause`, `RecordingState`, `SourceEvent` |
| `RecordingComponentFactories` | `RecordingComponentFactories.swift` | DI-протоколы: `EncoderControlling`, `WriterControlling`, `EncoderFactory`, `WriterFactory`, `SourceFactory` + live-реализации |
| `StageRateAggregator` | `StageRateAggregator.swift` | Телеметрия: per-stage частоты, причины drop'ов, лаги; flush в логи в конце сессии |

Где искать:

- Старт записи → `RecordingSession.start(permissions:)`.
- Резолв возможностей → `CapabilityProbe.probe()` → `CapabilityResolver.resolveStartProfile()`.
- Построение пайплайнов → `RecordingSession.buildPipelines()`.
- Drop'ы и состояние UI → `DropMonitor.observe()` → `recordingStateStream`; детальная модель учёта и атрибуции по причинам — [`architecture/drop-accounting.md`](architecture/drop-accounting.md).
- Отзыв источника (AC-12) → `RecordingSession.handleSourceEvent()`.
- Роутинг в файлы → `DualFileOutputStage.routeVideo/routeAudio()`.

Конвенции:

- Единая эпоха T0 (`HostTimeAnchor`) снимается один раз на старте сессии и передаётся
  всем источникам и writer'ам через `.start()`; все PTS — смещения от T0.
- Два самотактируемых кодера: каждый `VideoEncoder` ведёт собственную CFR-сетку
  (разный fps для экрана и камеры), без общего тика из `RecordingSession`.
- Роутинг — хранимые `Task`-хэндлы (не inline `withTaskGroup`), чтобы stop мог
  погасить один пайплайн, пока второй работает.

## Кодирование — `Onset/Encode/`

Аппаратное HEVC-кодирование с CFR-нормализацией, дедупликацией кадров и
стримингом результата.

| Тип | Файл | Роль |
|---|---|---|
| `VideoEncoder` | `VideoEncoder.swift` | Актор одного потока HW HEVC: CFR-клок, backpressure-гейтинг, anchored-PTS |
| `CFRNormalizer` | `CFRNormalizer.swift`, `CFRNormalizer+CatchUp.swift` | Чистая state machine слотов CFR и hold-кадров; без CoreMedia — полностью тестируема |
| `VTEncoderSettings` | `EncoderConfigBuilder.swift` | Иммутабельный снапшот конфига (rate/GOP/profile/color) между `RecordingConfiguration` и VT C API |
| `LiveCompressionSession` | `VideoEncoder+LiveSession.swift` | Продакшн-обёртка `VTCompressionSession`: C-callback → async stream |
| `CompressionSession` | `VideoEncoderTypes.swift` | Протокол-шов над VT-сессией; моки форсируют fallback/ошибки |
| `EncodedSampleSink` | `VideoEncoderTypes.swift` | Потокобезопасный мост C-callback'а: восстановление continuation из refcon |
| `CFREmission` | `CFRNormalizer+CatchUp.swift` | Результат catch-up: hold'ы + слот реального кадра; флаг capped short сигналит лаг |
| `HEVCProfileLevel` | `HEVCProfileLevel+VideoToolbox.swift` | Чистый enum + VT CFString-маппинг, общий для `CapabilityProbe` и `VideoEncoder` |

Где искать:

- CFR-клок и эмиссия слотов → `CFRNormalizer` (`processFrame`, `catchUpThenEncode`,
  `catchUpHolds`).
- VT C-callbacks и refcon → `LiveCompressionSession.outputCallback`.
- Маппинг VT-констант → `VideoEncoder+Configuration.swift`.
- Контракт one-shot lifecycle → доку-комментарий типа `VideoEncoder`.

Конвенции:

- Чистая логика на швах: `CFRNormalizer` и `VTEncoderSettings` импортируют только
  Foundation; impure C-interop заперт в акторе и обёртке сессии.
- One-shot lifecycle: `start()` успешен один раз; бросивший `start()` — терминален;
  `stop()` идемпотентен. Перезапусков нет — нет багов «протухшего» состояния.
- Anchored PTS — целочисленный индекс слота: `CMTime` строится из точного `Int`
  (никаких lossy round-trip через `Double`).

## Сервисы — `Onset/Permissions/`, `Onset/Configuration/`, `Onset/Storage/`

TCC-разрешения, политика записи, запись MP4.

| Тип | Файл | Роль |
|---|---|---|
| `PermissionsService` | `Permissions/PermissionsService.swift` | Источник истины по TCC-статусам (экран/камера/микрофон); поллинг и relaunch |
| `PermissionsProviding` | `Permissions/PermissionsProviding.swift` | Протокол трёх разрешений для тестов |
| `EffectivePermissions` | `Permissions/EffectivePermissions.swift` | Чистый расчёт доступных режимов записи из трёх статусов |
| `AppRouter` | `Permissions/AppRouter.swift` | Чистый роутинг стартового экрана (onboarding/allSet/main) из статусов и аргументов relaunch |
| `AppRelauncher` | `Permissions/AppRelauncher.swift` | Self-relaunch при гранте screen recording; анти-луп флаг в UserDefaults, аргумент `--post-screen-grant` |
| `RecordingConfiguration` | `Configuration/RecordingConfiguration.swift` | Иммутабельная политика: HEVC-настройки, таблица VBR-битрейтов, границы fps, бюджет |
| `OutputFolderKeys` | `Configuration/OutputFolderKeys.swift` | UserDefaults-ключ для персистирования базовой папки вывода (#225) |
| `FileWriter` | `Storage/FileWriter.swift` | Актор: мультиплексирование HEVC+AAC в MP4 (passthrough); телеметрия drop/fault |
| `RecordingOutput` | `Storage/RecordingOutput.swift` | Чистые утилиты: пути файлов внутри подпапки сессии, `~/Movies/Onset/` (дефолт базовой папки), POSIX-права 0600/0700 |
| `OutputFolderStore` / `OutputFolderPersisting` | `Storage/OutputFolderStore.swift` | Персистирование пользовательской базовой папки вывода в UserDefaults; injectable для тестов (#225) |
| `OutputDirectoryNaming` / `OutputDirectoryValidation` | `Storage/OutputDirectoryNaming.swift` | Чистые утилиты: имя подпапки сессии (`"Onset YYYY-MM-DD HH.mm.ss"`), collision avoidance с суффиксом ` (N)`, валидация записываемости базовой папки (#225) |

Где искать:

- Enum статуса разрешения и конверсии → `Permissions/PermissionStatus.swift`.
- TCC экрана → `Permissions/ScreenRecordingPermission.swift`
  (`CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`).
- TCC камеры/микрофона → `Permissions/CaptureDevicePermission.swift`
  (`AVCaptureDevice.authorizationStatus`).
- Типы политики записи (`Container`, `VideoCodec`, `ColorPrimaries`, `EngineBudgetCap`)
  → `Configuration/RecordingPolicyTypes.swift`.
- Ошибки writer'а и шов входа → `Storage/FileWriterTypes.swift`
  (`WriterInputSeam`, `FinishResult`, `FileWriterError`).
- Выбор и персистирование базовой папки вывода → `OutputFolderStore` / `OutputFolderKeys`; имя подпапки сессии и валидация → `OutputDirectoryNaming`.

Конвенции:

- Доменные value-типы объявляют явные nonisolated static операторы
  `Equatable`/`Hashable` — обязательное следствие
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
- `PermissionsService` (`@MainActor` `@Observable`) оборачивает nonisolated
  stateless-обёртки TCC; `FileWriter` (актор) держит nonisolated `WriterInputSeam`,
  чтобы не платить async-hop на каждый кадр.
- Чистые типы (`RecordingConfiguration`, `EffectivePermissions`, `RecordingOutput`,
  `AppRouter`) не импортируют AVFoundation; маппинг во framework-константы — на
  уровне кодера/writer'а/обёрток.

## Диагностика — `Onset/Diagnostics/`

Экспорт журнала событий приложения для поддержки (#164).

| Тип | Файл | Роль |
|---|---|---|
| `DiagnosticLogEntry` | `Diagnostics/DiagnosticLogEntry.swift` | Чистый value-тип: одна запись журнала (date, subsystem, category, level, message) |
| `LogExportFormatter` | `Diagnostics/LogExportFormatter.swift` | Чистый nonisolated enum: форматирование записей в text-файл, генерация имени файла |
| `LogEntryProviding` | `Diagnostics/LogEntryProviding.swift` | DI-шов: `entries(since:) async throws -> [DiagnosticLogEntry]` |
| `OSLogEntryProvider` | `Diagnostics/DiagnosticsExportService.swift` | Живая реализация `LogEntryProviding` через `OSLogStore(scope: .currentProcessIdentifier)` |
| `DiagnosticsSaveCoordinator` | `Diagnostics/DiagnosticsSaveCoordinator.swift` | `@MainActor @Observable`: оркестрирует сбор → NSSavePanel → запись → reveal в Finder |

Где искать:

- Кнопка «Экспортировать диагностику» → `MenuBarMenu.idleMenu`.
- Настройки временного окна (30 мин) → `DiagnosticsSaveCoordinator.defaultLookBackInterval`.
- Инструкции для пользователей (включая crash-логи `.ips`) → `docs/support/diagnostics.md`.

Конвенции:

- `OSLogStore(scope: .currentProcessIdentifier)` — читает только записи текущего процесса,
  специальный entitlement не нужен (macOS 12.0+). Исключительно локальный: сетевых соединений
  нет, инвариант `check-no-network.sh` соблюдён.
- `Task.detached` в `OSLogEntryProvider` — блокирующий disk I/O OSLogStore вынесен с
  вызывающего актора в пул кооперативных потоков.

## UI — `Onset/UI/`

Три поверхности (главное окно, окно записи, онбординг) + меню-бар и хоткей,
с одним координатором состояния.

| Тип | Файл | Роль |
|---|---|---|
| `RecordingCoordinator` | `UI/RecordingCoordinator.swift` | Единственный владелец состояния записи (phase, recordingState, drops, elapsed) и единственный подписчик стримов сессии |
| `MainViewModel` | `UI/Main/MainViewModel.swift` | Выбор устройств и enable-логика кнопки Record (AC-2: экран обязателен, камера опциональна, guard невыбранного микрофона); список камер/микрофонов обновляется вживую через `observeDeviceChanges()` (`MainViewModel+Devices.swift`); выбор и персистирование базовой папки вывода (#225) |
| `outputSection` / `OutputFolderRow` | `UI/Main/MainView+Sections.swift` | Секция «ВЫВОД» главного окна: строка с текущей базовой папкой (путь сокращён через `~`) и кнопка выбора через `NSOpenPanel` (#225) |
| `OnboardingViewModel` | `UI/Onboarding/OnboardingViewModel.swift` | Статусы карточек разрешений из `PermissionsProviding`; поллинг TCC экрана |
| `RecordingControlling` | `UI/RecordingControlling.swift` | Nonisolated-протокол над `RecordingSession` для координатора — юнит-тесты без железа |
| `RecordingView` | `UI/Recording/RecordingView.swift` | Тонкий reader состояния координатора; логика статуса/drop-pill в `RecordingDisplayMapper` |
| `GlobalHotKeyMonitor` | `UI/HotKey/GlobalHotKeyMonitor.swift` | Системный хоткей ⌘⌥⌃R через Carbon `RegisterEventHotKey`; зовёт `coordinator.stop()` |
| `MenuBarLabelMapper` | `UI/MenuBar/MenuBarLabelMapper.swift` | Чистый enum: phase+state → дескриптор лейбла меню-бара (красная/жёлтая точка, таймер) |
| `PermissionCardView` | `UI/Onboarding/PermissionCardView.swift` | Переиспользуемая карточка онбординга: иконка, статус-чип, кнопка, инструкции |

Где искать:

- Состояния lifecycle приложения → `AppPhase`, `RecordingOrigin`,
  `RecordingChecklist`, `SourceLiveness` в `RecordingCoordinator.swift`.
- Гварды кнопки Record → `MainViewModel.canRecord`, `recordDisabledReason`,
  `validateRecordGuards`.
- Stop из меню-бара (AC-9) → `MenuBarMenu.recordingMenu` → `coordinator.stop()`.
- Lifecycle превью камеры → `MainViewModel+Preview.swift`
  (`previewGeneration` + `.task(id:)`).
- Форматирование таймера (mm:ss / h:mm:ss) → `ElapsedFormatter.string(from:)` —
  без `String(format:)` из-за `SWIFT_STRICT_MEMORY_SAFETY`.

Конвенции:

- Координатор — единственный подписчик AsyncStream и владелец `@Observable`-состояния;
  поверхности только читают published-свойства, своих таймеров/подписок не имеют.
- Чистые nonisolated-мапперы (`MenuBarLabelMapper`, `RecordingDisplayMapper`) в паре
  с тонкими `@MainActor`-view.
- DI через closure-швы: `discoverDisplays`/`discoverCameras`/`discoverMicrophones`/
  `makeDeviceChangeStream`/`makeCameraSource` на `MainViewModel`, `startSessionOverride`
  для шпионажа в тестах.
- `@State` + передача параметрами (никаких `@EnvironmentObject`).

## Тесты — `OnsetTests/`

Плоская структура (31 файл), Swift Testing (`@Suite`/`@Test`/`#expect`), ноль XCTest.

- **Уровни L2/L5 в одних файлах**: юнит (L2 — без железа, `Fake*`-дублёры) и
  интеграция (L5 — реальное железо) рядом; L5-сьюты гейтятся env-переменными
  `ONSET_RUN_L5_*` через `.enabled(if:)` или явный `ProcessInfo` чек.
- **Дублёры**: `FakePermissionsService` (переиспользуемый `@MainActor`-мок),
  `FakeEncoder`/`FakeWriter`/`FakeRecordingControlling` (AsyncStream-хуки для
  инъекции сэмплов/drop'ов), `LiveCaptureSetup` (L5-харнесс с реальным
  `AVCaptureSession`).
- **Кросс-изоляционное состояние**: `FlagBox` (`OSAllocatedUnfairLock`) и `Counter`
  (`@unchecked Sendable`) — без data-race ошибок компилятора.
- **Изоляция тестов**: каждый `@Test` в `@Suite`-структуре получает свежий инстанс.
- **Именование**: функции читаются как утверждения —
  `start_transitionsToRecording`, `elapsedAfterStop_isFrozen`.
- **Поллинг-ассерты**: общий хелпер `eventuallyMain` (дедлайн-таймаут) в
  `RecordingCoordinatorTests.swift`.

Конвенции написания тестов — в `OnsetTests/CLAUDE.md` (подгружается агентом при работе
с тестами).

## Ссылки на документацию

Внешние справочники по стеку проекта (проверены 2026-06-07):

- ScreenCaptureKit — <https://developer.apple.com/documentation/screencapturekit>
- AVFoundation — <https://developer.apple.com/documentation/avfoundation>
- VideoToolbox — <https://developer.apple.com/documentation/videotoolbox>
- Swift Testing — <https://developer.apple.com/documentation/testing>
- MenuBarExtra — <https://developer.apple.com/documentation/swiftui/menubarextra>
- Privacy manifests — <https://developer.apple.com/documentation/bundleresources/privacy-manifest-files>
- Required-Reason API — <https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api>
- Миграция на Swift 6 concurrency — <https://www.swift.org/migration/>
- Каталог правил SwiftLint — <https://realm.github.io/SwiftLint/rule-directory.html>
- Правила SwiftFormat — <https://github.com/nicklockwood/SwiftFormat/blob/main/Rules.md>
- Ограничения AVFoundation на macOS (4K/60fps, L5-verified) — [`docs/quality/macos-avfoundation-camera-limits.md`](quality/macos-avfoundation-camera-limits.md)
