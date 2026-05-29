# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Проект

**Onset** — нативное **macOS**-приложение (Swift, Apple Silicon, deployment target macOS 26.5) для одновременной записи экрана, внешней камеры и микрофона в **раздельные синхронизируемые файлы** для монтажа. Bundle id `dev.androidbroadcast.onset`.

> Внимание: `ast-index` определяет проект как «iOS (Swift/ObjC)» по эвристике — это **macOS**-таргет (`SDKROOT = macosx`). Команды/destination всегда для macOS.

На текущий момент в репозитории — Xcode-скелет (шаблонные `onsetApp.swift`/`ContentView.swift`/`Item.swift`) и **полная спецификация** в `docs/`. Реализация ведётся по спекам; они — источник истины (`status: approved`).

## Документация — источник истины

Перед реализацией любой фичи прочитай соответствующие спеки. Структура `docs/` зеркалит будущие модули кода (вертикальный срез на фичу):

- `docs/spec/overview.md` — scope MVP, карта фич, граф связей, общие Decisions, референс-железо.
- `docs/spec/architecture.md` — слои, Domain-протоколы, concurrency/hot-path, backpressure, синхронизация, state machine. **Читать первым** при любой работе с пайплайном.
- `docs/spec/non-functional-requirements.md` — кросс-каттинг NFR (контракт, не «по возможности»).
- `docs/spec/testing.md` — уровни тестов + команды верификации выходных файлов (`ffprobe`/`ffmpeg`).
- `docs/<feature>/{spec.md,test-plan.md}` — по фичам: `screen-capture`, `camera-capture`, `audio-capture`, `capability-and-settings`, `recording-session`, `recording-control-ui`, `performance-and-degradation`, `permissions`. Каждый spec содержит блок `## Dependencies` и `## AC` (acceptance criteria, стабильные id `AC-N`). TC-id (`TC-1…TC-43`) стабильны across всех test-plan'ов.

## Команды

Схема: `onset`. Таргеты: `onset`, `onsetTests` (unit), `onsetUITests` (UI).

```bash
# Build (Debug)
xcodebuild -project onset.xcodeproj -scheme onset -configuration Debug build

# Все тесты (unit + UI) на macOS
xcodebuild test -project onset.xcodeproj -scheme onset -destination 'platform=macOS'

# Только unit-таргет
xcodebuild test -project onset.xcodeproj -scheme onset -destination 'platform=macOS' -only-testing:onsetTests

# Один тест-класс / один метод
xcodebuild test -project onset.xcodeproj -scheme onset -destination 'platform=macOS' -only-testing:onsetTests/SampleRouterTests
xcodebuild test -project onset.xcodeproj -scheme onset -destination 'platform=macOS' -only-testing:onsetTests/SampleRouterTests/testFanOut
```

L5 hardware-acceptance не автоматизируется в CI — требует референс-железа (MacBook Pro 14" M3 Max + внешний 4K60 + Logitech MX Brio); верифицируется по чек-листу и пост-анализу файлов (`docs/spec/testing.md` Appendix A).

## Архитектурные инварианты (требуют чтения нескольких файлов)

Это правила, нарушение которых ломает продукт; они размазаны по `architecture.md` + NFR и не выводятся из одного файла:

- **Слои, зависимости внутрь:** Presentation (SwiftUI + AppKit menu bar) → Application (`RecordingSessionCoordinator` actor, `SettingsStore`, `RuntimeHealthMonitor`) → Domain (протоколы + value-типы) ← Infrastructure (ScreenCaptureKit/AVFoundation/AVAssetWriter/VideoToolbox/CoreMedia). Domain **сознательно** говорит на языке CoreMedia (`CMSampleBuffer`/`CMTime`/`CMClock`) на hot path — это граница ради zero-alloc, не нарушение чистоты.
- **Hot path неприкосновенен:** real-time callback'и (SCStream/AVCapture/audio) на выделенных GCD serial-очередях `com.app.capture.{screen,camera,audio}`; внутри — только retain/enqueue + немедленный release буфера/IOSurface. **Никаких actor-хопов на пути сэмплов** — actor'ы это только control plane. Время удержания SCStream-буфера < `minimumFrameInterval×(queueDepth−1)`.
- **Backpressure асимметричен:** видео — bounded-очередь, переполнение → drop-oldest + `DroppedFrameStats` с причиной. **Аудио микрофона — лосслесс**, drop запрещён; gap-fill тишиной и fan-out выполняются **до** разветвления по writer'ам → оба файла бит-идентичны.
- **Синхронизация:** опорная шкала `CMClockGetHostTimeClock()`; микрофон держать **вне** `AVCaptureSession` камеры (иначе master clock слейвится к аудио-железу), PTS приводить через `CMSyncConvertTime`.
- **Parse-don't-validate:** `RecordingConfiguration` имеет приватный init и конструируется ТОЛЬКО `Validator`'ом (`capability-and-settings`) — «гарантированно выполнимый» обеспечен системой типов.
- **State machine:** `idle → configuring → ready → recording → finalizing → done/error`; отказ writer'а/источника → `isolateAndContinue` (частичная финализация упавшего выхода, остальные продолжают).
- **Расширение через швы, не через правку ядра** (open/closed): новый источник = реализация `CaptureSource`; новый кодек/контейнер = `EncodingWriter` + codec-registry; новый режим = вариант `CaptureScope` enum. Координатор не правится.

## Критичные NFR (блокеры PR — проверяются `/finalize` и `/acceptance`)

- **NFR-STACK:** только нативные Apple-фреймворки. **Сторонние runtime-зависимости запрещены без plan-stage согласования** (dev-only тест-инфра вроде swift-snapshot-testing — допустима). Враппер-слои поверх системных API «на всякий случай» запрещены.
- **NFR-HW:** видео всегда через аппаратный VideoToolbox-энкодер (`IsHardwareAccelerated`); software-fallback по-тихому запрещён — недоступность HW это явное состояние (capability/деградация). На многодвижковых чипах экран и камера — **две независимые `VTCompressionSession`** (раскладка по движкам). MJPEG камеры декодируется аппаратно. Zero-copy через `IOSurface`/`CVPixelBuffer`-пулы.
- **NFR-TEST:** пирамида L1→L5; каждая фича декларирует уровни. Unit без железа обязателен для: `Validator`, `SampleRouter` (fan-out + `isAlive`), atomic start (drop PTS<T), gap-fill до fan-out, `CMSyncConvertTime`, `DegradationLadder` (чистый decider-автомат). DI через composition root, без скрытых синглтонов на hot path. Каждый публичный символ покрыт тестом или помечен trivial-no-test; критические пути — 100% unit.
- **NFR-SEC:** local-only — никакой сети/телеметрии/аналитики; записи не покидают устройство.
- **NFR-I18N:** все user-facing строки в String Catalog (`.xcstrings`), хардкод UI-текста запрещён (готовность к локализации, сами переводы вне MVP).
- **NFR-ERR:** no silent failures — дропы вскрываются, отказы уведомляются; `AVAssetWriter` с `movieFragmentInterval` для crash-safety файлов.

## Конвенции

- **Логирование:** единая система логгера, `print` запрещён. Стандартные события: `recording.start/stop`, `frame.dropped`, `source.failure`, `writer.failure`, `degradation.step`, `capability.probe`, `permission`.
- **Верификация API против SDK macOS 26:** точные сигнатуры SCK/AVFoundation/`synchronizationClock` подтверждать против финального SDK на этапе реализации; при расхождении — следовать SDK, но host-clock-стратегия и «микрофон вне сессии камеры» неизменны.
