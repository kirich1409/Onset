---
type: spec
slug: audio-capture
product: Onset
parent: docs/spec/overview.md
date: 2026-05-29
status: approved
platform: [desktop]
acceptance_criteria_ids: [AC-9, AC-13]
depends_on: [capability-and-settings, recording-session, permissions]
provides_to: [recording-session]
---

# Feature: Audio Capture (микрофон)

Захват выбранного микрофона как **независимого источника** (вне сессии камеры), запись дорожкой в оба видеофайла идентичными буферами, gap-fill тишиной. Общая основа — [`docs/spec/architecture.md`](../spec/architecture.md).

## Context
Один источник микрофона; его буферы веером (fan-out) попадают во все присутствующие видеофайлы для синхронизации по аудиоволне. Фиксированный sample rate 48 кГц. PTS приводятся к host-clock.

## Acceptance Criteria
- [ ] **AC-9** — Микрофон (если выбран) пишется отдельной аудиодорожкой в **каждый** присутствующий видеофайл идентичными сэмпл-буферами (fan-out): экран+камера → оба файла; один видеоисточник → его файл. PTS микрофона приводятся к host clock через `CMSyncConvertTime` перед append.
- [ ] **AC-13** — Аудио всех источников фиксируется на едином sample rate 48 кГц; обнаруженный разрыв PTS заполняется тишиной перед append (защита от Core Audio gaps), чтобы аудио не укорачивалось относительно видео.

## Affected Modules
| Module | Change | Notes |
|---|---|---|
| `Infrastructure/Capture/AudioCaptureSource.swift` | New | Независимый аудио-источник (микрофон), вне сессии камеры; 48 кГц; gap-detection; реализует `CaptureSource` |

> Fan-out выполняет `SampleRouter` (владелец — `recording-session`); gap-fill и приведение PTS делаются **до** fan-out, здесь.

## Technical Approach
Независимая аудио-only `AVCaptureSession`/`AVCaptureAudioDataOutput` (или AVFAudio). Sample rate жёстко 48 кГц во всех источниках. Перед передачей в `SampleRouter`: (1) детекция разрыва PTS → вставка тишины (AC-13); (2) `CMSyncConvertTime` host-приведение (AC-9). Оба шага — **до** fan-out, чтобы оба файла получили идентичный поток (bit-identity, см. architecture § backpressure: аудио-путь лосслесс). Callback на `com.app.capture.audio`.

## Dependencies / связи с другими фичами
| Направление | Фича | Характер связи |
|---|---|---|
| depends-on | `capability-and-settings` | выбор микрофона |
| depends-on | `permissions` | Microphone (TCC) |
| depends-on | `recording-session` | передаёт буферы в `SampleRouter` (fan-out там); host-clock от координатора |
| provides-to | `recording-session` | аудиопоток для всех видеофайлов (bit-identity → синк AC-12) |

## Decisions
| Decision | Choice | Rationale |
|---|---|---|
| Источник микрофона | Независимый, вне сессии камеры | Не слейвить master clock к аудио-железу |
| Gap-fill / host-приведение | До fan-out | Идентичность дорожек в обоих файлах (AC-9/AC-12) |
| Sample rate | 48 кГц фиксированно | Защита от A/V-дрейфа |

## Out of Scope
- Системный/прил­оженческий звук — Phase 2.
- Несколько микрофонов одновременно — вне v1.
