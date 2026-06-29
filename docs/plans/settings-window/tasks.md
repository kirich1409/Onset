# Tasks: окно «Настройки» (⌘,) — v1

> Plan: ./plan.md · Спецификации нет — acceptance ниже является контрактом уровня реализации.

## T-1 — Доменные типы в Configuration/
- after: none
- files: `Onset/Configuration/SettingApplyPolicy.swift`, `Onset/Configuration/SettingsKeys.swift`
- acceptance: GIVEN `SettingApplyPolicy` WHEN inspected THEN у него есть кейсы `.immediate/.nextRecordingStart/.requiresRelaunch`; `SettingsKeys` определяет UserDefaults-ключи на каждую настройку; типы `nonisolated` с явным `==` для enum по правилу проекта.
- check: `swift build` чисто (без warnings по isolation/Equatable); небольшой `SettingApplyPolicyTests` подтверждает, что witness'ы равенства используемы off-main.

## T-2 — Хранилище настроек по-ключно
- after: T-1
- files: `Onset/Storage/SettingsStore.swift`, `OnsetTests/SettingsStoreTests.swift`
- acceptance: GIVEN `SettingsStore` на базе `UserDefaults`, хранящий `showMenuBarTimer` и `cameraMirror` как прямые `Bool` под СВОИМИ ключами (`set(_:forKey:)`; presence-check через `object(forKey:)` → unset возвращает default конкретной настройки, в стиле `OutputFolderStore`, НЕ JSON) WHEN один ключ сохранён/отсутствует THEN reload возвращает сохранённое значение, а отсутствующий/невалидный ключ резолвится в СВОЙ default БЕЗ влияния на другой; конструирование с `.standard` под тестом trap'ает (как `BackendSelectionStore`).
- check: `SettingsStoreTests` — save→load по ключу, изолированное corrupt-heal (повредить один ключ, ассертить целостность другого) — зелёные через `withScopedDefaults { InMemoryUserDefaults }`.

## T-3 — Общая @Observable AppSettings (in-memory источник истины)
- after: T-2
- files: `Onset/UI/AppSettings.swift`, `Onset/OnsetApp.swift`, `Onset/UI/Main/MainViewModel.swift`, `Onset/UI/MenuBar/MenuBarLabel*.swift`
- acceptance: GIVEN `AppSettings`, владеемая как `@State` в `OnsetApp` (рядом с `coordinator`) WHEN мутируется stored-свойство THEN его `didSet` персистит синхронно через `SettingsStore` И триггерит инвалидацию `@Observable`; значения загружаются из хранилища на старте. THE SYSTEM SHALL быть единственным in-memory источником чтения. THE SYSTEM SHALL инъектировать её явно (не `@Environment`): добавить `let appSettings: AppSettings` в `MainViewModel.init` (обновить все места создания VM) и передавать её параметром `init` в `MenuBarLabel` и `SettingsView` из `OnsetApp`.
- check: `swift build` чисто (все call-site'ы `MainViewModel(...)` / `MenuBarLabel(...)` обновлены); `AppSettingsTests` проверяет load-at-init + синхронный write-through через `didSet` в fake-хранилище.

## T-4 — Добавить cameraMirror в RecordingConfiguration
- after: none
- files: `Onset/Configuration/RecordingConfiguration.swift`, `OnsetTests/RecordingConfigurationTests.swift`
- acceptance: GIVEN `makeMVPDefault(baseDirectory:cameraMirror: Bool = false)` (default `false`, чтобы `static let mvpDefault` :244 и остальные вызыватели — `CameraFormatSelector`, `RecordingCoordinator.stop` — компилировались без изменений) WHEN построено THEN `cameraMirror` хранится на config; рукописный `==` (:308-341) считает два config'а, различающиеся только `cameraMirror`, неравными.
- check: `RecordingConfigurationTests`: неравенство `==` для `cameraMirror`; build чисто, включая существующих вызывателей `mvpDefault`. (Без изменений bitrate/quality — профиль качества вне scope v1.)

## T-5 — Читать зеркало на seam записи + дать AppSettings превью
- after: T-3, T-4
- files: `Onset/UI/Main/MainViewModel+Record.swift`, `Onset/UI/Main/MainView.swift`
- acceptance: GIVEN запись стартует WHEN `MainViewModel` строит config (+Record.swift:108) THEN он читает `cameraMirror` из `self.appSettings` и передаёт его в `makeMVPDefault`. THE SYSTEM SHALL передавать `appSettings.cameraMirror` в `CameraPreviewRepresentable` (`MainView.swift` :334–348), чтобы его `updateNSView` (T-7) реагировал на тогглы.
- check: build чисто; `grep` подтверждает, что `CameraPreviewRepresentable` получает значение зеркала (а не хардкод-константу).

## T-6 — Тоггл таймера в menu bar (потребитель)
- after: T-3
- files: `Onset/UI/MenuBar/MenuBarLabelMapper.swift`, `Onset/UI/MenuBar/MenuBarLabel*.swift`, `OnsetTests/MenuBarLabelMapperTests.swift`
- acceptance: GIVEN `descriptor(phase:recordingState:elapsed:showTimer:)` WHEN `showTimer == false` THEN `elapsed` дескриптора равен `nil` (нет строки времени), а точка статуса неизменна; `MenuBarLabel` передаёт `AppSettings.showMenuBarTimer`. THE SYSTEM SHALL обновить ВСЕ существующие call-site'ы `descriptor(...)` (~9 в `MenuBarLabelMapperTests.swift` + прод-вызыватели), чтобы передавали `showTimer:` — иначе добавление параметра их ломает.
- check: `MenuBarLabelMapperTests` ассертит `elapsed == nil` при `showTimer == false` во время `.recording` (точка неизменна) И все прежние кейсы передают `showTimer: true`; build чисто (нет нерезолвленных call-site'ов).

## T-7 — Зеркалирование камеры (путь записи + живое превью)
- after: T-4, T-5
- files: `Onset/Recording/Capture/CameraSource+SessionSetup.swift`, `Onset/UI/Main/CameraPreviewView.swift`, `Onset/UI/Main/MainView.swift`
- acceptance: GIVEN `config.cameraMirror == true` WHEN VDO-connection записи конфигурируется ПРИ SETUP в `attachOutputs` (после `addOutput` :300, до первого кадра) THEN `isVideoMirrored` ставится в true — под guard `isVideoMirroringSupported`, после `automaticallyAdjustsVideoMirroring = false`, обёрнуто в СОБСТВЕННЫЙ `session.beginConfiguration()/commitConfiguration()` (attachOutputs НЕ внутри существующего на :164/169); ставится ТОЛЬКО при setup, никогда на работающей сессии. THE SYSTEM SHALL сделать `CameraPreviewRepresentable.updateNSView` (`MainView.swift`) ЕДИНСТВЕННЫМ писателем `isVideoMirrored` connection'а preview-слоя (`CameraPreviewView` ставит `automaticallyAdjustsVideoMirroring = false` при подключении слоя), реагируя на `appSettings.cameraMirror` без переконфига сессии; выход не зеркалируется при `cameraMirror == false`.
- check: build чисто; L5 (T-10): записанный `camera.mp4` горизонтально перевёрнут vs baseline; живое превью переворачивается по тогглу без мерцания; зеркало-ON vs OFF на default сохраняет zero-copy (IOSurface-backed / нет регрессии CPU-энергии на кадр), дропы вторичны.

## T-8 — Observable recording-active + классификатор доступности
- after: none
- files: `Onset/UI/RecordingCoordinator.swift`, `Onset/UI/Settings/ControlAvailability.swift`, `OnsetTests/ControlAvailabilityTests.swift`
- acceptance: GIVEN `RecordingCoordinator.isRecordingActive` — это OBSERVABLE STORED свойство, ставящееся в `true` на ВХОДЕ `start()` (~:445, покрывая окно запуска) и в `false` по ЗАВЕРШЕНИИ `stop()` (после терминальной фазы) — и `defer` для `isStarting` на :449 НЕ должен его трогать (другая переменная) — WHEN чистый классификатор маппит `(.nextRecordingStart, active=true)` THEN он возвращает `.disabled`; `(.immediate, …)` возвращает `.enabled` всегда.
- check: `ControlAvailabilityTests` покрывает матрицу policy × active; build чисто; мутация `isRecordingActive` триггерит инвалидацию SwiftUI (stored, не computed поверх `@ObservationIgnored`); тест координатора подтверждает, что он остаётся true на протяжении окна старта (не сбрасывается defer'ом :449).

## T-9a — Сцена Settings, вкладки, обнаружимость, реальные контролы
- after: T-3, T-6, T-8
- files: `Onset/UI/Settings/SettingsView.swift`, `Onset/OnsetApp.swift`, `Onset/UI/MenuBar/MenuBarMenu.swift`
- acceptance: GIVEN `SettingsView(appSettings:coordinator:)` (явный init — `appSettings` для биндингов тогглов, `coordinator` для гейтинга по `isRecordingActive`), размещённый в сцене `Settings` WHEN открыто через ⌘, ИЛИ `SettingsLink` («Настройки…») в `MenuBarExtra` THEN `TabView` показывает вкладки Общие/Индикация/Видео/Камера/Аудио (каждая — SF Symbol), открывается на Индикации и помнит последнюю вкладку через `@AppStorage`, ключ — `rawValue: String` enum `SettingsTab` (default `.indication`); реальные контролы — `Toggle` таймера (Индикация), `Toggle` зеркала (Камера) — биндятся к `appSettings`.
- check: build чисто; L5: и ⌘,, и SettingsLink открывают окно (в т.ч. без окон); тогглы мутируют persisted-состояние; повторное открытие восстанавливает последнюю вкладку, самое первое открытие — Индикация; используются только стандартные контролы SwiftUI (ревью).

## T-9b — Панели read-only-заглушек + гейтинг во время записи
- after: T-9a
- files: `Onset/UI/Settings/*Pane.swift`
- acceptance: GIVEN строки-заглушки WHEN отрисованы THEN они read-only `LabeledContent` (лейбл + статичное значение, без шеврона, НЕ Picker): кодек HEVC, контейнер MP4, разрешение «Исходное», fps «авто/исходный», камера 1080p, аудио off/off, язык «Русский». THE SYSTEM SHALL рендерить контрол зеркала `.disabled` через `ControlAvailability` во время записи С видимой подписью «Недоступно во время записи» + `accessibilityHint`, и нести подпись «Превью обновляется сразу, в запись — со следующего старта» в остальных случаях.
- check: L3/L5 вручную: заглушки — неинтерактивные строки (не серые picker'ы); вкладки-только-заглушки (Общие/Видео/Аудио) читаются как информационные, не сломанные; зеркало серое + пояснено во время активной записи; VoiceOver озвучивает read-only строки как статичный текст (не кнопку) с корректным порядком фокуса; нет кастомных типов контролов (ревью).

## T-10 — Docs + L5-верификация + CLAUDE.md
- after: T-9b
- files: `docs/architecture.md`, `CLAUDE.md`
- acceptance: THE SYSTEM SHALL задокументировать сцену Settings + новые типы в architecture.md; добавить в CLAUDE.md (через revise-claude-md, ≤200 строк) КАК правило «UI из стандартных компонентов SwiftUI/AppKit», ТАК И переформулировку «sole @Observable owner» → «sole session-lifecycle owner». L5 на MX Brio (тихая машина, signed-build): зеркало переворачивает `camera.mp4` + живое превью; зеркало-ON vs OFF на default сохраняет zero-copy (IOSurface / нет регрессии CPU-энергии) без новых дропов (`verify-cfr`); таймер в menu bar скрывается/показывается вживую; и ⌘,, и SettingsLink открывают окно.
- check: docs обновлены в этом PR; L5-свидетельства (скриншот переворота + сравнение zero-copy/энергии зеркало-ON/OFF + результат verify-cfr) записаны в теле PR. NOTE: PR также трогает CLAUDE.md + это UI-изменение → не авто-мержабелен, нужно ревью владельца.
