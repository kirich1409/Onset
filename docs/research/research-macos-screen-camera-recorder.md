# Research: Нативное macOS-приложение для записи экрана + камеры + микрофона

Date: 2026-05-28
Experts consulted: Web, Docs (Apple frameworks), Architecture
Auto-review mode: tech-sanity

## Problem / Question Summary

Требуется полностью нативное macOS-приложение (Swift, Apple Silicon, macOS 26+) для одновременной записи экрана (оригинальное разрешение, до 5K@60), внешней камеры (до 4K@60) и выбранного микрофона в **раздельные файлы** с общим таймкодом для последующей синхронизации в NLE. Микрофон пишется дорожкой в оба видеофайла (для выравнивания по аудиоволне). Нужны выбор области экрана, выбор конкретного микрофона/камеры, отсутствие задержек и дропов кадров. Целевое железо — широкий диапазон Apple Silicon с адаптивной деградацией под возможности чипа.

## Approaches Found

### Approach 1: Ручной pipeline SCStream + AVCaptureSession → AVAssetWriter (рекомендуемый)

- **Description:** Экран захватывается через `SCStream` (ScreenCaptureKit), камера — через `AVCaptureSession` + `AVCaptureVideoDataOutput`, микрофон — отдельным источником. Сырые `CMSampleBuffer` из каждого источника вручную аппендятся в свой `AVAssetWriter` (по файлу на источник видео). Полный контроль над таймкодом, кодеком, fan-out микрофона в оба файла.
- **Trade-offs:** Максимальный контроль и качество; требует аккуратной работы с первым кадром, заполнением аудиопробелов, backpressure. Больше кода, чем у высокоуровневого API.
- **Evidence:** Web (паттерн A — используется OBS, ScreenSage, проф. рекордерами), Docs (полный API подтверждён), Architecture (детальный дизайн слоёв).
- **Compatibility:** Базовый API ScreenCaptureKit с macOS 12.3; нужные свойства синхронизации — macOS 13+. Подходит под все требования.

### Approach 2: SCRecordingOutput (высокоуровневый, macOS 15+)

- **Description:** `SCStream.addRecordingOutput(_:)` + `SCRecordingOutputConfiguration` — Apple сама пишет экран + аудио в файл.
- **Trade-offs:** Минимум кода, но: один файл, нет доступа к сырым буферам, нет управления таймкодом и кодеком, нельзя писать в несколько файлов одновременно. **Не покрывает требование раздельных файлов с аудиодорожкой в каждом** → не подходит как основной путь, годится только как fallback для упрощённого режима.
- **Evidence:** Web (паттерн B), Docs (API подтверждён, macOS 15+).
- **Compatibility:** macOS 15+, ограниченная функциональность.

### Approach 3 (ортогональный выбор): источник микрофона — SCStream vs отдельный AVCaptureSession

- **SCStream `captureMicrophone`** (macOS 15+): микрофон внутри стрима экрана, выбор по `microphoneCaptureDeviceID`. Минус: появился только в macOS 15, и привязывает микрофон к стриму экрана.
- **Отдельный `AudioCaptureSource`** (рекомендуемый): независимая аудио-only `AVCaptureSession` / `AVCaptureAudioDataOutput`. **Намеренно держим микрофон ВНЕ сессии камеры** — иначе `AVCaptureSession` слейвит master clock к часам аудиоустройства, и `synchronizationClock` камеры перестаёт совпадать с host clock. Один источник микрофона → fan-out одинаковых буферов в оба writer'а.
- **Evidence:** Architecture (ключевое решение по синхронизации), Docs (`AVCaptureMultiCamSession` на macOS недоступен → отдельные сессии всё равно обязательны).

### Side-by-side comparison

| Dimension | Ручной pipeline (A) | SCRecordingOutput (B) |
|---|---|---|
| Раздельные файлы + аудио в каждом | ✓ да | − нет (один файл) |
| Таймкод-трек | ✓ полный контроль | − нет |
| Выбор кодека (HEVC/ProRes) | ✓ да | − ограничен |
| Объём кода | L (большой) | S |
| Risk | medium (нужна аккуратность тайминга) | low, но не покрывает задачу |
| Вердикт | **основной путь** | fallback / упрощённый режим |

## Стек фреймворков (нативный, без зависимостей)

| Слой | Фреймворк | Ключевые типы |
|---|---|---|
| Захват экрана | ScreenCaptureKit | `SCShareableContent`, `SCContentFilter`, `SCStream`, `SCStreamConfiguration`, `SCStreamOutput` |
| Захват камеры/микрофона | AVFoundation | `AVCaptureSession`, `AVCaptureDevice.DiscoverySession`, `AVCaptureDeviceInput`, `AVCaptureVideoDataOutput`, `AVCaptureAudioDataOutput` |
| Запись в файл | AVFoundation | `AVAssetWriter`, `AVAssetWriterInput` (video/audio/timecode), `AVAssetWriterInputPixelBufferAdaptor` |
| Кодирование | VideoToolbox | автоматически через AVAssetWriter; `VTCompressionSession` — для тонкой настройки |
| Синхронизация | Core Media | `CMClockGetHostTimeClock()`, `CMSampleBuffer.presentationTimeStamp`, `CMSyncConvertTime`, `CMTimebase` |
| UI | SwiftUI | — |

## Ключевые технические выводы (конвергенция всех дорожек)

1. **Единая шкала времени — host time clock** (`CMClockGetHostTimeClock()`). Экран (SCStream) и камера (AVCaptureSession без аудиовхода) штампуют PTS на host clock → их PTS сравнимы напрямую, конвертация не нужна. Микрофон едет на дрейфующих часах аудио-железа → его PTS конвертируются на host через `CMSyncConvertTime` перед append. Это единственная точка примирения дрейфа.
2. **Real-time callback нельзя блокировать.** Правило ScreenCaptureKit (WWDC22): время на release буфера < `minimumFrameInterval × (queueDepth − 1)`. В callback — только retain/copy буфера + enqueue; кодирование и запись — на отдельной serial-очереди. Архитектура: весь hot path на GCD serial queues, **без actor-хопов**; actor — только control plane (старт/стоп/состояние).
3. **Конфигурация 60fps / оригинального разрешения:** `minimumFrameInterval = CMTime(1, 60)`, `captureResolution = .best` (иначе SCK отдаёт масштабированный буфер), `queueDepth` 5–6 (макс. 8). Для камеры — подбор `activeFormat` по `videoSupportedFrameRateRanges` + `activeVideoMin/MaxFrameDuration = CMTime(1,60)`.
4. **Выбор области экрана** — через `SCStreamConfiguration.sourceRect` (координаты в точках дисплея), а не через `SCContentFilter`. Инициализатора `SCContentFilter(display:rect:)` нет.
5. **Микрофон в оба файла идентичными буферами** → кросс-файловое аудиовыравнивание точное по построению (бит-в-бит), не приближённое. Плюс таймкод-трек (только в `.mov`) со стартовым SMPTE от общего host-времени T.
6. **Атомарный старт N writer'ов:** `startWriting()` заранее (медленная преаллокация в фазе ready), затем выбор одного host-времени T и `startSession(atSourceTime: T)` по всем writer'ам; на hot path drop сэмплов с PTS < T. Общая нулевая точка всех файлов = T.
7. **Кодек — главный рычаг рисков:**
   - **HEVC (HW)** — малый размер, но 5K HEVC выше 4K имеет риск slow-path в VideoToolbox; H.264 ограничен 4096×2304.
   - **ProRes 422 HQ** — нет лимита по разрешению, готов к NLE, но многогигабитный поток на файл (дисковый I/O).
   - Контейнер `.mov` обязателен для таймкод-трека (MP4 не поддерживает `.timecode`).

## Архитектура (greenfield, опорный дизайн)

Четыре слоя, зависимости внутрь: Presentation (SwiftUI) → Application (`RecordingSessionCoordinator` actor) → Domain (протоколы `CaptureSource`/`SampleSink`/`EncodingWriter`/`ClockProviding`) ← Infrastructure (`ScreenCaptureSource`, `CameraCaptureSource`, `AudioCaptureSource`, `HostClockService`, `AVAssetWriterPipeline`, `DeviceDiscoveryService`, `RegionSelector`, `PermissionsManager`).

- Domain допускает импорт CoreMedia (CMSampleBuffer/CMTime/CMClock) как «язык» hot path — абстрагировать его вредно (лишние аллокации).
- Очереди: `com.app.capture.{screen,camera,audio}` (приём), `com.app.writer.{screen,camera}` (запись), QoS `.userInitiated`.
- Машина состояний: `idle → configuring → ready → recording → finalizing → done/error`.
- Fan-out микрофона живёт в реализации `SampleSink` (`SampleRouter`) — единственное место, знающее топологию источник→файлы.

## Адаптивная деградация (целевое требование — любой Apple Silicon)

Поскольку приложение должно работать на любом Apple Silicon, выполнимость 5K60+4K60 одновременно зависит от числа аппаратных энкодеров:

| Чип | H.264/HEVC encode engines | Одновременный 5K60 + 4K60 |
|---|---|---|
| M1/M2/M3/M4 (base) | 1 | риск дропов → деградация |
| M*/Pro | 1 | риск дропов → деградация |
| M*/Max | 2 | реалистичен (HEVC, возможен ProRes) |
| M*/Ultra | 4 | с запасом (ProRes на оба файла) |

Архитектурное решение: `EncoderCapabilityProbe` оценивает возможности чипа **до старта записи**, подбирает максимально безопасные настройки и при нехватке применяет деградацию по политике (снизить fps/разрешение камеры, либо экран, либо предупредить пользователя) — до начала записи, не во время. `NSProcessInfo.thermalState` — мониторинг термального дросселя при длительных записях.

## Risks and Concerns

- **Насыщение HW-энкодера на base/Pro чипах при 5K60+4K60** — major. Точный предел не задокументирован Apple, требует бенчмарка на целевых чипах. Митигация: `EncoderCapabilityProbe` + адаптивная деградация до старта.
- **Аудиодрейф (A/V drift)** — major. Причина: разные sample rate источников. Митигация: единый 48000 Гц во всех источниках; CMSync-конвертация PTS микрофона на host.
- **Аудиопробелы (Core Audio gaps)** — major. Задокументированный баг: AVCaptureSession/AVAudioEngine иногда пропускают аудиопакеты со сдвигом PTS без буфера → аудио короче видео навсегда. Митигация: детект разрыва PTS и заполнение тишиной перед append.
- **5K HEVC slow-path в VideoToolbox** — major. Выше 4K HEVC может упасть до software path (5–10 fps). Митигация: ограничить 5K через ProRes или масштабировать до 4K на слабых чипах.
- **Дисковый I/O двух высокобитрейтных потоков (особенно ProRes)** — medium. Митигация: `DiskThroughputGuard` до старта; по возможности разные тома для ProRes.
- **Частичный отказ writer'а в середине записи** — medium. Митигация: per-writer `WriterHealth`, политика по умолчанию `.isolateAndContinue` (упавший файл финализируется как частичный, остальные потоки продолжают) с явной маркировкой.
- **Первый кадр / чёрное начало** — minor. Митигация: `startSession` от относительного времени, привязка PTS к `firstSampleTime`.
- **Sandbox + аппаратный энкодер** — minor. В Sandbox явное `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder` может вернуть ошибку; HW-энкодер всё равно работает автоматически через AVFoundation.

## Противоречие между источниками (разрешено)

**`AVCaptureSession.synchronizationClock` / `SCStream.synchronizationClock` — записываемые или read-only?**
Web-дорожка привела код вида `session.synchronizationClock = CMClockGetHostTimeClock()` (инжект своих часов). Architecture-дорожка (более строго, со ссылкой на developer.apple.com) утверждает: **`synchronizationClock` доступно только на чтение** — инжектировать свои часы нельзя; вместо этого host clock уже является базой источников, а задача — не «впихнуть один CMClock везде», а привести дрейфующий микрофон к host через CMSync. Docs-дорожка описывает `synchronizationClock` как часы, на которых *уже находятся* выходные буферы (чтение).

**Разрешение:** принимаем строгую трактовку (read-only) — она согласуется с историческим read-only `masterClock` и с Docs-дорожкой. Практический вывод от выбора не зависит: host clock — общая шкала в обоих случаях, и ключевая митигация (держать микрофон вне сессии камеры) обязательна независимо. **Требует подтверждения на этапе реализации против фактического SDK macOS 26** — get-only vs settable меняет 2 строки кода, не дизайн.

## Permissions / Entitlements

- `Info.plist`: `NSCameraUsageDescription`, `NSMicrophoneUsageDescription` (обязательны).
- Screen Recording — TCC-разрешение (Системные настройки → Конфиденциальность → Запись экрана); программного запроса нет, диалог вызывается первым обращением к `SCShareableContent.get*`.
- App Sandbox: `com.apple.security.device.camera`, `com.apple.security.device.microphone`.
- `com.apple.developer.persistent-content-capture` (macOS 14.4+) — для постоянного захвата без повторных диалогов (требует одобрения Apple).

## Recommendation

Строить на **Approach 1** (ручной pipeline SCStream + AVCaptureSession → AVAssetWriter) с отдельным `AudioCaptureSource` вне сессии камеры (Approach 3, рекомендуемый вариант). Единая шкала — host time clock; микрофон fan-out идентичными буферами в оба `.mov` + таймкод-трек от общего T. Кодек по умолчанию **HEVC (HW)**, ProRes — опциональный режим под Max/Ultra с проверкой дискового I/O. Обязателен `EncoderCapabilityProbe` + адаптивная деградация под чип (требование «любой Apple Silicon»). Весь real-time-тракт на GCD serial-очередях без actor-хопов; control plane — на actor `RecordingSessionCoordinator`. Гарантия «no drops» = предотвращать насыщение энкодера/диска и вскрывать состояние (`DroppedFrameStats` в UI), а не молча терять кадры.

Минимальная база — macOS 13 (для `synchronizationClock` и системного аудио); `captureMicrophone` в SCStream — только macOS 15+, поэтому отдельный аудиоисточник также даёт совместимость вниз.

## Known Unknowns

- **Полная документация macOS 26 ("Tahoe")** по ScreenCaptureKit / AVFoundation / VideoToolbox на developer.apple.com на 2026-05-28 ещё не опубликована (ранняя бета). Изменений streaming-API в xcode26 beta не зафиксировано (нововведения — screenshot/privacy). Подтвердить против финального SDK при старте реализации.
- **Точный предел одновременного аппаратного HEVC-энкода 5K60 + 4K60** для каждого класса чипа Apple не публикует — определяется бенчмарком на целевом железе. Влияет на пороги деградации в `EncoderCapabilityProbe`.
- **Создание timecode-трека из real-time** (`CMTimeCodeFormatDescriptionCreate`, `CMTimeCode32`) официального Swift-примера в документации не имеет — потребует экспериментальной валидации.

## Sources

- ScreenCaptureKit: https://developer.apple.com/documentation/screencapturekit
- SCStreamConfiguration: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration
- queueDepth: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/queuedepth
- captureResolution: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/captureresolution
- sourceRect: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/sourcerect
- AVCaptureSession.synchronizationClock: https://developer.apple.com/documentation/avfoundation/avcapturesession/synchronizationclock
- AVAssetWriter: https://developer.apple.com/documentation/avfoundation/avassetwriter
- WWDC22 «Take ScreenCaptureKit to the next level»: https://developer.apple.com/videos/play/wwdc2022/10155/
- WWDC24 «Capture HDR content with ScreenCaptureKit»: https://developer.apple.com/videos/play/wwdc2024/10088/
- TN2310 (Timecode): https://developer.apple.com/library/archive/technotes/tn2310/_index.html
- Nonstrict — recording to disk with SCK: https://nonstrict.eu/blog/2023/recording-to-disk-with-screencapturekit/
- Nonstrict — audio capture gaps: https://nonstrict.eu/blog/2024/handling-audio-capture-gaps-on-macos/
- Softron — Apple Silicon HW accelerators: https://softron.zendesk.com/hc/en-us/articles/11209248309020
- Sunshine — VideoToolbox HEVC 5K slow path: https://github.com/LizardByte/Sunshine/issues/5095
- OBS ScreenCaptureKit PR: https://github.com/obsproject/obs-studio/pull/5875
- dotnet/macios SCK xcode16: https://github.com/dotnet/macios/wiki/ScreenCaptureKit-macOS-xcode16.0-b1
- dotnet/macios SCK xcode26: https://github.com/dotnet/macios/wiki/ScreenCaptureKit-macOS-xcode26.0-b1
- ScreenSage architecture: https://fatbobman.com/en/posts/screensage-from-pixel-to-meta/

---

# Addendum (2026-05-29): настройки записи, детекция железа, кодеки, UX-сценарий

Experts consulted (addendum): Web (реальные лимиты железа), Docs (API настроек + детекция), Architecture (модель Settings & Capability).

## Референсная конфигурация (зафиксирована пользователем)

| Компонент | Значение | Следствие для дизайна |
|---|---|---|
| **Дисплей** | 4K (3840×2160) @ **60fps**, **SDR (без HDR)** | SDR-пайплайн: 8-bit pixelFormat (`32BGRA` / `420v`), без `captureDynamicRange`, без 10-bit и EDR-ветки. Экран 4K (не 5K) → проходит лимит H.264 4096×2304 |
| **Камера** | Logitech MX Brio — **4K@30** или **1080p@60** (MJPEG на 4K) | путь MJPEG→decode→encode; типовой профиль камеры 4K@30 |
| **Кодек/выход** | HEVC HW (default) / H.264 HW, контейнер MOV (default) / MP4 | оба кодека валидны для 4K (≤ H.264-лимита); HEVC предпочтителен по размеру |

**Нагрузка референс-сценария:** 4K60 экран + 4K30 камера, оба HEVC HW, SDR. Это умеренная нагрузка на один аппаратный HEVC-движок (~1.5× от одиночного 4K60). Комфортно тянет любой M-чип от Pro и выше; на base M1 — на грани, страхуется capability-probe + адаптивной деградацией.

**Область планирования: потолок — 4K, 5K поддерживается вторым приоритетом.** ProRes и HDR из требований выпали окончательно. **5K не выпал** — остаётся поддерживаемым через ту же capability-детекцию (HEVC HW; 5K экран → только HEVC, H.264 не покрывает >4096 шириной), но **фокус и проектный потолок MVP — 4K60**. 5K-дисплей (Studio Display / Pro Display XDR) обрабатывается тем же кодом: probe подтверждает HEVC на 5K, при нехватке движка — адаптивная деградация (даунскейл до 4K либо снижение fps). То есть 5K — это «работает и не ломается», а не «оптимизируется в первую очередь». Референсный путь, на котором затачивается качество и тесты, — **SDR 4K60 HEVC MOV**.

## A. Типовой сценарий (UX-флоу, со слов пользователя)

1. Запуск приложения → сразу окно настроек записи.
2. Выбор источников (любой можно отключить):
   - **Камера**: выпадающий список обнаруженных камер + вариант «без камеры».
   - **Микрофон**: список обнаруженных микрофонов (+ вариант «без звука»). Звук пишется дорожкой в оба видеофайла.
   - **Экран**: включить запись экрана + выбор охвата — весь дисплей (какой именно), область, или отдельное окно.
3. Выбор **пути сохранения** (папка для готовых файлов).
4. Выбор **кодека** (см. раздел E) — по умолчанию подставляется оптимальный аппаратный для текущего чипа.
5. Нажатие **Record** → запись стартует, главное окно сворачивается.
6. **Иконка в menu bar** (статус-айтем) для быстрой остановки (и индикации, что идёт запись). Это `NSStatusItem` в правой части строки меню — на macOS «трея» нет, аналог — menu bar extra.
7. **Stop** → файлы финализируются и сохраняются в выбранную папку. Готовые раздельные файлы (экран / камера) с общим таймкодом и встроенным микрофоном — можно нести в монтажку и синхронизировать.

Архитектурно это ложится на уже спроектированную машину состояний: окно настроек = фаза `configuring`; готовый валидный конфиг = `ready`; Record = атомарный старт всех writer'ов; menu bar Stop = атомарный стоп → `finalizing` → `done`.

## B. Матрица настроек записи (что отдаётся пользователю)

| Группа | Настройка | API / тип | Зависимость от железа |
|---|---|---|---|
| Экран — охват | весь дисплей / область / окно | `SCContentFilter` (display / desktopIndependentWindow), `sourceRect` для области | список дисплеев/окон от `SCShareableContent` |
| Экран — разрешение | native / fixed | `SCStreamConfiguration.width/height`, `captureResolution = .best` | потолок = нативный пиксельный размер дисплея |
| Экран — fps | до 60 (или 120 ProMotion) | `minimumFrameInterval = CMTime(1, fps)` | ≤ `NSScreen.maximumFramesPerSecond` дисплея |
| Экран — HDR | вкл/выкл | `captureDynamicRange` (macOS 15+) | только если дисплей HDR-capable (EDR > 1.0) |
| Камера — устройство | список | `AVCaptureDevice.DiscoverySession` | обнаруженные камеры (external / builtIn / continuity) |
| Камера — разрешение+fps | только поддерживаемые | перебор `device.formats` → `videoSupportedFrameRateRanges` | строго из того, что камера сообщает (часто реальный максимум 4K@30) |
| Микрофон — устройство | список | `AVCaptureDevice.DiscoverySession` (audio) | обнаруженные микрофоны |
| Аудио | sample rate 48 кГц, AAC/PCM | `AVAssetWriterInput` audio settings | фиксируем 48 кГц во всех источниках (против дрейфа) |
| Кодек | HEVC / H.264 / ProRes* | `AVVideoCodecType`, VideoToolbox | приоритет аппаратным; ProRes только при наличии HW ProRes-движка (см. E) |
| Битрейт | auto / fixed | `AVVideoAverageBitRateKey` | auto-расчёт по разрешению+fps |
| Контейнер | `.mov` | `AVFileType.mov` | обязателен для timecode-трека |
| Путь | папка | `URL` | свободное место (`volumeAvailableCapacityForImportantUsage`) |

## C. Детекция возможностей железа (runtime API)

- **Дисплей**: `SCShareableContent.displays` → `SCDisplay` (логические точки!); реальный пиксельный размер — `CGDisplayCopyDisplayMode` + `CGDisplayModeGetPixelWidth/Height`; макс. refresh — `NSScreen.maximumFramesPerSecond`; HDR — `NSScreen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0`.
- **Камера**: `device.formats` → `CMVideoFormatDescriptionGetDimensions` (разрешение) + `videoSupportedFrameRateRanges` (fps) + `supportedColorSpaces` (HDR через `.HLG_BT2020`). Тип: `.external` (macOS 14+), `.continuityCamera` (macOS 13+). На macOS `isVideoHDRSupported`/`isBinned` недоступны (только iOS).
- **Энкодер (главное)**: `VTCopyVideoEncoderList` → перечень с `kVTVideoEncoderList_IsHardwareAccelerated`; `VTCopySupportedPropertyDictionaryForEncoder(width:height:codecType:...)` → подтверждает, что чип умеет конкретный кодек на конкретном разрешении (noErr = умеет). Публичного API для числа одновременных сессий **нет** — берётся из эвристической таблицы по tier чипа.
- **Чип/система**: `sysctlbyname("hw.model")`, `"machdep.cpu.brand_string"`, `"hw.perflevel0/1.physicalcpu"` (P/E ядра); `ProcessInfo.thermalState` (+ нотификация); свободное место — `URLResourceValues.volumeAvailableCapacityForImportantUsage`.

## D. Реальные лимиты железа («что может записать устройство»)

**Аппаратные движки кодирования по чипам:**

| Чип | H.264/HEVC encode | ProRes encode |
|---|---|---|
| M1 (base) | 1 | **нет (CPU)** |
| M2/M3/M4 (base) | 1 | 1 |
| M*/Pro | 1 | 1 |
| M*/Max | **2** | **2** |
| M*/Ultra | **4** | **4** |

**Что реально пишется без дропов:**
- Один HEVC-поток 4K60 или 5K60 — любой M1+.
- Два одновременных HEVC-потока (5K60 экран + 4K60 камера) — надёжно на Pro+, на base есть риск (один движок делится).
- Два одновременных **ProRes**-потока 5K60+4K60 — **только Max/Ultra** (2+ движка). На base/Pro один ProRes-движок не параллелит честно.
- M1 base: нет аппаратного ProRes вообще → принудительно HEVC.

**Камера (реальность UVC/USB):** «4K60-вебкамера» почти всегда = MJPEG 4K@30, реже MJPEG 4K@60 (Elgato Facecam 4K), несжатый 4K60 — только Facecam Pro класс. Continuity Camera (iPhone) — максимум 1920×1440@30. UI проектировать под типичный максимум вебкамеры 4K@30. Источник форматов — то, что камера реально сообщает через `device.formats`.

**Дисплей:** захват не может превысить refresh дисплея (60 Гц → макс 60fps; ProMotion → 120). 5K@60 возможен только на 5K-дисплее (Studio Display, Pro Display XDR 6K); встроенный экран MacBook Pro ~3–3.5K, не 5K.

**Диск:** ProRes 422 HQ — 4K60 ≈ 221 MB/s (~13 ГБ/мин), 5K60 ≈ ~393 MB/s (~23 ГБ/мин); два потока 5K60+4K60 ≈ ~614 MB/s (~36 ГБ/мин). Внутренний SSD Apple (3–7 ГБ/с) тянет с запасом; USB 3.0 HDD — нет. HEVC несопоставимо легче (~6 MB/s при 50 Mbit/s).

## E. Политика выбора кодека + выходной формат (РЕШЕНО)

**Решение пользователя (2026-05-29): на выходе только deliverable-форматы MP4/MOV; сырые монтажные форматы (ProRes) НЕ нужны.** Это отменяет ProRes-ветку из основного отчёта и снимает требование к Max/Ultra.

Кодек выбирается пользователем, логика по умолчанию:

1. **Перечислить аппаратные энкодеры** через `VTCopyVideoEncoderList`, отфильтровать `IsHardwareAccelerated == true`.
2. **По умолчанию — HEVC HW** (есть на всех M1+, лучший размер/качество, малая нагрузка на диск ~6 MB/s при 50 Mbit/s). Подтвердить разрешение через `VTCopySupportedPropertyDictionaryForEncoder`.
3. **H.264 HW** — как опция совместимости (лимит 4096×2304; для 5K экрана нужен HEVC или даунскейл).
4. **ProRes исключён** из палитры (пользователь не хочет монтажные форматы). Если когда-нибудь понадобится — добавляется отдельным «archival»-режимом.
5. **Никогда не уходить в software-энкод по умолчанию.** Форс SW-only комбинации → явное предупреждение.
6. **Эффективное использование M-чипа:** два потока (экран + камера) — две независимые `AVAssetWriter`/энкодер-сессии. На Max/Ultra VideoToolbox раскладывает их по двум движкам (≈2× throughput; «один поток = один движок» оптимально). На одно-движковых чипах два HEVC-потока делят движок — снижать менее приоритетный (камеру) при нехватке. AV1 на M3+ — только декод, для энкода недоступен.

**Следствие для железа (важно):** раз ProRes больше не нужен, headline-сценарий = **HEVC HW для обоих потоков в MP4/MOV**. Это резко расширяет совместимое железо — двойной HEVC-энкод (5K60 экран + 4K30 камера) реально тянет любой M-чип от Pro и выше, а с MX Brio (4K@30, см. § камеры) нагрузка ещё мягче. Требование «Max/Ultra» из базового отчёта относилось только к двойному ProRes и теперь неактуально.

### Выбор контейнера: MOV vs MP4

| | MOV | MP4 |
|---|---|---|
| HEVC / H.264 | ✓ | ✓ |
| **Timecode-трек** (авто-синк в NLE) | ✓ поддерживается | ✗ не поддерживается |
| Совместимость с плеерами/монтажками | отличная (нативно Apple, читается везде) | максимально универсальная |

**Рекомендация: MOV + HEVC по умолчанию.** MOV — это тоже стандартный deliverable-контейнер (не «сырой» формат), играет везде, и единственный, который позволяет писать timecode-трек для автоматической синхронизации в монтажке. MP4 оставить опцией для тех, кому нужна предельная универсальность — но тогда синхронизация только по (а) общему host-clock PTS и (б) идентичной аудиодорожке микрофона в обоих файлах (timecode-трека не будет). Оба механизма синка остаются рабочими и в MP4; timecode — это бонус MOV.

## F. Архитектура слоя Settings & Capability

Поток: `CapabilityService (actor, версионированный snapshot) + SettingsStore (мутабельный черновик Selections) → Validator (чистая функция) → Result<RecordingConfiguration, [ValidationIssue]> → RecordingSessionCoordinator (иммутабельный конфиг)`.

- **`RecordingConfiguration` — parse-don't-validate**: приватный init, конструируется только `Validator`'ом → «гарантированно выполнимый» обеспечен системой типов.
- **Capability discovery**: на launch — полный (включая дорогой VT-probe, кэшируется); на hotplug камеры/дисплея и смену thermalState — частичный refresh с инкрементом `generation`.
- **Capture scope** — типизированный enum: `.fullDisplay(id)` / `.region(id, rect)` / `.window(id)`. Окно даёт `dynamicDimensions = true` (размер меняется при ресайзе) → writer резолвится по worst-case bounding box.
- **Presets** (`.maxQuality / .balanced / .smallFile / .custom`) резолвятся в конкретные Selections под обнаруженные возможности; деградация по tier data-driven через `CapabilityMatrix`.
- **UI-привязка**: показывать только поддерживаемое (fps-picker камеры — из её форматов), недоступное — дизейблить с причиной («5K60 ProRes требует Max/Ultra»), live-резолв на каждое изменение.
- **Правило приоритета источников**: probe выигрывает для single-stream фактов; эвристическая таблица — единственный источник для multi-stream count (нет API). Неизвестный/будущий чип → консервативный fallback по числу P-ядер; single-stream потолки всё равно реальные (probe).
- **Граница static↔dynamic feasibility**: `Validator` гарантирует только статическую выполнимость + запас; thermal-дропы — зона adaptive degradation. Resolved-конфиг несёт `DegradationLadder` (заранее посчитанный порядок сброса: камера fps → экран fps → downscale → смена кодека → отключение камеры).

## Дополнения к Known Unknowns

- Точное HDR-свойство `SCStreamConfiguration` и форма VideoToolbox ProRes-probe на macOS 26 — подтвердить против финального SDK.
- Реальный потолок одновременного HW-энкода на конкретном чипе — нет публичного API, нужна калибровка/бенчмарк; эвристическая `CapabilityMatrix` закрывает пробел консервативно.
- Поведение ScreenCaptureKit при ресайзе окна во время записи (`.window` scope) — публичной гарантии нет, проверить эмпирически.

## Дополнительные источники (addendum)

- VTCopyVideoEncoderList / IsHardwareAccelerated: https://developer.apple.com/documentation/videotoolbox/vtcopyvideoencoderlist(_:_:)
- VTCopySupportedPropertyDictionaryForEncoder: https://developer.apple.com/documentation/videotoolbox/vtcopysupportedpropertydictionaryforencoder(width:height:codectype:encoderspecification:encoderidout:supportedpropertiesout:)
- SCDisplay / SCWindow / SCContentFilter: https://developer.apple.com/documentation/screencapturekit/sccontentfilter
- AVCaptureDevice.Format: https://developer.apple.com/documentation/avfoundation/avcapturedevice/format
- NSScreen EDR / maximumFramesPerSecond: https://developer.apple.com/documentation/appkit/nsscreen
- Apple ProRes data rates: https://en.wikipedia.org/wiki/Apple_ProRes
- Softron Apple Silicon HW accelerators: https://softron.zendesk.com/hc/en-us/articles/11209248309020
- NSStatusItem (menu bar): https://developer.apple.com/documentation/appkit/nsstatusitem
