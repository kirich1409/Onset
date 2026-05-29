---
type: spec
slug: camera-capture
product: Onset
parent: docs/spec/overview.md
date: 2026-05-29
status: approved
platform: [desktop]
acceptance_criteria_ids: [AC-3, AC-4]
depends_on: [capability-and-settings, recording-session, permissions]
provides_to: [recording-session, capability-and-settings]
---

# Feature: Camera Capture

Захват внешней камеры через AVFoundation, перечисление реально поддерживаемых форматов, живое превью. Общая основа — [`docs/spec/architecture.md`](../spec/architecture.md).

## Context
Источник видео камеры (референс — Logitech MX Brio: 4K@30 / 1080p@60 / 720p@90, на 4K — MJPEG). Отдаёт `CMSampleBuffer` в `recording-session`. Превью используется в settings UI (`capability-and-settings`).

## Acceptance Criteria
- [ ] **AC-3** — Для выбранной камеры пикеры разрешения и FPS показывают **только** комбинации из `device.formats` (`CMVideoFormatDescriptionGetDimensions` + `videoSupportedFrameRateRanges`). Baseline MX Brio: {4K@30, 1080p@60, 720p@90}; 4K@60 отсутствует. Инвариант: ни одной комбинации сверх `device.formats`.
- [ ] **AC-4** — Окно настроек показывает живое превью выбранной камеры (`AVCaptureVideoPreviewLayer`); при смене камеры превью переключается; при «Без камеры» область скрыта/плейсхолдер.

## Affected Modules
| Module | Change | Notes |
|---|---|---|
| `Infrastructure/Capture/CameraCaptureSource.swift` | New | `AVCaptureSession` (видео, **без аудиовхода**), `AVCaptureVideoDataOutput`, выбор `activeFormat`, MJPEG→decode при 4K; реализует `CaptureSource` |
| `Presentation/CameraPreviewView.swift` | New | `NSViewRepresentable` вокруг `AVCaptureVideoPreviewLayer` |

## Technical Approach
Перечисление форматов: `device.formats` → {resolution, fpsRanges, codec}. Сессия конфигурируется **сразу в целевом `activeFormat`** (без реконфигурации при Record — только добавляется `AVCaptureVideoDataOutput`). На 4K MX Brio отдаёт MJPEG → AVFoundation декодирует → кадры энкодятся в recording-session. **Без аудиовхода** в сессии (иначе ломается host-синхронизация — см. architecture § синхронизация). Callback на `com.app.capture.camera`.

## Dependencies / связи с другими фичами
| Направление | Фича | Характер связи |
|---|---|---|
| depends-on | `capability-and-settings` | выбор устройства/формата/fps из resolved конфига |
| depends-on | `permissions` | Camera (TCC) |
| depends-on | `recording-session` | эмитит буферы в `SampleSink`; старт/T от координатора |
| provides-to | `capability-and-settings` | список форматов (для пикеров) + превью-слой для settings UI |
| provides-to | `recording-session` | видеопоток камеры |
| provides-to | `performance-and-degradation` | MJPEG-decode нагрузка; цель деградации (fps камеры — первый шаг ladder) |

## Decisions
| Decision | Choice | Rationale |
|---|---|---|
| Микрофон | Вне сессии камеры | Сохранить host-clock синхронизацию |
| Preview-сессия | В целевом формате записи | Без glitch-реконфигурации при Record |

## Out of Scope
- Несколько камер одновременно; Continuity Camera-специфика сверх стандартного UVC — вне v1.
- 4K@60 для MX Brio (камера не отдаёт).
