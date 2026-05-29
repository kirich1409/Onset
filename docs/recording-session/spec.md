---
type: spec
slug: recording-session
product: Onset
parent: docs/spec/overview.md
date: 2026-05-29
status: approved
platform: [desktop]
acceptance_criteria_ids: [AC-7, AC-11, AC-12, AC-17, AC-20]
depends_on: [capability-and-settings, screen-capture, camera-capture, audio-capture, performance-and-degradation, recording-control-ui]
provides_to: [recording-control-ui, performance-and-degradation]
---

# Feature: Recording Session

Ядро записи: координатор/state machine, атомарный старт/стоп N writer'ов, синхронизация-гарантия, маршрутизация (SampleRouter), вывод файлов, isolate отказов writer'а/источника. Общая основа — [`docs/spec/architecture.md`](../spec/architecture.md) (§ Атомарный старт/стоп, § Машина состояний, § Синхронизация, § SampleRouter).

## Context
Принимает `RecordingConfiguration` от `capability-and-settings`, оркестрирует источники и `AVAssetWriterPipeline` по файлу на видеоисточник, гарантирует общий host-clock и атомарность старта/стопа. Владеет `ClockProviding`, `SampleRouter` (fan-out микрофона), `OutputLayout`.

## Acceptance Criteria
- [ ] **AC-7** — По Record все источники стартуют от единой точки T: первый кадр каждого файла соответствует одному моменту реального времени; окно сворачивается, состояние → «идёт запись». (Механизм warm-up→T — architecture.)
- [ ] **AC-11** — По окончании создаётся `Recording YYYY-MM-DD HH.mm.ss/` с `screen.*` и/или `camera.*` (по контейнеру); после Stop папка открывается в Finder.
- [ ] **AC-12** — Оба файла с общей нулевой точкой T на одной host-шкале. Объективная проверка: при наличии микрофона его дорожки в обоих файлах бит-в-бит идентичны (SHA-256). Practical: выравнивание в NLE ≤1 кадр. Timecode-трек (MOV, best-effort) — бонус. Без микрофона — совпадение старт-PTS ≤1 кадрового интервала.
- [ ] **AC-17** — Отказ **writer'а** mid-recording → его выход финализируется как частичный, остальные продолжают; уведомление; запись не теряется целиком.
- [ ] **AC-20** — Отказ **источника** mid-recording (unplug камеры; отзыв Camera permission) → источник финализируется как частичный, остальные продолжают (симметрично AC-17); при падении последнего видеоисточника → `error` с сохранением файлов. (Screen-recording revocation — на релончe; см. architecture § верификация SDK.)

## Affected Modules
| Module | Change | Notes |
|---|---|---|
| `Domain/CaptureSource.swift` | New | протоколы `CaptureSource`/`SampleSink`/`EncodingWriter`/`ClockProviding`, `SourceKind`, `RecordingState` |
| `Application/RecordingSessionCoordinator.swift` | New | actor: машина состояний, атомарный старт/стоп, isolate отказов |
| `Infrastructure/Sync/HostClockService.swift` | New | `ClockProviding`: host clock + `CMSyncConvertTime` |
| `Infrastructure/Sync/SampleRouter.swift` | New | `SampleSink`: fan-out микрофона; читает atomic `isAlive` writer'ов |
| `Infrastructure/Writer/AVAssetWriterPipeline.swift` | New | `AVAssetWriter` (video+audio+timecode), HEVC/H.264 outputSettings, timecode-трек (MOV) |
| `Application/OutputLayout.swift` | New | session-папка, имена файлов, reveal в Finder (AC-11) |

## Technical Approach
Машина `idle→configuring→ready→recording→finalizing→done/error`. Атомарный старт warm-up→T и стоп — см. architecture. `SampleRouter` раздаёт видео в свой writer, микрофон — fan-out во все (буферы уже host-приведены и gap-filled в `audio-capture`). Синхронизация по host-clock + timecode (MOV). Отказы: writer (AC-17) и source (AC-20) — `isolateAndContinue` через per-writer `WriterHealth`/`isAlive` и source-failure ветку. `OutputLayout` создаёт папку и открывает Finder.

## Dependencies / связи с другими фичами
| Направление | Фича | Характер связи |
|---|---|---|
| depends-on | `capability-and-settings` | принимает `RecordingConfiguration` (вход) |
| depends-on | `screen/camera/audio-capture` | источники `CMSampleBuffer` |
| depends-on | `recording-control-ui` | триггеры start/stop |
| depends-on | `performance-and-degradation` | сигнал деградации (применяет шаги ladder); читает `DroppedFrameStats` |
| provides-to | `recording-control-ui` | состояние записи, прошедшее время |
| provides-to | `performance-and-degradation` | writers/sources как цели деградации; health-сигналы |

## Decisions
| Decision | Choice | Rationale |
|---|---|---|
| Старт | warm-up→T, drop PTS<T | Без «дыры» в начале файлов |
| Отказ writer'а/источника | isolateAndContinue | Не терять параллельные потоки |
| Контейнер для timecode | MOV | MP4 не поддерживает timecode-трек |

## Out of Scope
- Real-time композиция/PiP; pause/resume — вне v1.
