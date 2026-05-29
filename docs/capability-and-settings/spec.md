---
type: spec
slug: capability-and-settings
product: Onset
parent: docs/spec/overview.md
date: 2026-05-29
status: approved
platform: [desktop]
acceptance_criteria_ids: [AC-1, AC-2, AC-5, AC-6, AC-15, AC-16]
depends_on: [permissions, screen-capture, camera-capture, audio-capture, performance-and-degradation]
provides_to: [recording-session, recording-control-ui]
---

# Feature: Capability & Settings

Детекция возможностей железа, окно настроек, выбор устройств/кодека/пути, валидация конфигурации (parse-don't-validate), персистентность. Общая основа — [`docs/spec/architecture.md`](../spec/architecture.md) (§ Capability-модель, § Кодек-политика).

## Context
Единственный конструктор `RecordingConfiguration` (через `Validator`). UI показывает только поддерживаемое железом и дизейблит невозможное с причиной. Запоминает последние настройки. Снабжает `recording-session` готовым валидным конфигом.

## Acceptance Criteria
- [ ] **AC-1** — При запуске открывается окно настроек: выбор камеры (+«Без камеры»), микрофона (+«Без звука»), вкл/выкл экрана и какой дисплей записывать.
- [ ] **AC-2** — Списки заполняются реально обнаруженными устройствами (камеры `AVCaptureDevice.DiscoverySession` `.external`/`.builtInWideAngleCamera`/`.continuityCamera`, микрофоны audio-discovery, дисплеи `SCShareableContent.displays`); hotplug во время настроек обновляет списки.
- [ ] **AC-5** — Выбор папки + кодек (HEVC default / H.264) + контейнер (MOV default / MP4). Недоступные на железе комбинации (VideoToolbox-probe) задизейблены с поясняющей причиной, не скрыты.
- [ ] **AC-6** — Record активна только при валидной конфигурации (≥1 видеоисточник: экран или камера); при нуле — неактивна с подсказкой.
- [ ] **AC-15** — Перед записью — capability-валидация: невозможный выбор авто-корректируется (с уведомлением) либо отклоняется до старта. *(Рантайм-исполнение `DegradationLadder` — в `performance-and-degradation`.)*
- [ ] **AC-16** — Кодек по умолчанию — аппаратный HEVC (`VTCopyVideoEncoderList`/`VTCopySupportedPropertyDictionaryForEncoder`); software по умолчанию не используется; форс SW-only → предупреждение.

## Affected Modules
| Module | Change | Notes |
|---|---|---|
| `Domain/Capability.swift` | New | `CapabilitySnapshot`, `Display/Camera/Encoder/Audio/SystemCapability`, `ChipTier`, `CaptureScope` |
| `Domain/RecordingConfiguration.swift` | New | parse-don't-validate (приватный init) |
| `Infrastructure/Capability/CapabilityService.swift` | New | actor: VT-probe + sysctl + discovery; версионированный snapshot; hotplug-инвалидация |
| `Infrastructure/Capability/CapabilityMatrix.swift` | New | data-таблица tier→бюджет (multi-stream) |
| `Infrastructure/Capability/Validator.swift` | New | чистая функция `(Caps, Selections) → Result<RecordingConfiguration, [ValidationIssue]>` |
| `Application/SettingsStore.swift` | New | мутабельный черновик Selections + UserDefaults персистентность |
| `Presentation/SettingsView.swift` | New | SwiftUI окно настроек: пикеры, путь, кодек |
| `Presentation/RecordingViewModel.swift` | New | `@MainActor` мост UI ↔ Coordinator/Capability/Settings |

## Technical Approach
`CapabilityService` собирает snapshot на launch (probe кэшируется); hotplug/thermal → bump generation. `Validator` (чистая функция) резолвит черновик `Selections` против snapshot на каждое изменение → конкретный `RecordingConfiguration` или `[ValidationIssue]`. UI: пикеры строятся из capability (fps камеры — из её форматов), невозможное дизейблится с причиной. Кодек-политика — см. architecture § Кодек-политика. Персистентность — UserDefaults. Priority probe↔matrix и MJPEG-decode бюджет — см. architecture § Capability-модель.

## Dependencies / связи с другими фичами
| Направление | Фича | Характер связи |
|---|---|---|
| depends-on | `permissions` | доступ к устройствам для enumeration; статусы в UI |
| depends-on | `screen-capture`/`camera-capture`/`audio-capture` | capability каждого источника (форматы/дисплеи) |
| depends-on | `performance-and-degradation` | encoder-probe / `CapabilityMatrix` бюджет |
| provides-to | `recording-session` | **выдаёт `RecordingConfiguration`** (вход машины состояний) |
| provides-to | `recording-control-ui` | состояние валидности (активность Record) |
| provides-to | `camera-capture` | settings UI встраивает превью (`CameraPreviewView`) |

## Decisions
| Decision | Choice | Rationale |
|---|---|---|
| Конфигурация | parse-don't-validate | «Выполнимый» гарантируется типами |
| Персистентность | UserDefaults (устройства/путь/кодек) | Удобство повторных записей |
| Probe vs matrix | probe — single-stream truth; matrix — multi-stream count | Нет публичного API на число сессий |

## Out of Scope
- Пресеты сверх дефолтов выбора — минимально в v1 (можно `.maxQuality/.balanced/.smallFile`).
- ProRes-опции в пикере кодека — исключены.
