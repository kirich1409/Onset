---
type: spec-architecture
product: Onset
date: 2026-05-29
status: approved
---

# Onset — Architecture (общая техническая основа)

Общий фундамент, на который опираются все фичи. Feature-specs ссылаются сюда, а не дублируют. Связано с [`overview.md`](overview.md).

## Слои

Зависимости направлены внутрь: **Presentation** (SwiftUI + AppKit menu bar) → **Application** (`RecordingSessionCoordinator` actor, `SettingsStore`, `RuntimeHealthMonitor`) → **Domain** (протоколы + value-типы) ← **Infrastructure** (ScreenCaptureKit / AVFoundation / AVAssetWriter / VideoToolbox / Core Media).

Domain импортирует CoreMedia (`CMSampleBuffer`/`CMTime`/`CMClock`) как «язык» hot path — сознательная граница ради отсутствия аллокаций на горячем пути.

## Domain-протоколы (контракты между фичами)

```swift
protocol ClockProviding {            // фича: общая (sync), владелец recording-session
    var referenceClock: CMClock { get }              // host time clock
    func now() -> CMTime
    func convert(_ t: CMTime, from src: CMClock) -> CMTime  // CMSyncConvertTime
}
protocol CaptureSource: AnyObject {  // реализуют screen/camera/audio capture
    var kind: SourceKind { get }
    var sourceClock: CMClock { get }
    func configure(_ c: SourceConfiguration) throws
    func start(emittingTo sink: SampleSink) throws
    func stop()
}
protocol SampleSink: AnyObject {     // реализует SampleRouter (recording-session)
    func receive(_ buf: CMSampleBuffer, kind: SourceKind)
}
protocol EncodingWriter: AnyObject { // реализует AVAssetWriterPipeline (recording-session)
    func prepare(_ d: OutputDescriptor) throws
    func beginSession(atSourceTime t: CMTime)
    func append(_ buf: CMSampleBuffer, track: TrackKind)
    func finalize() async throws
    var health: WriterHealth { get }
    var isAlive: /* atomic Bool, acquire/release */ Bool { get }
}
```

`RecordingConfiguration` — **parse-don't-validate**: приватный init, конструируется ТОЛЬКО `Validator`'ом (фича `capability-and-settings`). «Гарантированно выполнимый» обеспечивается системой типов.

## Concurrency / hot path (общее правило для всех capture-фич)

- Real-time callback'и (`SCStreamOutput`, `AVCaptureVideoDataOutputSampleBufferDelegate`, аудио) — на выделенных **GCD serial-очередях** `com.app.capture.{screen,camera,audio}`. Внутри callback — только retain/enqueue + немедленный release исходного буфера/IOSurface.
- Для SCStream обязательно: время удержания буфера < `minimumFrameInterval × (queueDepth−1)` (queueDepth экрана 5–6).
- Запись — на serial-очередях `com.app.writer.{screen,camera}`; перед `append` — `guard input.isReadyForMoreMediaData`.
- **Никаких actor-хопов на пути сэмплов.** Actor (`RecordingSessionCoordinator`/`RuntimeHealthMonitor`) — только control plane.

## Backpressure-контракт (общий)

- **Видео-источники:** ограниченная очередь capture→writer фиксированной глубины. Переполнение / `!isReadyForMoreMediaData` → **drop-oldest** + `DroppedFrameStats` с причиной (`encoderBound`/`diskBound`). Capture-layer дропы тоже учитываются: камера — `captureOutput(_:didDrop:from:)` (`poolExhausted`/`captureBound`), экран — `SCFrameStatus` в attachments.
- **Аудио-путь микрофона — ЛОССЛЕСС**, drop-oldest НЕ применяется (буферы малы). Gap-fill тишиной и fan-out — **до** разветвления по writer'ам, оба файла получают идентичный поток (bit-identity). Потеря аудио-буфера — ошибка, не штатный режим.
- Callback никогда не блокируется ожиданием writer'а.

## Синхронизация (общая, гарантия — в recording-session/AC-12)

- Опорная шкала — `CMClockGetHostTimeClock()`. Экран (SCStream) и камера (`AVCaptureSession` **без аудиовхода**) уже на host-шкале. Микрофон — независимый источник на дрейфующих аудиочасах; PTS приводятся к host через `CMSyncConvertTime` перед append.
- **Микрофон держать ВНЕ сессии камеры** (иначе master clock слейвится к аудио-железу).
- Один источник микрофона → идентичные буферы в оба файла (bit-identity).

## Атомарный старт/стоп (общий механизм; AC-7/AC-12)

- **Старт (warm-up→T):** в `ready` по всем writer'ам сделан `startWriting()`; при Record — запустить все источники и дождаться first-sample от каждого (таймаут) → выбрать единое `T = host-now` → `startSession(atSourceTime: T)` по всем → admit PTS≥T (PTS<T отбрасываются). Re-validate generation snapshot перед стартом (TOCTOU).
- **Стоп:** фиксация T_end, остановка источников, дренаж буферов ≤ T_end, `finalize()` всех writer'ов, reveal папки в Finder (`OutputLayout`).

## Машина состояний (recording-session)

`idle → configuring → ready → recording → finalizing → done/error`. Ветки отказа: **writer-failure** (AC-17) и **source-failure** (AC-20) — обе `isolateAndContinue` (упавший выход финализируется как частичный, остальные продолжают; при падении последнего видеоисточника → `error`).

## SampleRouter ↔ writer health (wait-free)

`isAlive` — настоящий atomic Bool (acquire/release; не lock). Writer-queue выставляет false при фатальной ошибке; `SampleRouter` читает на hot path без блокировки и прекращает fan-out в мёртвый writer. `DroppedFrameStats` — per-source atomic-счётчики.

## Capability-модель (foundation; детали в capability-and-settings)

`CapabilityService` (actor) — версионированный snapshot: VideoToolbox-probe (HW-кодеки, max-разрешение), sysctl (tier/ядра), discovery дисплеев/камер/микрофонов, диск/термалка. Probe кэшируется; hotplug/thermal → bump generation. Правило приоритета: **probe — ground truth для single-stream; `CapabilityMatrix` — единственный источник для оценки числа одновременных сессий** (нет публичного API). Неизвестный чип → консервативный fallback по P-ядрам. MJPEG-decode камеры — отдельный член бюджета.

## Адаптивная деградация (foundation; детали в performance-and-degradation)

`DegradationLadder` — только динамически-принимаемые шаги (fps камеры → fps экрана → битрейт → отключение камеры); смена выходного разрешения mid-recording НЕ входит (фиксированные output-dimensions writer'а). Триггеры: дропы > N за окно T / `thermalState>=.serious` / memory watermark. Апгрейд — только после cooldown C при чистом окне; ratchet против осцилляции. Статическую выполнимость даёт Validator (+ margin); динамическую — эта петля.

## Кодек-политика (foundation; детали в capability-and-settings)

Перечислить HW-энкодеры (`VTCopyVideoEncoderList`, `IsHardwareAccelerated`); default HEVC HW (подтвердить разрешение `VTCopySupportedPropertyDictionaryForEncoder`); H.264 — опция; software по умолчанию не использовать. На M3 Max два потока раскладываются по двум движкам (эмерджентно, подтверждается AC-14).

## Верификация API против SDK macOS 26

На этапе реализации (не меняет дизайн): точная форма `synchronizationClock` (get-only vs settable), real-time timecode-трек, сигнатуры SCK/AVFoundation на финальном SDK. При расхождении — следовать SDK; host-clock-стратегия и «микрофон вне сессии камеры» остаются.

## Тестируемость (общая)

Unit/L2 без железа: `Validator`, `SampleRouter` (fan-out + isAlive), atomic start (drop PTS<T, warm-up→T), gap-fill до fan-out, `CMSyncConvertTime`, `DegradationLadder`-decider (чистый автомат). Hardware-acceptance (L5) — на референс-железе: AC-14/AC-10/AC-3/AC-4/AC-19/AC-20.

## Инструментация (общая)

Логгер по `rules/logging.md` (единая система, без `print`). События: `recording.start/stop`, `frame.dropped`, `source.failure`, `writer.failure`, `degradation.step`, `capability.probe`, `permission`. Metrics/Traces/Alerts/Dashboards — N/A (локальное приложение).
