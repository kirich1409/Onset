---
type: spec-overview
product: Onset
date: 2026-05-29
status: approved
platform: [desktop]
supersedes: docs/specs/2026-05-29-macos-screen-camera-recorder.md
---

# Onset — Overview (общая часть)

**Onset** — нативное macOS-приложение (Swift, Apple Silicon, macOS 26+) для одновременной записи экрана, внешней камеры и микрофона в **раздельные синхронизируемые файлы** для последующего монтажа. Название нейтрально к функциям (от «on set»), масштабируется на будущие режимы (композиция/наложение).

Это корневой документ. Общая техническая основа — [`architecture.md`](architecture.md). **Кросс-каттинг нефункциональные требования (обязательны для всех фич)** — [`non-functional-requirements.md`](non-functional-requirements.md): производительность, автоматизированное тестирование/покрытие, нативный стек, расширяемость архитектуры, error-handling/crash-safety, CI/CD, security/privacy, a11y/локализация. Документация по фичам — в `docs/<feature>/` (spec.md + test-plan.md). Спеки консолидируют результаты предварительного исследования (рабочий артефакт, в репозитории не хранится).

> NFR — не «по возможности», а контракт: каждая фича и каждый PR проверяются против релевантных NFR; нарушение критичных (PERF/TEST/STACK/EXT) — блокер.

## Scope (MVP v1)

- Запись **всего дисплея** (область/окно — Phase 2), внешней камеры, микрофона в раздельные файлы.
- Кодеки HEVC HW (default) / H.264 HW; контейнер MOV (default, timecode-трек) / MP4.
- Синхронизация: общий host-clock + микрофон дорожкой в оба файла (bit-identity) + timecode (MOV, best-effort).
- Capability-детекция возможностей железа + адаптивная деградация.
- UX: окно настроек (+превью камеры) → Record → menu bar (Stop/hotkey/Dock) → готовые файлы.

## Референс-железо (acceptance)

- **MacBook Pro 14" M3 Max** (2 HW encode engine) + **внешний дисплей 4K60 SDR** + **Logitech MX Brio** (4K@30 / 1080p@60).
- Потолок планирования — 4K60; 5K поддерживается вторым приоритетом через capability-детекцию + деградацию.

## Карта фич и зоны ответственности

| Фича (`docs/<feature>/`) | Зона | AC |
|---|---|---|
| `screen-capture` | Захват экрана (ScreenCaptureKit, весь дисплей, SDR) | AC-10 |
| `camera-capture` | Камера (AVFoundation, форматы, превью, MJPEG→decode) | AC-3, AC-4 |
| `audio-capture` | Микрофон (fan-out в оба файла, gap-fill, 48 кГц, bit-identity) | AC-9, AC-13 |
| `capability-and-settings` | Детекция возможностей, Validator, настройки/UI, выбор кодека, персистентность | AC-1, AC-2, AC-5, AC-6, AC-15, AC-16 |
| `recording-session` | Координатор/state machine, атомарный старт/стоп, синхронизация-гарантия, вывод файлов, isolate отказов | AC-7, AC-11, AC-12, AC-17, AC-20 |
| `recording-control-ui` | Menu bar, hotkey, Dock, способы остановки, окно во время записи | AC-8, AC-19 |
| `performance-and-degradation` | No-drops SLA, учёт дропов, RuntimeHealthMonitor, DegradationLadder, память | AC-14, AC-21 |
| `permissions` | TCC: Screen Recording / Camera / Microphone / Notifications | AC-18 |

> AC-15 (capability-валидация + деградация): валидация до старта — в `capability-and-settings`; исполнение `DegradationLadder` в рантайме — в `performance-and-degradation`.

## Граф связей между фичами

```
permissions ──► (все capture-фичи, capability-and-settings, recording-control-ui[notifications])

capability-and-settings ──► выдаёт RecordingConfiguration ──► recording-session
   ▲ берёт capability от: screen-capture, camera-capture, audio-capture, performance(encoder probe)

screen-capture ─┐
camera-capture ─┼─ CMSampleBuffer ─► recording-session (SampleRouter → AVAssetWriterPipeline)
audio-capture ──┘   (audio fan-out в оба writer'а)

recording-session ◄──► performance-and-degradation (DroppedFrameStats/health → DegradationLadder)
recording-session ◄──► recording-control-ui (start/stop, состояние, счётчик дропов)

camera-capture ──► (превью) ──► capability-and-settings (settings UI)
```

Точная таблица зависимостей — в блоке `## Dependencies` каждого feature-spec.

## Общие решения (Decisions, действуют на все фичи)

| Decision | Choice | Rationale |
|---|---|---|
| Стек | Только нативный Apple (ScreenCaptureKit/AVFoundation/AVAssetWriter/VideoToolbox/Core Media/AppKit/SwiftUI) | Эффективность, без сторонних зависимостей |
| Платформа | Swift, macOS 26.0, Apple Silicon | Все API доступны на 26+ |
| Кодек/контейнер default | HEVC HW + MOV | Размер/качество; MOV — единственный с timecode-треком |
| ProRes / HDR | Исключены | Не нужны монтажные форматы; референс SDR |
| Output | `Recording <timestamp>/` с `screen.*`/`camera.*` | Файлы записи держатся вместе |
| ≥1 видеоисточник | Обязателен; микрофон опционален | Запись без видео бессмысленна; mic fan-out во все видеофайлы |
| Activation policy | `.regular` (Dock-иконка) | Нужна для способа остановки через Dock |

## Out of Scope (общий, MVP v1)

- Захват области/окна; системный звук — Phase 2.
- ProRes, HDR/10-bit, real-time композиция/PiP, pause/resume, countdown, аннотации, редактор, мультикамера/мультидисплей, шеринг — вне v1/продукта.
- Entitlement `com.apple.developer.persistent-content-capture` — вне v1.

## Future Phases

- **Phase 2:** область (`sourceRect`) + окно (`desktopIndependentWindow`) + системный звук (`SCStream.capturesAudio`).
- **Phase 3 (кандидаты):** HDR/10-bit, ProRes archival, мультидисплей/мультикамера, hotkeys/countdown, real-time композиция.
