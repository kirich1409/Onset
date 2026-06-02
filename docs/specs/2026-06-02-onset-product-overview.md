---
type: spec
slug: onset-product-overview
date: 2026-06-02
status: approved
platform: [desktop]
surfaces: [ui]
risk_areas: [pii, perf-critical]
non_functional:
  sla: "запись не теряет файл при краше; HW-энкодер обязателен; dropped frames наблюдаемы"
  a11y:
acceptance_criteria_ids: [AC-1, AC-2, AC-3, AC-4, AC-5, AC-6, AC-7, AC-8]
design:
  figma:
  design_system: docs/design-ref/
---

# Spec: Onset — Product Overview

Date: 2026-06-02
Status: approved
Slug: onset-product-overview

---

## Context and Motivation

Onset — нативная macOS-утилита для одновременной записи экрана и веб-камеры в **два отдельных видеофайла** на диск, со звуком. Цель файлов — последующий монтаж в стандартных NLE (Premiere Pro, DaVinci Resolve, Final Cut Pro), в т.ч. на Windows. Ниша: создатели контента, авторы туториалов и докладов, которым нужны раздельные дорожки экрана и камеры (в отличие от composite-first инструментов вроде Loom/ScreenFlow). Onset делает ставку на встроенные возможности macOS и аппаратное ускорение Apple Silicon, чтобы дать максимум качества «из коробки» при zero-config UX: запустил → выдал разрешения → нажал запись → получил готовые к монтажу файлы.

Этот документ — **верхнеуровневая спецификация продукта**: vision, границы MVP, roadmap, кросс-режущие архитектурные принципы и карта фич. Детали реализуются в feature-спеках:
- [`onset-permissions-onboarding`](2026-06-02-onset-permissions-onboarding.md) — выдача TCC-разрешений.
- [`onset-recording-mvp`](2026-06-02-onset-recording-mvp.md) — ядро записи (источники, захват, кодирование, вывод, UI записи).
- [`onset-devops-ci`](2026-06-02-onset-devops-ci.md) — инфраструктура вокруг кода: двухскоростной CI (быстрый PR-гейт + async-слой) на GitHub-hosted, auto-merge, L5 локально (вне CI), security-проверки. Прямой ответ на требование fast feedback для agent-driven модели.

Фундамент исследования: `swarm-report/research/research-mac-dual-recorder.md` (v2.1).

## Acceptance Criteria

Продуктовые критерии MVP (детальные AC — в feature-спеках):

- [ ] **AC-1** — Чистая установка → первый запуск: пользователь проходит онбординг разрешений и доходит до экрана записи без чтения документации.
- [ ] **AC-2** — На главном экране пользователь выбирает источник экрана, камеру и микрофон, нажимает «Записать» — и получает **два отдельных файла** (экран и камера), каждый со звуком выбранного микрофона.
- [ ] **AC-3** — Оба файла открываются в Premiere Pro, DaVinci Resolve и Final Cut Pro (Mac и Windows) и **выравниваются на общем таймлайне**: видео-PTS обоих потоков укоренены в одной host-time эпохе старта сессии, а идентичная звуковая дорожка микрофона обеспечивает audio-waveform авто-sync. Проверка: открыть оба клипа в NLE, выровнять по звуку → действие на экране и реакция на камере совпадают. (Покадровое совпадение не гарантируется и не требуется — fps потоков различаются.)
- [ ] **AC-4** — Запись использует аппаратный HEVC-энкодер Apple Silicon; если HW-энкодер недоступен, запись не стартует молча в software, а сообщает об этом.
- [ ] **AC-5** — Файлы пишутся в CFR (constant frame rate); VFR не допускается (ломает NLE).
- [ ] **AC-6** — Запись устойчива к крашу: при аварийном завершении уже записанная часть обоих файлов остаётся валидной и проигрываемой (теряется не более одного `movieFragmentInterval`-окна хвоста).
- [ ] **AC-7** — Пропущенные кадры (dropped frames) во время записи наблюдаемы пользователю; при деградации показывается состояние Degraded.
- [ ] **AC-8** — Приложение не инициирует исходящих сетевых соединений во время онбординга и записи (UI-обещание «Данные никуда не отправляются» истинно). Проверка: отсутствие network-egress (`nettop`/Little Snitch на чистой сессии) и отсутствие сетевого клиента в сборке.

**Authoritative definition of done.** Реализующий агент валидирует против feature-спеков; этот список — продуктовый каркас, не подменяет AC feature-спеков.

## Prerequisites

| Prerequisite | Status | Owner | Notes |
|--------------|--------|-------|-------|
| Xcode-проект Onset (SwiftUI), target macOS 26.5, Apple Silicon | ✅ Done | — | Уже инициализирован (boilerplate SwiftUI + SwiftData) |
| `.gitignore` (исключить `.DS_Store`, `xcuserdata`, `swarm-report/`) | ⬜ Todo | Agent | Свежий репо без .gitignore — мусор уже в дереве |
| Info.plist usage descriptions: `NSCameraUsageDescription`, `NSMicrophoneUsageDescription` | ⬜ Todo | Agent | Screen Recording управляется TCC без отдельного usage-string |
| Подпись: **Developer ID + Hardened Runtime + notarization, без App Sandbox** (MVP) | ⬜ Todo | Human/Agent | Решено (см. Decisions). Exit-criterion: приложение подписано, нотаризовано, проходит TCC-флоу и пишет в `~/Movies/Onset` на чистой машине. MAS/sandbox-совместимость — post-MVP |
| Hardened Runtime entitlements: camera, microphone (screen capture — через TCC, без отдельного entitlement) | ⬜ Todo | Agent | Без App Sandbox прямой доступ к `~/Movies`; без `com.apple.security.network.client` (гарантия AC-8) |
| SwiftLint + SwiftFormat (SPM build-tool plugins) | ⬜ Todo | Agent | Одобрены как dev-зависимости; настроить конфиги + интеграцию в L1-гейт/CI |
| Swift 6 + strict concurrency в project.pbxproj (SWIFT_VERSION 5.0 → 6) | ⬜ Todo | Agent | Текущий шаблон на 5.0 |
| **`ENABLE_APP_SANDBOX = YES` → `NO`** в project.pbxproj | ⬜ Todo (CONFLICT) | Agent | Текущий шаблон со sandbox **противоречит** решению «Developer ID без App Sandbox»; ломает прямой доступ к `~/Movies` и AVCaptureSession |
| **Shared Xcode scheme** `Onset.xcodeproj/xcshareddata/xcschemes/Onset.xcscheme` | ⬜ Todo (BLOCKER) | Agent | Сейчас только user-local scheme → `xcodebuild` падает на CI; деталь в [`onset-devops-ci`](2026-06-02-onset-devops-ci.md) |
| Apple Developer аккаунт + notarization credentials | ⬜ Todo | Human | Единственное, что агент физически не может (принцип 15г); код/конфиги подписи — агент |
| Доступ к тестовым машинам M1 Air + M3 Max для L5 | ⬜ Todo | Human | Физический/удалённый доступ; саму приёмку исполняет агент |

## Affected Modules and Files

Greenfield — текущий код это SwiftUI+SwiftData boilerplate (`OnsetApp.swift`, `ContentView.swift`, `Item.swift`), он будет заменён. Предлагаемая верхнеуровневая модульная структура (слои):

| Модуль / слой | Change type | Notes |
|---------------|-------------|-------|
| `OnsetApp` (composition root) | Modified | menu bar `MenuBarExtra` + окна; DI/wiring |
| `Permissions/` | New | TCC: Screen Recording, Camera, Microphone — запрос, polling-детект, состояния |
| `Capture/` | New | Capture-слой: `ScreenSource` (SCStream), `CameraSource` (AVCaptureSession), `MicrophoneSource`; экспонирует per-frame событие + latest-frame holder |
| `Encode/` | New | `VideoEncoder` (VTCompressionSession), `FileWriter` (AVAssetWriter); pluggable codec/container |
| `Recording/` | New | `RecordingSession` (оркестрация двух пайплайнов), `OutputStage` (DualFile сейчас, Composite позже), общий host-time clock, sync |
| `Capability/` | New | `CapabilityProbe` (HW-энкодер, бюджет), dropped-frames мониторинг, Degraded-состояние |
| `Configuration/` | New | `RecordingConfiguration` (per-stream codec/container/fps/res/mic), реестр кодеков/контейнеров |
| `UI/` | New | Главный экран, окно записи, menu bar, онбординг разрешений (по макетам `docs/design-ref/`) |
| `Storage/` | New | Метаданные записей (возможно SwiftData — уже в шаблоне), пути/имена файлов |

Key integration points:
- Capture-слой отдаёт `CMSampleBuffer`/`CVPixelBuffer` + host-time → `OutputStage` потребляет.
- `RecordingConfiguration` — единый источник истины для параметров записи; базовый экран читает дефолт-профиль, будущее меню настроек редактирует тот же объект.

## Technical Approach

Архитектурные принципы (обязательны для всех feature-спеков), из research v2.1:

1. **Path B — два независимых low-level пайплайна.** Экран: `SCStream → SCStreamOutput → VTCompressionSession → AVAssetWriter`. Камера: `AVCaptureSession → AVCaptureVideoDataOutput → VTCompressionSession → AVAssetWriter`. **НЕ** `AVCaptureMultiCamSession` (на macOS не существует). **НЕ** `SCRecordingOutput` для основного пути (скрытый энкодер: нет per-frame/backpressure, нельзя дублировать микрофон в оба файла, нельзя нарастить composite).

2. **Capture-слой + сменная output stage.** Capture-слой для каждого источника экспонирует ДВА интерфейса: (a) per-frame событие (callback с `CVPixelBuffer` + host-time), (b) thread-safe latest-frame holder. `OutputStage` — протокол:
   - `DualFileOutputStage` (MVP) — **event-driven**: каждый источник → свой энкодер на своём CFR fps. Это и есть «разные fps камеры и экрана». «Ноль дублирования» — идеальный случай (источник в сетке); при джиттере камеры CFR обеспечивается hold/drop на промахах сетки (см. `onset-recording-mvp` §CFR), не инвариант.
   - `CompositeOutputStage` (post-MVP) — **clock-driven**: тик на target fps + latest-frame hold + Core Image (Metal) compositor → один энкодер. Добавляется без переписывания capture-слоя.

3. **Синхронизация двух файлов** — общий host-time корень (`CMClockGetHostTimeClock()`/`synchronizationClock`), `CMClock.convertTime(_:to:)` **per-sample** (не разовый offset — дрейф). Дополнительно: один микрофон пишется в оба файла → audio-waveform авто-sync в любом NLE (кросс-платформенно). Опционально позже: SMPTE timecode-track (только .mov).

4. **CFR обязателен** — NLE не держат VFR. Каждый поток пишется с фиксированным целевым fps и стабильным keyframe-интервалом.

5. **Pluggable codec/container + конфигурационный слой.** Output stage параметризуется профилем (`VideoCodec` + `Container` + rate-control); кодек и контейнер — данные, не ветки кода (VTCompressionSession codec type + AVAssetWriter file type). Реестр кодеков/контейнеров с проверкой доступности на чипе (`VTCopyVideoEncoderList`). `RecordingConfiguration` — единый источник истины. Закладывается с самого старта, даже если в MVP включён один кодек.

6. **Two-tier UX.** Базовый экран — read-only дефолт-профиль (zero-config). Меню настроек (post-MVP) — редактор того же `RecordingConfiguration`; наполняется постепенно добавлением полей/опций в реестр без переписывания pipeline.

7. **Дефолт кодека — HEVC Main 8-bit Rec.709 CFR, контейнер .mp4 (hvc1)**, VBR + peak-cap, B-кадры on, `RealTime=true`, `ProfileLevel = HEVC_Main_AutoLevel`, `movieFragmentInterval` (устойчивость к крашу). ProRes/H.264 — опции настроек post-MVP (+ ProRes как probe-fallback при нехватке encode-движка).

8. **CapabilityProbe** — на старте: тестовый `VTCompressionSession` с `RequireHardwareAcceleratedVideoEncoder` + read-back `UsingHardwareAcceleratedVideoEncoder`. Питает Degraded-состояние. Точные пороги/тиры деградации в MVP НЕ зашиваются (калибруются на железе post-MVP).

9. **Concurrency.** Каждый рекордер — изолированный actor (падение одного не роняет второй); `AVAssetWriterInput.append` не потокобезопасен → строгая сериализация на actor, гейт на `isReadyForMoreMediaData`. Callbacks на своих delegate-очередях не смешиваются.

10. **Направление зависимостей (контракт границ модулей).** Допустимые рёбра: `UI → Recording → {Capture, Encode, Capability} → Configuration`. `Configuration` — чистый слой данных, ни от кого не зависит. `Permissions` — отдельный слой; от него зависят `Recording` и `UI`-онбординг, но не наоборот. `Capture`/`Encode`/`Capability` НЕ зависят от `UI`. Обратных рёбер быть не должно — это контракт, против которого валидируется реализация и `/acceptance`.

11. **Rate-control — codec-specific под-конфигурация, не плоское поле.** `RecordingConfiguration` хранит rate-control как вариант под кодек: `RateControl.vbr(average, peak)` для HEVC/H.264; `RateControl.proResQuality(.lt/.proxy)` для ProRes (intra-only, без bitrate-target). Реестр кодеков остаётся данными, но конфиг не навязывает HEVC-семантику ProRes. В MVP включён только HEVC-вариант; ProRes-вариант — закладка формы (реализуется post-MVP).

12. **No network egress.** Приложение не содержит сетевого клиента, телеметрии, аналитики; без `com.apple.security.network.client`. Это гарантирует UI-обещание «Данные никуда не отправляются» (AC-8) на уровне сборки.

13. **a11y — базовый уровень (L1) с самого старта.** Состояния записи/деградации передаются НЕ только цветом (текст «ЗАПИСЬ»/«ДЕГРАДАЦИЯ» + иконка обязательны); таймер и счётчик пропущенных кадров — VoiceOver live-region; все интерактивы (карточки разрешений, селекторы, кнопки, menu-bar-элемент) имеют `accessibilityLabel` и логичный фокус-порядок; контраст текста ≥ 4.5:1 (≥ 3:1 для крупного).

14. **Sandbox-forward-compatibility (MVP без sandbox, post-MVP MAS).** Где sandbox-совместимый подход бесплатен — выбирать его уже в MVP: глобальный hotkey через `RegisterEventHotKey` (не требует Accessibility/Input Monitoring TCC, MAS-ready); доступ к файлам за абстракцией `Storage`-слоя (MVP — прямой `~/Movies`; post-MVP добавляется security-scoped bookmark/NSSavePanel без переписывания вызывающего кода).

15. **Agent-driven development — весь код и всё ревью выполняют агенты, человек код не пишет и не ревьюит.** Следствия, обязательные для всех спеков: (а) спеки — **единственный автономный контракт** реализации; не полагаться на tribal knowledge или человека-уточнителя в процессе (всё решающее зафиксировано в спеке/Decisions/AC). (б) Верификация максимально **машинно-проверяема**: L1/L2 полностью автоматизированы (build + SwiftLint/SwiftFormat + Swift Testing в CI). (в) L5 (медиа/железо) исполняет **агент** (`manual-tester` + mobile/desktop MCP-автоматизация) на реальных машинах, не человек; критерии L5 сформулированы как объективные проверки (`ffprobe` CFR, открытие в NLE, crash-injection), а не «выглядит хорошо». (г) Owner «Human» в Prerequisites — только для того, что агент физически не может: Apple Developer аккаунт, App Store Connect, физический доступ к тестовым машинам; всё остальное (код, конфиги, entitlements, CI) — агенты.

## Technical Constraints

- Только Apple Silicon, macOS 26.5+. Системные API: ScreenCaptureKit, AVFoundation, VideoToolbox, Core Media. Без сторонних медиа-библиотек.
- Логирование — `os.Logger` (Unified Logging), не `print`/`NSLog`.
- HW-энкодер обязателен; software-кодирование не использовать молча (детект через Require/Using).
- CFR обязателен; VFR запрещён.
- Файлы устойчивы к крашу (`movieFragmentInterval`).
- Не закладывать `AVCaptureMultiCamSession` (нет на macOS) и `SCRecordingOutput` как основной путь.
- Presenter Overlay не использовать как composite-механизм (нет API управления — включается только пользователем).
- Входной pixel-rate экрана не превышает бюджет, измеренный CapabilityProbe под фактический чип: 5K/6K дисплеи downscale до вписывания (дефолт ≤ 4K60).
- Глобальный hotkey только через `RegisterEventHotKey` — без Accessibility/Input Monitoring.
- Нет исходящего сетевого трафика (no telemetry/analytics; без `com.apple.security.network.client`).
- Приложение не подавляет и не имитирует системный индикатор записи экрана; запись всегда визуально индицирована.

## Технический стек (закреплено)

| Аспект | Выбор | Notes |
|---|---|---|
| Язык | **Swift 6, strict concurrency** | Проект concurrency-heavy (actor-пайплайны, не-thread-safe `AVAssetWriter`); compile-time проверка data races. project.pbxproj обновить SWIFT_VERSION 5.0 → 6 + strict |
| UI | SwiftUI + `MenuBarExtra` | AppKit-interop точечно: `NSWorkspace` (deep-link/relaunch), `AVCaptureVideoPreviewLayer` через `NSViewRepresentable`, `RegisterEventHotKey` |
| Архитектурный паттерн | MVVM | `@Observable` view-models; capture/encode/`DropMonitor` — изолированные `actor`'ы |
| DI | Composition root в `OnsetApp`, constructor injection | Без DI-библиотек |
| Тесты | Swift Testing | Нативно в Xcode 26; XCTest допустим для UI-тестов где Swift Testing не покрывает |
| Логирование | `os.Logger` (Unified Logging) | Не `print`/`NSLog` |
| Линт/формат | **SwiftLint + SwiftFormat** (SPM build-tool plugins) | Dev-зависимости (не runtime); часть L1-гейта |
| Медиа-фреймворки | ScreenCaptureKit, AVFoundation, VideoToolbox, Core Media, Core Image/Metal (post-MVP composite) | Без сторонних медиа-библиотек |
| Инструменты | Xcode 26+, target macOS 26.5, Apple Silicon | — |

### Compiler & language strictness (максимальный уровень — закреплено)

Цель: максимум machine-verifiable гарантий, чтобы компилятор/линтер ловили то, что иначе легло бы на ревью (критично для agent-driven модели — принцип 15).

- **Swift 6 language mode + strict concurrency = complete** (data-race safety на компиляции).
- **Warnings as errors** (`SWIFT_TREAT_WARNINGS_AS_ERRORS = YES`) — ни одного непрочитанного warning проходит L1.
- **Strict memory safety** (Swift 6.2 opt-in) — требует явной маркировки `unsafe`; обязательно для C-interop с VideoToolbox / Core Media (`withUnsafe…`, pointer-based API): каждое небезопасное место явно обосновано, а не растворено в коде.
- **Upcoming-feature флаги** (то, что ещё не дефолт в Swift 6): `ExistentialAny`, `InternalImportsByDefault`, `MemberImportVisibility` (+ прочие не-дефолтные на используемом toolchain).
- **Typed throws** — доменные ошибки типизированы (строгий error-контракт вместо нетипизированного `Error`) там, где набор ошибок известен.
- **SwiftLint strict mode + analyzer-правила** — линт как жёсткая часть L1.

Точные имена upcoming-feature флагов и доступность strict-memory-safety — **подтвердить по Swift 6.x toolchain Xcode 26 при настройке** (implementation-time); концепция и уровень зафиксированы.

## Качество и приёмка (технические требования)

Пирамида верификации (строго последовательно; уровень требует прохождения предыдущего):

- **L1 — статика (всегда):** build green под **максимальной строгостью** (Swift 6 strict concurrency + warnings-as-errors + strict memory safety + upcoming-флаги + typed throws компилируются без ошибок/warnings) + SwiftLint strict/SwiftFormat чисто + код-ревью агентом (`/finalize`).
- **L2 — unit (Swift Testing):** чистая логика без устройств — CFR-нормализация (snap/hold/drop), pre-flight бюджет-калькулятор, `RecordingConfiguration` и реестр кодеков, эвристика авто-формата камеры, формирование имён файлов, приведение PTS к host-time. Public-API coverage gate.
- **L3 — UI tests (опц.):** ключевые состояния онбординга / главного экрана.
- **L5 — приёмка на железе (MANDATORY — медиа/железо; исполняет агент `manual-tester` + MCP-автоматизация, не человек).** Стратегия по машинам: **в процессе разработки MVP приёмка идёт на MacBook Pro M3 Max (2 движка — dev-машина)**; **MacBook Air M1 (1 движок, пассив) — финальная обкатка готовой MVP-версии** (слабый край, для выявления правок под ограничения железа), не на каждой задаче. Критерии (на целевой машине):
  - оба файла создаются, валидны, проигрываются;
  - открываются в Premiere Pro / DaVinci Resolve / Final Cut Pro и выравниваются по звуку микрофона (cross-platform);
  - `ffprobe -show_frames` подтверждает CFR (равномерные PTS, hvc1-тег, ноль пропусков на сетке);
  - HW-энкодер задействован (не software-fallback);
  - crash-injection (`kill -9` во время записи) → потеря хвоста ≤ `movieFragmentInterval`, остальное проигрывается;
  - на M1 Air с внешним 4K/5K-монитором pre-flight cap не даёт безостановочного backpressure-брака.
- **Performance-test (post-MVP):** автоматизированная проверка encode-бюджета под чип (калибровка порогов деградации) — после обкатки.

**Definition of done (технический):** все AC трёх спеков verified + L1 green + L2 green + **L5 локальная приёмка на обоих чипах passed**. L5 нельзя заменить статикой/build — claim «работает» проверяется только на реальном железе.

### Блокирующие vs необязательные проверки (приоритет)

- **БЛОКИРУЮТ закрытие задачи (must-have, без них принять НЕЛЬЗЯ):** L1 (build + lint + warnings-as-errors) · L2 (unit) · **L5 — полная локальная приёмка на железе** (per-task — на **M3 Max**, dev-машина; ffprobe CFR, открытие в NLE, crash-injection). L5 — абсолютный acceptance-gate: задача не закрывается, пока локальная приёмка не пройдена. Выполняет агент (`manual-tester` + MCP), локально, не на GitHub-hosted (нужно реальное железо).
- **Финальный gate MVP:** обкатка на **M1 Air** (слабый край) перед релизом MVP — выявляет правки под ограничения железа. Это отдельный gate целой MVP-версии, не каждой задачи.
- **НЕ блокируют (informational / async, можно отказаться):** медленные GitHub-проверки — CodeQL, тяжёлый security-scan, полные матрицы. Выносятся в nightly/scheduled/on-demand, их отсутствие/провал **не блокирует** закрытие задачи. Прямое следствие боли «CodeQL 20-30 мин простоя»: эти проверки полезны, но не на критическом пути acceptance.

Контракт: «принято» = блокирующий набор зелёный (включая локальную L5). GitHub-async-слой — фоновая гигиена, не gate.

## Decisions Made

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Архитектура захвата | Path B (два независимых low-level пайплайна) | Контроль encode-бюджета, sync, один микрофон в оба файла, расширяемость к composite — недостижимо на SCRecordingOutput |
| Дефолт кодека | HEVC Main 8-bit .mp4/hvc1 CFR | 2× эффективность, аппаратный на всех M, шире всех декодится в NLE (см. research decode-матрицу) |
| ProRes | Опция настроек (post-MVP) + probe-fallback | Для реалистичных таргетов 2×HEVC влезает в один движок; ProRes не нужен дефолтом (огромные файлы, Premiere Windows не открывает) |
| Sync | host-time + один микрофон в оба файла | Audio-waveform авто-sync кросс-платформенно; timecode-track — дополнение позже |
| MVP-деградация | Наблюдение (dropped frames + Degraded), без авто-тиров | Лимиты калибруются на реальном железе (M1 Air … M3 Max); performance-test post-MVP |
| Архитектура расширяемости | Pluggable codec/container + RecordingConfiguration + two-tier UX с самого старта | Требование пользователя: добавлять кодеки/форматы/настройки без переписывания |
| Файлов на запись | 2 (экран + камера), звук микрофона в оба | Явное требование пользователя. Макетная строка-сводка перечисляет 3 ИСТОЧНИКА (экран+камера+микрофон), не 3 файла — файлов 2 |
| Модель распространения | MVP — Developer ID + Hardened Runtime + notarization, **без App Sandbox**; post-MVP — MAS-совместимость (App Sandbox) | Sandbox конфликтует с прямым доступом к `~/Movies` и авто-relaunch; так делают OBS/ScreenFlow. MAS — отдельная фаза |
| Верхняя граница разрешения экрана | Дефолт CFR 60; входной pixel-rate экрана **cap по бюджету движка** (CapabilityProbe); 5K/6K дисплеи downscale до вписывания | Research считал 4K60 (0.62–0.75× движка); 5K60 = 1.01–1.14× → на base/Pro 2×HEVC не влезает. Cap по разрешению — рычаг из research |
| Глобальный hotkey | `RegisterEventHotKey` (Carbon-class), НЕ event-tap | Не требует Accessibility/Input Monitoring TCC (нет 4-го разрешения), MAS-ready |
| Сеть | Нет сетевого клиента (no egress) | Гарантирует privacy-обещание AC-8 на уровне сборки |
| Язык / concurrency | Swift 6 + strict concurrency | Compile-time data-race safety для actor-пайплайнов; цена битого файла высока |
| Тесты | Swift Testing | Нативно в Xcode 26 |
| Линт/формат | SwiftLint + SwiftFormat (одобрены как dev-зависимости) | Часть L1-гейта; не в runtime-бинаре |
| Модель разработки | Agent-driven: код + ревью агентами, человек не пишет/не ревьюит | Спеки = автономный контракт; верификация машинно-проверяема; L5 исполняет агент |
| Compiler/language строгость | Максимальная: + warnings-as-errors + strict memory safety + upcoming-флаги + typed throws + SwiftLint strict | Максимум compile-time гарантий разгружает ревью; критично для agent-driven (компилятор не «забывает») |

## Out of Scope (MVP)

Реализуется после MVP (см. Future Phases):
- Меню настроек (выбор кодека/контейнера/разрешения/fps/папки) — *(target: Phase 2)*
- Режимы захвата экрана «Область» и «Окно» (MVP — только весь дисплей) — *(Phase 2)*
- Запись системного звука (только в файл экрана) — *(Phase 2/3)*
- Отдельный микрофон для каждого файла (per-file mic) — *(Phase 2/3)*
- Composite-режим (экран + наложение камеры PiP в один файл) — *(Phase 3)*
- ProRes/H.264 как пользовательский выбор; авто-деградация-тиры; performance-test — *(Phase 2/3)*
- SMPTE timecode-track — *(Phase 2)*
- Уровень микрофона (live meter) на главном экране — *(Phase 2)*

## Open Questions

- [x] **РЕШЕНО** Эвристика авто-формата камеры: дефолт = наибольшее доступное разрешение при fps≥30 (опрос `device.formats`). Явный выбор формата — post-MVP (Phase 2).

## Future Phases

**Phase 2 — Настройки и режимы захвата:** меню настроек (two-tier UX наполняется), выбор кодека/контейнера/разрешения/fps/папки, режимы «Область»/«Окно», уровень микрофона, timecode-track. Отложено ради тонкого MVP.

**Phase 3 — Аудио-расширение и Composite:** системный звук (в файл экрана), per-file микрофон, composite PiP (`CompositeOutputStage` + Core Image compositor), ProRes/H.264 опции, авто-деградация-тиры + performance-test (калибровка на M1 Air … M3 Max).

Специфицируются отдельно после реализации и валидации MVP.
