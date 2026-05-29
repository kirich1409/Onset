---
type: test-plan
slug: audio-capture
parent: docs/spec/overview.md
source_spec: docs/audio-capture/spec.md
date: 2026-05-29
status: draft
---

# Test Plan: Audio Capture

Команды верификации и log-маппинг — `docs/spec/testing.md`; TC-id стабильны across feature-планов. Срез по фиче.

## Test Cases (owned)

#### TC-9 — Микрофон fan-out в оба файла идентичными буферами
| | |
|---|---|
| Priority | P0 | Type | unit | Tier | Feature |
| Preconditions | Fake EncodingWriter ×2 + источник микрофона |
| Steps | Прогнать mic-буферы через SampleRouter |
| Expected Result | Оба writer'а получили идентичные mic-буферы; видеобуферы — только в свой writer |
| Source | Spec §AC-9 |

#### TC-10 — Один видеоисточник → микрофон в его единственный файл
| | |
|---|---|
| Priority | P1 | Type | unit | Tier | Feature |
| Preconditions | Один fake writer + микрофон |
| Expected Result | Mic в единственный присутствующий writer |
| Source | Spec §AC-9 |

#### TC-13 — gap-fill тишиной ДО fan-out (идентичность сохранена)
| | |
|---|---|
| Priority | P0 | Type | unit | Tier | Feature |
| Preconditions | Аудиопоток с разрывом PTS, два fake writer'а |
| Expected Result | Тишина вставлена один раз до fan-out; оба writer'а получают идентичный поток |
| Source | Spec §AC-13 |

#### TC-14 — CMSyncConvertTime: PTS микрофона к host clock
| | |
|---|---|
| Priority | P1 | Type | unit | Tier | Feature |
| Preconditions | Mic-буферы на смещённых аудио-часах |
| Expected Result | PTS приведены к host; монотонность сохранена |
| Source | Spec §AC-9 |

#### TC-33 — Единый sample rate 48 кГц, аудио не короче видео
| | |
|---|---|
| Priority | P1 | Type | integration | Tier | Acceptance (L5) |
| Preconditions | Запись с микрофоном ≥5 мин |
| Expected Result | Аудио 48 кГц; длительность аудио ≈ видео; разрывы заполнены тишиной |
| Source | Spec §AC-13 |

## Shared / cross-feature TC
- **TC-29** (аудио-путь лосслесс под backpressure) — `performance-and-degradation`.
- **TC-31** (sync: bit-identity mic-дорожек, SHA-256) — `recording-session`.

## Coverage Matrix
| AC | TC |
|---|---|
| AC-9 | TC-9, TC-10, TC-14 (+ TC-29, TC-31 shared) |
| AC-13 | TC-13, TC-33 |
