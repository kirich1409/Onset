---
type: spec
slug: macos-screen-camera-recorder
date: 2026-05-29
status: approved
platform: [desktop]
surfaces: [ui]
risk_areas: [perf-critical]
non_functional:
  sla: "Acceptance-железо MacBook Pro 14\" M3 Max (2 HW encode engine): 0 dropped frames в steady state при dual-stream экран 4K60 + камера 4K30, оба HEVC HW — две одновременные HW encode-сессии, которые планировщик VideoToolbox может распараллелить на 2-движковом чипе (эмерджентно, не контрактная изоляция движков; подтверждается эмпирически в AC-14). На 1-движковых чипах (base/Pro): 0 дропов гарантируется для single-stream 4K60; dual-stream — через адаптивную деградацию, дропы вскрываются, не теряются молча. Real-time sample-buffer callback не блокируется. Процедура измерения — см. AC-14."
  a11y: "Окно настроек и menu bar управляются с клавиатуры и читаются VoiceOver (стандартные AppKit/SwiftUI контролы); остановка записи доступна с клавиатуры (глобальный hotkey)."
acceptance_criteria_ids: [AC-1, AC-2, AC-3, AC-4, AC-5, AC-6, AC-7, AC-8, AC-9, AC-10, AC-11, AC-12, AC-13, AC-14, AC-15, AC-16, AC-17, AC-18, AC-19, AC-20, AC-21]
design:
  figma:
  design_system:
---

# Spec: Onset — нативный macOS-рекордер экрана + камеры + микрофона (MVP v1)

Название продукта: **Onset** (от «on set» — на съёмочной площадке; бренд нейтрален к функциям, масштабируется на будущие режимы: композиция/наложение и др.).

> ⚠️ **SUPERSEDED — разбито по фичам.** Канонические доки: общая часть — [`docs/spec/overview.md`](../spec/overview.md) + [`docs/spec/architecture.md`](../spec/architecture.md); по фичам — `docs/<feature>/spec.md` + `test-plan.md` (screen-capture, camera-capture, audio-capture, capability-and-settings, recording-session, recording-control-ui, performance-and-degradation, permissions). Этот монолит — консолидированная историческая версия; правки вносить в per-feature доки.

Date: 2026-05-29
Status: approved
Slug: macos-screen-camera-recorder

---

## Context and Motivation

Приложению нужно записывать экран и внешнюю камеру в **раздельные синхронизируемые файлы** с дорожкой микрофона, чтобы автор мог нести готовые клипы в монтажную программу (Final Cut / DaVinci / Premiere) и собирать там видео без ручной подгонки. Раздельные файлы (а не готовая композиция) дают максимум гибкости на монтаже; общий host-clock таймкод и идентичная аудиодорожка микрофона в обоих файлах обеспечивают точную синхронизацию. Стек полностью нативный (Apple Silicon, macOS 26+) ради максимальной эффективности и отсутствия задержек/дропов. Предварительное исследование (API, синхронизация, capability-модель, лимиты железа) — рабочий артефакт, в репозитории не хранится; результаты консолидированы в спеках.

MVP v1 сфокусирован на референс-сценарии: дисплей 4K60 SDR + камера Logitech MX Brio (4K@30 / 1080p60), запись всего дисплея, кодек HEVC в MOV. 5K-дисплеи поддерживаются вторым приоритетом через capability-детекцию и адаптивную деградацию. Область/окно и системный звук вынесены в Phase 2.

## Acceptance Criteria

Фича готова, когда ВСЕ пункты истинны. Каждый критерий наблюдаемый и проверяемый.

**Окно настроек и выбор источников**
- [ ] **AC-1** — При запуске открывается окно настроек, где можно: выбрать камеру (из обнаруженных + вариант «Без камеры»), выбрать микрофон (из обнаруженных + «Без звука»), включить/выключить запись экрана и выбрать какой дисплей записывать (из подключённых).
- [ ] **AC-2** — Списки устройств заполняются реально обнаруженными устройствами: камеры через `AVCaptureDevice.DiscoverySession` (типы `.external`, `.builtInWideAngleCamera`, `.continuityCamera`), микрофоны через audio-discovery, дисплеи через `SCShareableContent.displays`. При подключении/отключении устройства во время нахождения в окне настроек список обновляется (hotplug-нотификации).
- [ ] **AC-3** — Для выбранной камеры пикеры разрешения и FPS показывают **только** комбинации, которые камера реально сообщает через `device.formats` (`CMVideoFormatDescriptionGetDimensions` + `videoSupportedFrameRateRanges`). Для MX Brio это `4K@30`, `1080p@60`, `720p@90`; вариант `4K@60` не предлагается, потому что камера его не отдаёт.
- [ ] **AC-4** — Окно настроек показывает живое превью выбранной камеры (`AVCaptureVideoPreviewLayer`); при смене камеры превью переключается на новое устройство; при «Без камеры» область превью скрыта/пуста.
- [ ] **AC-5** — Пользователь выбирает папку сохранения и кодек (HEVC по умолчанию / H.264) и контейнер (MOV по умолчанию / MP4). Недоступные на текущем железе комбинации (подтверждается VideoToolbox-probe) показаны задизейбленными с поясняющей причиной, а не скрыты.
- [ ] **AC-6** — Кнопка Record активна только при валидной конфигурации: выбран хотя бы один видеоисточник (экран или камера). При нуле видеоисточников Record недоступен с подсказкой почему.

**Запись**
- [ ] **AC-7** — По нажатию Record все выбранные источники стартуют от единой нулевой точки T: первый кадр в каждом выходном файле соответствует одному и тому же моменту реального времени (проверяется синком AC-12). Главное окно сворачивается, состояние приложения переходит в «идёт запись». (Внутренний механизм — warm-up источников → выбор T → `startSession(atSourceTime: T)` → admit PTS≥T — описан в Technical Approach.)
- [ ] **AC-8** — Во время записи в строке меню (`NSStatusItem`) присутствует индикатор записи с отображением прошедшего времени, текущего счётчика дропнутых кадров (с причиной) и пунктом Stop. При ненулевых дропах сам `NSStatusItem` показывает заметный признак деградации (изменение иконки/цвета). Пункт Stop отображает назначенный глобальный hotkey как key-equivalent.
- [ ] **AC-9** — Микрофон (если выбран) пишется отдельной аудиодорожкой в **каждый** присутствующий видеофайл идентичными сэмпл-буферами (fan-out): при записи экран+камера — в оба файла; при одном видеоисточнике — в его файл. PTS микрофона приводятся к host clock через `CMSyncConvertTime` перед append.
- [ ] **AC-10** — Запись экрана идёт в оригинальном разрешении выбранного дисплея (`captureResolution = .best`) с целевым FPS (`minimumFrameInterval`), не превышающим refresh дисплея. SDR-пайплайн: 8-битный pixelFormat, без HDR/`captureDynamicRange`.

**Выходные файлы и синхронизация**
- [ ] **AC-11** — По окончании в выбранной папке создаётся подпапка `Recording YYYY-MM-DD HH.mm.ss/`, содержащая файлы присутствующих источников: `screen.mov` и/или `camera.mov` (расширение по выбранному контейнеру). После Stop эта папка открывается в Finder.
- [ ] **AC-12** — Оба видеофайла записаны с общей нулевой точкой T, их PTS лежат на одной host-шкале. Объективная проверка синка: когда микрофон присутствует, его аудиодорожки в `screen.*` и `camera.*` бит-в-бит идентичны (совпадение SHA-256 извлечённых PCM-дорожек после старта) — это машинно-проверяемая гарантия из AC-9. Практический результат: открытие обоих файлов в NLE и выравнивание по аудиоволне даёт совпадение ≤1 кадр. Дополнительно (best-effort, см. Open Questions) при MOV пишется timecode-трек со стартовым SMPTE от T; его отсутствие не нарушает AC-12. Когда микрофон не выбран, синк проверяется совпадением PTS-старта обоих файлов на host-шкале (разница ≤1 кадрового интервала).
- [ ] **AC-13** — Аудио всех источников фиксируется на едином sample rate 48 кГц; обнаруженный разрыв PTS в аудиопотоке заполняется тишиной перед append (защита от Core Audio gaps), чтобы аудио не укорачивалось относительно видео.

**Производительность, деградация, ошибки**
- [ ] **AC-14** — Измеримый no-drop критерий на acceptance-железе (MacBook Pro 14" M3 Max + внешний дисплей 4K60): запись dual-stream экран 4K60 + камера 4K30 (оба HEVC HW) длительностью **≥10 минут без срабатывания DegradationLadder** (если деградация сработала внутри окна — прогон невалиден для AC-14, деградация проверяется отдельно в AC-15); после warm-up окна **первых 2 с** суммарные `DroppedFrameStats` обоих источников (включая capture-layer дропы, см. AC-21) == 0, а PTS-непрерывность каждого выходного файла (анализ дельт через `AVAsset`/`ffprobe`) не имеет пропущенных кадровых интервалов сверх допуска **0 кадров** в steady state. Real-time callback'и источников не блокируются: внутри callback — только retain/enqueue, кодирование/запись — на отдельных serial-очередях.
- [ ] **AC-15** — Перед записью выполняется capability-валидация: при выборе, который железо не тянет, конфигурация либо авто-корректируется (даунскейл/снижение fps) с явным уведомлением, либо отклоняется до старта. Во время записи при перегрузке/термал-throttle применяется `DegradationLadder` по измеримым триггерам (см. Technical Approach) — фрейм-дропы не «лечатся» молча.
- [ ] **AC-16** — Кодек по умолчанию — аппаратный HEVC (подтверждён через `VTCopyVideoEncoderList` / `VTCopySupportedPropertyDictionaryForEncoder`); приложение никогда не уходит в software-энкод по умолчанию. Если пользователь форсит SW-only комбинацию — явное предупреждение.
- [ ] **AC-17** — При отказе одного **writer'а** в середине записи (напр. диск переполнился, постоянная ошибка записи) этот выход останавливается и финализируется как частичный файл, остальные источники продолжают писать; пользователь уведомляется (системное уведомление). Запись не теряется целиком из-за одного выхода.
- [ ] **AC-18** — При первом запросе доступа приложение корректно запрашивает разрешения Screen Recording (TCC), Camera, Microphone и Notifications; при отсутствии разрешения соответствующий источник недоступен с понятной подсказкой, как его выдать. Если разрешение на уведомления не выдано — факт ошибки/частичного отказа всё равно обнаружим: индикатор в `NSStatusItem` показывает необработанную ошибку до возврата в окно (fallback к AC-21/AC-8), уведомления не единственный канал.
- [ ] **AC-19** — Запись можно остановить **минимум тремя** способами, доступными при свёрнутом главном окне: пункт Stop в menu bar (AC-8), глобальный hotkey, и клик по иконке приложения в Dock (возвращает окно с активной кнопкой Stop). Состояние «идёт запись» всегда визуально обнаружимо (индикатор в menu bar), запись не может «потеряться».
- [ ] **AC-20** — При отказе **источника** в середине записи (отключение USB-камеры; отзыв Camera permission через System Settings — прерывает live немедленно) этот источник останавливается и его файл финализируется как частичный, остальные источники продолжают (симметрично AC-17); пользователь уведомляется системным уведомлением (или fallback по AC-18). Если упал последний/единственный видеоисточник — запись корректно финализируется (не теряется) и переходит в `error` (результат частичный из-за сбоя). Примечание: отзыв Screen Recording permission исторически применяется на релончe, не мгновенно — этот арм проверяется через unplug камеры / отзыв Camera permission; live-наблюдаемость screen-revocation подтверждается против SDK macOS 26 на этапе реализации.
- [ ] **AC-21** — Дропнутые кадры **видео** никогда не теряются молча. Учитываются ОБА класса дропов: (а) capture-layer — камера через `AVCaptureVideoDataOutputSampleBufferDelegate.captureOutput(_:didDrop:from:)`, экран через `SCFrameStatus` в attachments `CMSampleBuffer`; (б) consumer-layer — переполнение ограниченной очереди / writer не `isReadyForMoreMediaData` / временный disk-stall. Каждый дроп учитывается в `DroppedFrameStats` с причиной (`captureBound`/`poolExhausted` / `encoderBound` / `diskBound`); счётчик виден пользователю во время (в `NSStatusItem`, AC-8) и после записи. Временный disk-stall (writer не готов, том рабочий) отличается от постоянного отказа тома (AC-17) и не помечает выход как failed. **Аудио-путь микрофона — лосслесс по построению** (drop-oldest к нему не применяется, см. Technical Approach): потеря аудио-буфера микрофона — это ошибка, а не штатный режим, чтобы не нарушить бит-в-бит идентичность AC-9/AC-12.

**Authoritative definition of done.** Имплементирующий агент валидирует против этого списка перед закрытием задач.

## Prerequisites

| Prerequisite | Status | Owner | Notes |
|--------------|--------|-------|-------|
| Создать Xcode-проект «Onset» (macOS App, SwiftUI lifecycle, Swift) | ⬜ Todo | Agent | Bundle-приложение (не plain executable) — иначе Screen Recording permission не отобразится в System Settings (macOS 26.1) |
| Добавить в Info.plist `NSCameraUsageDescription`, `NSMicrophoneUsageDescription` | ⬜ Todo | Agent | Без них система не покажет диалог доступа |
| Настроить entitlements: при App Sandbox — `com.apple.security.device.camera`, `com.apple.security.device.microphone` | ⬜ Todo | Agent | Решить sandbox vs non-sandbox (см. Open Questions) |
| Deployment target = macOS 26.0 | ⬜ Todo | Agent | Все используемые API доступны на 26+ |
| Acceptance-Mac: MacBook Pro 14" M3 Max | ⬜ Todo | Human | 2 HW encode engine → dual-stream 4K60+4K30 HEVC по движку на поток (AC-14). Встроенный дисплей — ProMotion 3024×1964, не 4K → запись референс-дисплея идёт на ВНЕШНИЙ 4K60 |
| Внешний дисплей 4K60 для приёмки | ⬜ Todo | Human | Для AC-10, AC-14 (встроенный экран MBP не 4K) |
| Референс-камера Logitech MX Brio подключена для приёмки | ⬜ Todo | Human | Для проверки AC-3, AC-4, AC-14 |

## Affected Modules and Files

Greenfield — всё новое. Предлагаемая структура (Swift, один таргет):

| Module / File | Change type | Notes |
|---------------|-------------|-------|
| `App/OnsetApp.swift` | New | Точка входа SwiftUI, инициализация composition root |
| `Domain/CaptureSource.swift` | New | Протокол `CaptureSource`, `SampleSink`, `EncodingWriter`, `ClockProviding`, value-типы (`SourceKind`, `RecordingState`) |
| `Domain/RecordingConfiguration.swift` | New | parse-don't-validate тип (приватный init, конструируется только Validator) + sub-configs |
| `Domain/Capability.swift` | New | `CapabilitySnapshot`, `DisplayCapability`, `CameraCapability`, `EncoderCapability`, `AudioCapability`, `SystemCapability`, `ChipTier`, `CaptureScope` |
| `Infrastructure/Capture/ScreenCaptureSource.swift` | New | ScreenCaptureKit: `SCStream` + `SCStreamConfiguration` + `SCContentFilter` (full display) |
| `Infrastructure/Capture/CameraCaptureSource.swift` | New | AVFoundation: `AVCaptureSession` (видео, без аудиовхода), `AVCaptureVideoDataOutput`, MJPEG→decode при 4K |
| `Infrastructure/Capture/AudioCaptureSource.swift` | New | Независимый аудио-источник (микрофон), вне сессии камеры |
| `Infrastructure/Writer/AVAssetWriterPipeline.swift` | New | Обёртка `AVAssetWriter` (video+audio+timecode inputs), HEVC/H.264 outputSettings, gap-filling |
| `Infrastructure/Sync/HostClockService.swift` | New | `ClockProviding`: host time clock, `CMSyncConvertTime` |
| `Infrastructure/Sync/SampleRouter.swift` | New | `SampleSink`: fan-out микрофона в нужные writer'ы |
| `Infrastructure/Capability/CapabilityService.swift` | New | actor: VideoToolbox probe + sysctl + display/camera/audio discovery, версионированный snapshot, hotplug-инвалидация |
| `Infrastructure/Capability/CapabilityMatrix.swift` | New | data-таблица tier→бюджет для multi-stream (нет публичного API) |
| `Infrastructure/Capability/Validator.swift` | New | чистая функция: `(Capabilities, Selections) -> Result<RecordingConfiguration, [ValidationIssue]>` |
| `Application/RecordingSessionCoordinator.swift` | New | actor: машина состояний, атомарный старт/стоп (warm-up→T), оркестрация; владеет переходами. Делегирует мониторинг RuntimeHealthMonitor |
| `Application/RuntimeHealthMonitor.swift` | New | поллинг `thermalState`, чтение `DroppedFrameStats`/memory watermark, агрегация `WriterHealth`/source-health; предлагает Coordinator'у шаги `DegradationLadder` по измеримым триггерам (control plane, не hot path) |
| `Application/OutputLayout.swift` | New | владелец AC-11: создание session-папки `Recording <timestamp>/`, имена файлов, reveal в Finder |
| `Application/SettingsStore.swift` | New | мутабельный черновик Selections + персистентность (UserDefaults) |
| `Presentation/SettingsView.swift` | New | SwiftUI окно настроек: пикеры устройств/scope/кодека/пути, превью камеры |
| `Presentation/CameraPreviewView.swift` | New | NSViewRepresentable вокруг `AVCaptureVideoPreviewLayer` |
| `Presentation/MenuBarController.swift` | New | `NSStatusItem`: индикатор записи + таймер + Stop |
| `Presentation/GlobalHotkeyService.swift` | New | глобальный hotkey остановки записи (AC-19), доступен при свёрнутом окне |
| `Presentation/NotificationManager.swift` | New | системные уведомления (UserNotifications) о старте/стопе/ошибках источника/writer'а при свёрнутом окне (AC-17, AC-20, AC-21) |
| `Presentation/RecordingViewModel.swift` | New | `@MainActor`, мост UI ↔ Coordinator/SettingsStore/CapabilityService |
| `Infrastructure/Permissions/PermissionsManager.swift` | New | TCC Screen Recording, Camera, Microphone |

Key integration points:
- `CaptureSource` эмитит timestamped `CMSampleBuffer` → `SampleRouter` (`SampleSink`) → `AVAssetWriterPipeline` (`EncodingWriter`).
- `Validator` — единственный конструктор `RecordingConfiguration`, который потребляет `RecordingSessionCoordinator`.
- `HostClockService.referenceClock` инъецируется во все источники как единая шкала.

## Technical Approach

Слои (зависимости внутрь): Presentation (SwiftUI + AppKit menu bar) → Application (`RecordingSessionCoordinator` actor, `SettingsStore`) → Domain (протоколы + value-типы) ← Infrastructure (ScreenCaptureKit / AVFoundation / AVAssetWriter / VideoToolbox / Core Media). Domain импортирует CoreMedia как «язык» hot path (CMSampleBuffer/CMTime/CMClock) — это сознательная граница ради отсутствия аллокаций на горячем пути.

**Поток данных записи:**
```
ScreenCaptureSource (SCStream)         ─┐
CameraCaptureSource (AVCaptureSession) ─┼─ timestamped CMSampleBuffer ─→ SampleRouter ─→ AVAssetWriterPipeline(screen)
AudioCaptureSource  (microphone)       ─┘        (fan-out mic)                          └→ AVAssetWriterPipeline(camera)
                         все PTS на единой host-шкале (HostClockService)
```

**Синхронизация:** host time clock — единая опорная шкала. Экран (SCStream) и камера (`AVCaptureSession` **без аудиовхода**, чтобы master clock не слейвился к аудио-железу) уже на host-шкале. Микрофон — независимый источник на дрейфующих аудиочасах; его PTS конвертируются на host через `CMSyncConvertTime` перед append. Один источник микрофона → идентичные буферы в оба файла (бит-в-бит → точный аудио-синк). Timecode-трек (только MOV) со стартовым SMPTE от общего T.

**Hot path / concurrency:** real-time callback'и (`SCStreamOutput`, `AVCaptureVideoDataOutputSampleBufferDelegate`, аудио) исполняются на выделенных GCD serial-очередях (`com.app.capture.{screen,camera,audio}`); внутри — только retain/enqueue + немедленный release исходного буфера/IOSurface после enqueue (для SCStream обязательно: время удержания < `minimumFrameInterval × (queueDepth−1)`, queueDepth экрана 5–6). Запись — на отдельных serial-очередях (`com.app.writer.{screen,camera}`), перед `append` — `guard input.isReadyForMoreMediaData`. **Никаких actor-хопов на пути сэмплов.** Actor (`RecordingSessionCoordinator`/`RuntimeHealthMonitor`) — только control plane.

**Backpressure-контракт (закрывает AC-21, перф-SLA):**
- **Видео-источники (экран, камера):** между capture-очередью и writer-очередью — **ограниченная** очередь фиксированной глубины (bounded ring buffer; глубина — параметр, калибруется, старт ~ queueDepth источника). Политика при переполнении или `!isReadyForMoreMediaData`: **drop-oldest** + инкремент `DroppedFrameStats` с причиной (`encoderBound` / `diskBound`). Дополнительно учитываются **capture-layer дропы до очереди**: камера — `captureOutput(_:didDrop:from:)` (с явным `alwaysDiscardsLateVideoFrames`, причина `poolExhausted`/`captureBound`), экран — `SCFrameStatus` из attachments (причина `captureBound`). Память: каждый in-flight 4K-кадр ~12–33 МБ; ограниченная очередь даёт жёсткий потолок. Различие режимов: временный disk-stall (writer не ready, том рабочий) → `diskBound`-дроп, том НЕ failed; постоянная ошибка записи → AC-17 isolate.
- **Аудио-путь микрофона — ЛОССЛЕСС, drop-oldest НЕ применяется.** Аудио-буферы малы (48 кГц), потолок памяти не проблема → отдельная не-drop очередь. Gap-fill тишиной (AC-13) и fan-out (AC-9) выполняются **до** разветвления по writer'ам, так что оба файла получают идентичный поток (бит-в-бит, AC-12). Потеря аудио-буфера трактуется как ошибка, не штатный режим. Это намеренно отделено от видео-политики drop-oldest, чтобы backpressure видео-writer'а не «обкусывал» аудио в одном файле относительно другого.
- **Callback никогда не блокируется ожиданием writer'а.** `RuntimeHealthMonitor` отслеживает memory watermark и счётчики дропов как триггеры деградации.

**SampleRouter ↔ writer health (wait-free, закрывает AC-17/AC-20 без actor-хопа):** у каждого writer'а — **настоящий атомарный** флаг `isAlive` (atomic Bool с acquire/release-семантикой, напр. `Atomic<Bool>`/`OSAllocatedAtomic`-эквивалент; **не** lock-защищённый — лок на hot-path-чтении нарушил бы wait-free). При фатальной ошибке writer-queue выставляет флаг в false; `SampleRouter` на hot path читает его без блокировки и прекращает fan-out в мёртвый writer, продолжая в живые. Это единственный разрешённый канал control→hot-path; он wait-free. `DroppedFrameStats` — той же строгости: per-source atomic-счётчики (atomic increment на hot path, atomic read у `RuntimeHealthMonitor` и `@MainActor` ViewModel).

**Capability/Settings:** `CapabilityService` (actor) на launch собирает версионированный snapshot: VideoToolbox-probe (HW-кодеки, max-разрешение), sysctl (tier чипа, ядра), discovery дисплеев/камер/микрофонов, диск/термалка. Дорогой probe кэшируется; hotplug камеры/дисплея и смена thermalState инкрементят generation и обновляют только свои сегменты. `SettingsStore` хранит мутабельный черновик Selections (+ UserDefaults персистентность). `Validator` (чистая функция) на каждое изменение резолвит черновик против snapshot → `RecordingConfiguration` или `[ValidationIssue]`; UI показывает только поддерживаемое и дизейблит невозможное с причиной. Priority-правило: probe — ground truth для single-stream; `CapabilityMatrix` — единственный источник для оценки числа одновременных сессий (нет публичного API). Неизвестный чип → консервативный fallback по числу P-ядер. **MJPEG-decode камеры — отдельный член бюджета:** на 4K MX Brio отдаёт MJPEG, путь камеры = decode-сессия + encode-сессия, поэтому он дороже «просто ещё одного encode»; `CapabilityMatrix` учитывает decode-стоимость отдельно от encode при оценке multi-stream насыщения (на acceptance-железе M3 Max — измерить фактический бюджет decode+encode пути камеры).

**Машина состояний:** `idle → configuring → ready → recording → finalizing → done/error`.

- **Атомарный старт (warm-up → T):** в `ready` по всем writer'ам выполнен `startWriting()` (медленная преаллокация). При Record: (1) запустить все источники (SCStream, AVCaptureSession, микрофон) и **дождаться first-sample от каждого** (источники реально эмитят буферы) с таймаутом; (2) только теперь выбрать единое T = host-now; (3) `startSession(atSourceTime: T)` по всем writer'ам; (4) admit PTS ≥ T (сэмплы с PTS < T отбрасываются). Это исключает «дыру» в начале файла из-за разной стартовой задержки источников. Если источник не вышел в running за таймаут → его обработка как source-failure (см. ниже), старт продолжается с остальными (или error, если видеоисточников не осталось).
- **Re-validate на старте (TOCTOU):** перед `startWriting()`/стартом Coordinator сверяет `generation` snapshot'а, на котором построен `RecordingConfiguration`, с текущим; при расхождении (устройство исчезло между настройкой и Record) — повторный прогон `Validator`, и при потере устройства — сообщение пользователю вместо старта.
- **Атомарный стоп:** фиксация T_end, остановка источников, дренаж буферов ≤ T_end, `finalize()` всех writer'ов, `OutputLayout` reveal папки в Finder.
- **Source-failure ветка (AC-20):** disconnect устройства / отзыв permission mid-recording → остановить и финализировать этот источник как частичный файл, уведомить, остальные продолжают; если упал последний видеоисточник → `finalizing`/`error`. Симметрично writer-failure (AC-17).

**Адаптивная деградация (измеримые триггеры, закрывает AC-15):** `RuntimeHealthMonitor` владеет мониторингом, `DegradationLadder` задаёт **порядок** сброса **только из шагов, которые HW-энкодер/сессия принимают динамически без нового файла-сегмента**: снижение fps камеры → снижение fps экрана → снижение битрейта → отключение камеры. Изменение выходного разрешения mid-recording НЕ входит в ladder v1 (`AVAssetWriter` фиксирует output-dimensions на `startWriting()`; смена потребовала бы нового сегмента/файла) — вынесено за scope; при необходимости даунскейла применяется только scale **на входе энкодера при сохранении фиксированного выходного размера**, что нагрузку encode не снижает и потому в ladder не используется. Триггеры (числа — кандидаты в калибровку на acceptance-железе, фиксируются на этапе реализации): шаг **вниз** при `DroppedFrameStats` прирост > N за окно T (старт N=3, T=2 с) **или** `thermalState >= .serious` **или** memory watermark превышен. Шаг **вверх** (апгрейд) только после cooldown ≥ C секунд (старт C=15) устойчиво чистого окна И `thermalState ∈ {.nominal,.fair}`; максимум один шаг за cooldown; **ratchet** — запрет апгрейда выше уровня, на котором в последний раз случился дроп (анти-осцилляция). Статическую выполнимость гарантирует Validator (+ safety margin); динамическую — эта петля.

**Камера-превью (перф):** `AVCaptureVideoPreviewLayer` на сессии камеры в окне настроек. Сессия конфигурируется **сразу в целевом `activeFormat` записи** (а не в дефолтном preview-формате), чтобы при Record не требовалась реконфигурация формата (`begin/commitConfiguration` с glitch и сдвигом первого PTS) — добавляется только `AVCaptureVideoDataOutput`. Если целевой формат недоступен для preview — допускается glitch строго до точки T (не влияет на записанные кадры).

**Gap-fill до fan-out (согласование AC-9 ↔ AC-13):** детекция разрыва PTS аудио и заполнение тишиной выполняется в `AudioCaptureSource`/до `SampleRouter`, **до** fan-out — так оба файла получают идентичный заполненный поток, и бит-в-бит идентичность микрофона (AC-9) не нарушается per-writer обработкой.

**Камера MJPEG:** на 4K MX Brio отдаёт MJPEG; `AVCaptureVideoDataOutput` получает декодированные кадры (AVFoundation декодирует UVC MJPEG), которые затем энкодятся в HEVC/H.264. Лишний decode учтён в нагрузке.

## Technical Constraints

- Только нативный Apple-стек: ScreenCaptureKit, AVFoundation, AVFAudio, AVAssetWriter, VideoToolbox, Core Media, AppKit/SwiftUI. **Сторонние зависимости запрещены** без явного согласования.
- Swift, deployment target macOS 26.0, Apple Silicon.
- Real-time sample-buffer callback не блокировать; никаких actor-хопов на hot path.
- Микрофон держать ВНЕ `AVCaptureSession` камеры (иначе master clock слейвится к аудио-железу и ломается host-синхронизация).
- Кодек по умолчанию — аппаратный (HEVC); software-энкод не использовать по умолчанию.
- SDR-пайплайн в v1 (без HDR/10-bit/`captureDynamicRange`).
- Контейнер MOV для timecode-трека; в MP4 timecode-трек не писать (не поддерживается).
- `RecordingConfiguration` конструируется только `Validator`'ом (parse-don't-validate).
- **Верификация API против SDK macOS 26 на этапе реализации** (не меняет дизайн): точная форма `synchronizationClock` (get-only vs settable — research склоняется к read-only, миграция = 2 строки), сигнатуры ScreenCaptureKit/AVFoundation на финальном SDK (на момент research полная docs macOS 26 не опубликована). При расхождении — следовать фактическому SDK, host-clock-стратегия и «микрофон вне сессии камеры» остаются в силе.
- **Очереди capture→writer — строго ограниченные (bounded).** Unbounded enqueue запрещён: in-flight 4K-кадры (~12–33 МБ каждый) на длинной записи дают memory-pressure → дропы. Память на сценарий 4K60+4K30 проверяется на приёмке как бюджет.
- **Тестируемость (L1/L2 vs L5):** unit-тестируемо без железа — `Validator` (синтетические Capabilities+Selections → Result), `SampleRouter` fan-out (синтетические `CMSampleBuffer` → топология + реакция на `isAlive=false`), drop-PTS<T и warm-up→T (fake `EncodingWriter`), gap-fill до fan-out, `CMSyncConvertTime`-конвертация. Только на acceptance-железе (L5) — AC-14 (no-drops/non-blocking), AC-10 (реальные разрешение/fps дисплея), AC-3/AC-4 (реальная MX Brio), AC-19/AC-20 (hotkey/Dock/unplug).
- **Activation policy = `.regular`** (Dock-иконка обязательна для третьего способа остановки в AC-19). Accessory/LSUIElement-режим без Dock-иконки в v1 не используется.
- **Глобальный hotkey — через Carbon `RegisterEventHotKey`** (не `NSEvent.addGlobalMonitorForEvents`), чтобы не вводить дополнительный Input-Monitoring/Accessibility TCC-гейт. Default-сочетание задаётся (кандидат — `⌘⌥⇧R`), показывается как key-equivalent в пункте Stop menu bar и в окне настроек; при неудачной регистрации (конфликт сочетания) пользователь видит это в настройках, остановка остаётся доступной через menu bar + Dock.
- **Главное окно при Record — minimize (не hide)**, чтобы клик по Dock-иконке его восстанавливал. Восстановленное во время записи окно показывает таймер + Stop + счётчик дропов; конфигурационные контролы задизейблены с пояснением «недоступно во время записи».

## Decisions Made

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Режимы захвата в v1 | Только весь дисплей | Область/окно дают основную UI-сложность (overlay-селектор, ресайз окна); ядро пайплайна и синк от них не зависят → выносим в Phase 2 |
| Системный звук в v1 | Только микрофон | Соответствует исходному требованию «не захватывать всё»; system audio → Phase 2 |
| Превью | Превью камеры в окне настроек | Подтверждено пользователем; помогает выставить кадр до записи |
| Персистентность | Помнить последние устройства/путь/кодек (UserDefaults) | Подтверждено пользователем; удобно для повторных записей |
| Кодек/контейнер по умолчанию | HEVC + MOV | HEVC HW на всех M1+, малый размер; MOV — deliverable-формат, единственный с timecode-треком. H.264/MP4 — опции |
| ProRes / HDR | Исключены | Пользователь не хочет монтажные форматы; HDR не нужен (референс SDR). Снимает требование Max/Ultra |
| Потолок разрешения | Фокус 4K60; 5K — второй приоритет | 5K ведётся тем же кодом (probe + деградация), но качество/тесты затачиваются на 4K60 |
| Структура вывода | Session-папка `Recording <timestamp>/` с `screen.*`/`camera.*` | Файлы одной записи держатся вместе, очевидная пара для NLE |
| ≥1 видеоисточник | Обязателен; микрофон опционален | Запись без видео бессмысленна; mic fan-out во все присутствующие видеофайлы |
| Отказ writer'а | isolateAndContinue + уведомление | Не терять параллельный поток из-за одного сбоя (NLE-сценарий) |
| Старт записи | Немедленный, без countdown | Проще; countdown можно добавить позже |
| Синхронизация | host clock PTS + timecode (MOV) + идентичный mic в обоих файлах | Три независимых механизма, точный синк по построению |
| Acceptance-железо | MacBook Pro 14" M3 Max + внешний 4K60 | 2 encode engine → честный dual-stream 0-drop; SLA сформулирован по числу движков (1-движковые — через деградацию) |
| Остановка записи | menu bar + глобальный hotkey + Dock-иконка | Свёрнутое окно не должно «прятать» запись; ≥3 способа остановки + всегда видимый индикатор (AC-19) |
| Уведомления при свёрнутом окне | Системные (UserNotifications) | Ошибки источника/writer'а и старт/стоп должны доходить, когда главное окно свёрнуто (AC-17/20/21) |
| Динамическая деградация в v1 | Включена (RuntimeHealthMonitor + ladder с гистерезисом) | Осознанное решение: соответствует принципу «дропы не молча»; статический-отказ-вместо-ladder отвергнут как ухудшающий UX длинных записей. Триггеры калибруются на acceptance-железе |
| Отказ источника | isolateAndContinue (симметрично writer-failure) | Не терять параллельные потоки при unplug камеры/отзыве permission (AC-20) |

## Out of Scope

- Захват **области** дисплея и **отдельного окна** — *(owner: Agent, target: Phase 2)*.
- Захват **системного/прил­оженческого звука** — *(Phase 2)*.
- **ProRes** и любые «сырые» монтажные форматы — *(вне продукта; при необходимости — отдельный archival-режим)*.
- **HDR / 10-bit** запись — *(вне v1; референс SDR)*.
- Реал-тайм **композиция/PiP** (камера поверх экрана) — *(не требуется; раздельные файлы)*.
- **Pause/resume**, countdown-таймер, горячие клавиши, аннотации/курсор-эффекты, редактирование после записи — *(вне v1)*.
- **Множественные камеры одновременно** — *(вне v1)*.
- Запись **нескольких дисплеев** одновременно — *(вне v1; один выбранный дисплей)*.
- Загрузка/шеринг файлов куда-либо — *(вне продукта)*.
- Entitlement `com.apple.developer.persistent-content-capture` (захват экрана без повторных TCC-диалогов, требует одобрения Apple) — *(вне v1; стандартного TCC-флоу достаточно)*.

## Open Questions

- [ ] App Sandbox: включать ли sandbox для приложения? — *non-blocking*
  - Options: (A) без sandbox — проще с правами захвата экрана, но нельзя в Mac App Store; (B) с sandbox — нужны entitlements камеры/микрофона, возможны ограничения VideoToolbox `RequireHardwareAcceleratedVideoEncoder`.
  - Recommendation: (A) без sandbox для v1 (прямое распространение), т.к. цель — личный/проф-инструмент, не App Store; пересмотреть при необходимости публикации.
- [ ] Авто-битрейт: конкретные значения/формула. — *non-blocking*
  - Options: фикс-таблица (4K60 экран ~50 Mbit/s, 4K30 камера ~25 Mbit/s) vs формула от пикселей×fps.
  - Recommendation: формула `bitrate = pixels × fps × bppFactor` с bppFactor ~0.06 (экран) / ~0.10 (камера, motion), с advanced-override. Уточняется на приёмке по визуальному качеству.
- [ ] Timecode-трек в реальном времени (MOV): официального Swift-примера записи `CMTimeCode32` через `AVAssetWriterInput(mediaType: .timecode)` нет — требует экспериментальной валидации на этапе реализации. — *non-blocking*
  - Options: (A) писать timecode-трек (best-effort) — даёт авто-синк по таймкоду в NLE; (B) если real-time запись таймкода окажется нестабильной — отказаться от трека, оставив синхронизацию на host-clock PTS + идентичной аудиодорожке микрофона.
  - Recommendation: (A) с фолбэком на (B). Синхронизация по AC-12 гарантируется и без timecode-трека (PTS на общей шкале + waveform), поэтому timecode — улучшение, а не критичная зависимость; провал валидации не блокирует фичу.

## Future Phases

**Phase 2 — Область и окно + системный звук:** `SCStreamConfiguration.sourceRect` для области (+ overlay-селектор), `SCContentFilter(desktopIndependentWindow:)` для окна (+ пикер окон, обработка ресайза, `dynamicDimensions`), системный звук через `SCStream.capturesAudio` с маршрутизацией дорожек. Specится отдельно после валидации Phase 1.

**Phase 3 (кандидаты) — HDR/10-bit, ProRes archival-режим, мультидисплей/мультикамера, горячие клавиши и countdown.** По мере потребности.
