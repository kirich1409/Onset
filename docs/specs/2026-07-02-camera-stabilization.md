---
type: spec
slug: camera-stabilization
date: 2026-07-02
status: approved
platform: [desktop]
surfaces: [ui]
risk_areas: [perf-critical]
non_functional:
  sla: "этап стабилизации p50 (оценка+рендер) ≤ 0.8 × медианного межкадрового интервала сессии (адаптивный порог, верифицируется телеметрией AC-8; ориентир: 31.2 мс p50 @3× offline); деградация свежести кадров ≤ 5% относительно OFF-baseline по медиане ≥3 пар (AC-2)"
acceptance_criteria_ids: [AC-1, AC-2, AC-3, AC-4, AC-5, AC-6, AC-7, AC-8]
design:
---

# Spec: Стабилизация изображения камеры

Date: 2026-07-02
Status: approved
Slug: camera-stabilization

Эпик #294, issue #296. Основа: `docs/research/camera-stabilization.md` (research + spike #295,
вердикт GO). Реализация — #297, L5-приёмка — #298.

---

## Context and Motivation

Веб-камера (Logitech MX Brio) стоит на мониторе; вибрация от набора текста передаётся через
стол в камеру — в записи видна высокочастотная тряска 1–3 px за кадр. Готового API на macOS
нет (AVFoundation-стабилизация iOS/Catalyst-only). Spike #295 эмпирически доказал: собственный
этап (Vision-оценка на апскейле → каузальный smoother → GPU-рендер) давит тряску ниже порога
заметности (lock-to-ref residual 4.84 → 0.81 px, целочисленный измеритель видит 0 движущихся
пар) при латентности, влезающей в реальную каденцию камеры. Фича опциональная (тумблер,
default OFF), только для записи camera-потока; screen-путь и живое превью не затрагиваются.

## Acceptance Criteria

Фича готова, когда истинны ВСЕ пункты. Верификация AC-1/AC-2/AC-8 — на референсном железе
(MX Brio, M3 Max) в рамках #298; остальные — автотесты/локальные проверки в #297.

- [ ] **AC-1** — На реальной **1080p**-записи с набором текста (MX Brio, включённая
  стабилизация): lock-to-ref отклонение (2 s rolling mean) max ≤ 1 px по субпиксельному
  измерителю (`translational@2×` из `tools/verify-stabilization/`); целочисленный
  `measure-shake` показывает 0 движущихся пар на **размеченном статичном сегменте той же
  typing-записи** (сегмент под активным набором текста — отдельная статичная запись без
  вибрации прошла бы вакуумно). Правила замера: (а) метрика считается ПОСЛЕ завершения
  warm-up (с кадра 61, момент — из лога выбора estScale) — первые ~3 s записи
  нестабилизированы by design; (б) **гейт валидности стимула**: OFF-запись той же
  typing-сцены (back-to-back с ON, неизменные условия) обязана показывать lock-to-ref
  max > 2 px, иначе прогон невалиден (вибрация не дошла до камеры) и повторяется. AC-1
  верифицируется только @1080p.
- [ ] **AC-2** — **N ≥ 3 пар НА КАЖДОЕ разрешение** (1080p и 4K) записей ON/OFF одной
  сцены с непрерывным движением в кадре, снятых back-to-back при неизменных условиях, **без
  вибро-стимула** (стоимость этапа от стимула не зависит, а сдвиг 1–3 px в OFF искусственно
  завышал бы fresh_fps baseline): `median(fresh_fps(ON)) ≥ median(fresh_fps(OFF)) × 0.95`,
  медианы сравниваются раздельно по разрешениям. Гейты A/B `verify-cfr.sh` проходят у всех
  записей; абсолютный гейт C (`MIN_FRESH_FPS=25`, зашит в скрипт) для приёмочных прогонов
  ОТКЛЮЧАЕТСЯ — критерий свежести для них = относительная дельта (Brio 20–25 fps проходит
  зашитый пол монеткой, на 4K падали бы обе записи пары; доработка — в Affected Modules).
  Сцена с движением обязательна: fresh-content check ложно падает на идеально
  стабилизированной статике.
- [ ] **AC-3** — Выключенная стабилизация — нулевая регрессия: `StabilizingVideoSource` не
  создаётся (wiring идентичен текущему), все существующие тесты зелёные, в телеметрии
  отсутствует source `stabilizeCamera`.
- [ ] **AC-4** — Телеметрия этапа: дропы видны как `DropSource.stabilizeCamera` /
  `DropReason.stabilizationDrops` (строка в `DropReportFormatter`); переход в bypass
  фиксируется полем в `DropBreakdown` (+ строка отчёта с временем перехода) и
  `os.Logger`-warning; при устойчивом перегрузе этап деградирует в bypass-режим — запись
  не прерывается, геометрия кадра не меняется (нет zoom-jump), correction рампится к нулю
  (нет translation-snap). **Атрибуция**: индуцированные этапом потери приходят с source
  `stabilizeCamera`, НЕ утекают в capture-счётчики обёрнутого источника — L2-тест
  «медленный fake-этап + быстрый fake-источник → все дропы source = stabilizeCamera».
- [ ] **AC-5** — Тумблер «Стабилизация камеры» в настройках: default OFF, применение
  per-session (`.nextRecordingStart`), во время записи контрол disabled; отдельная
  `Section` с собственным footer-caption; тексты caption и alert — ровно из Decisions Made
  (enabled-текст обязан говорить, что эффект только в записи и превью не стабилизируется;
  disabled-текст согласован с mirror-контролом); при сбое старта этапа alert называет
  стабилизацию и действие пользователя. Верификация: живой прогон настроек
  (manual-tester: запись активна → тумблер disabled + caption; VoiceOver читает footer
  вместе с контролом) + скриншот в PR body.
- [ ] **AC-6** — Знак коррекции закреплён автотестом: на синтетической паре буферов со
  сдвигом (+Δ) этап выдаёт коррекцию (−Δ) (correction = −alignmentTransform). Первый шаг
  #297 — CI-smoke стека Vision+CIContext(Metal) на runner'е; если стек на CI недоступен,
  тест переводится в локальный preflight-гейт с пометкой в PR (фальсифицируемость
  сохраняется, меняется место исполнения).
- [ ] **AC-7** — Выходной файл стабилизированной сессии: разрешение равно плановому
  (scale-back, не «меньший выход»), кодек/контейнер без изменений, PTS исходные (single T0
  инвариант), буферы этапа — NV12/420v (проверка формата пула unit-тестом).
- [ ] **AC-8** — Телеметрия латентности этапа присутствует: `os_signpost`-интервалы вокруг
  оценки и рендера + in-process агрегация p50/p95 (владелец — в Affected Modules) со
  строкой в отчёте сессии. Замер #298 на референсном железе (тихая машина, конфигурация
  camera+screen одновременно): p50 (оценка+рендер) ≤ 0.8 × медианного межкадрового
  интервала, измеренного warm-up'ом той же сессии (адаптивный порог самосогласован с любым
  выбором estScale; лог выбора estScale — обязательный артефакт замера).

**Authoritative definition of done.** Реализующий агент сверяется с этим списком до
объявления любой задачи завершённой.

## Prerequisites

| Prerequisite | Status | Owner | Notes / критерий выхода |
|--------------|--------|-------|-------|
| Spike #295: выбор API, параметры smoother, знак, геометрия | ✅ Done | — | `docs/research/camera-stabilization.md` |
| Инструменты замера в репозитории: `tools/verify-stabilization/` (`measure-shake`, `translational2x` из spike) | ⬜ Todo | Agent (#297) | критерий: инструменты собираются и запускаются из чистого чекаута (сейчас — только gitignored `swarm-report/research/spike/`) |
| Typing-записи 1080p для AC-1: ON + OFF (гейт валидности стимула) | ⬜ Todo | **Human** (физическая вибрация — агент не может трясти стол) + Agent (запуск/замер) | критерий: каждая ≥ 60 s; back-to-back, неизменные условия (та же формула, что AC-2); первые ≥ 5 s без набора (warm-up вне стимула); освещение без low-light смаза по критерию `production-quality-bar`; статичный сегмент для целочисленной части AC-1 — размеченный сегмент ЭТОЙ ЖЕ записи (под активным набором) |
| Motion-записи для AC-2: **N ≥ 3 пар** ON/OFF одной сцены, back-to-back, 1080p и 4K | ⬜ Todo | Human (присутствие в кадре) + Agent | критерий: каждая ≥ 60 s, движение в кадре, неизменный свет между дублями; AC-1 и AC-2 — РАЗНЫЕ записи |
| Условия перф-замера AC-8 | ⬜ Todo | Agent | тихая машина, без сторонней GPU/CPU-нагрузки; camera+screen одновременно, screen = нативный 4K60 (worst realistic case после #293) |

## Affected Modules and Files

| Module / File | Change type | Notes |
|---------------|-------------|-------|
| `Onset/Recording/Stabilize/StabilizationSmoother.swift` | New | pure nonisolated: cum/ref/correction в 1080p-эквивалентных координатах, rate-limited reference, ramp bypass (образец `CFRNormalizer`) |
| `Onset/Recording/Stabilize/StabilizingVideoSource.swift` | New | actor-декоратор `VideoFrameSource & AudioSampleSource`: warm-up выбор estScale, Vision-оценка, рендер, merge drops, bypass |
| `Onset/Recording/Stabilize/StabilizationRenderer.swift` (или внутри декоратора) | New | impure GPU-часть: CIContext(Metal) на выделенной serial DispatchQueue (`qos: .userInitiated`), CVPixelBufferPool NV12, апскейл-буферы оценки (образец `LiveCompressionSession`). Шаг «оценка+рендер» — за protocol/closure seam (паттерн DI seams проекта): иначе L2-тесты декоратора нереализуемы; fake-этап в L2 синхронно занимает work-очередь (семафор), не `Task.sleep` |
| `Onset/Recording/Pipeline/PipelineTypes.swift` | Modified | cases `DropSource.stabilizeCamera` + `DropReason.stabilizationDrops` + `DropCause.stabilizeCamera` (для тай-брейка dominant cause); witnesses `DropSource` (:448/:466), `DropReason` (:278 `==` — **default-ветка молчалива**: без правки пары новый case даст нерефлексивное равенство без compile-error; :302 `hash` — новый ordinal) и `DropCause` (тот же паттерн) |
| `Onset/Recording/Pipeline/DropMonitor.swift` | Modified | reason-switch (:391) — diagnostic-only ветка; ОБА source-switch (:404 bp-tally, :455 breakdown); в `DropBreakdown` (:89): ПАРА count-полей `stabilizeCamera` + `bpStabilizeCamera` (паттерн total/bp-only из #282) + поле bypass + `summaryLine`; **`computeDominantCause()` (:546) — список кандидатов = ЛИТЕРАЛ, не exhaustive-switch**: компилятор не заставит добавить `bpStabilizeCamera` — без ручного добавления кандидата ломается инвариант `dominantCause == .notDegraded ⇔ !sessionEverDegraded` |
| `Onset/Recording/Pipeline/DropReportFormatter.swift` | Modified | строка дропов этапа + строка перехода в bypass |
| `Onset/Recording/Pipeline/RecordingComponentFactories.swift` | Modified | **сигнатура `SourceFactory.makeCameraSource` расширяется параметром `cameraPlan: ResolvedCameraPlan`**; `LiveSourceFactory` оборачивает `CameraSource` в декоратор при `plan.stabilization != nil` |
| `Onset/Recording/Pipeline/RecordingSession.swift` | Modified | call-site фабрики в `buildCameraPipeline` (:559) передаёт план; fallback-конструктор `DropBreakdown` (:847). `DropCounters`/`DropHealthSnapshot` (:840) НЕ меняются — счётчик этапа = приватный tally `DropMonitor` + поле breakdown |
| `Onset/Recording/Pipeline/ResolvedRecordingPlan.swift` | Modified | `ResolvedCameraPlan.stabilization: StabilizationPlan?` (вложенный `nonisolated struct` с cropRect + scaleBack; nil = OFF; НЕ estScale — он runtime) + собственный ручной `==` у вложенного типа + правка пополевого `==` `ResolvedRecordingPlan` (:115) |
| `Onset/Recording/Pipeline/CapabilityResolver.swift` | Modified | вычисление cropRect по плановому разрешению; порядок рычагов деградации фиксируется doc-комментарием (кода деградации в #297 нет) |
| `Onset/Configuration/SettingsKeys.swift` | Modified | ключ `onset.settings.cameraStabilization` |
| `Onset/Storage/SettingsStore.swift` | Modified | `loadCameraStabilization()`/`saveCameraStabilization(_:)` в протокол + обе реализации + default OFF в `SettingsDefaults` |
| `Onset/UI/AppSettings.swift` | Modified | `var cameraStabilization: Bool { didSet { save } }` |
| `Onset/UI/Settings/CameraPane.swift` | Modified | отдельная `Section` (без заголовка, после секции зеркала, перед «Камера») + `Toggle` + собственный footer-caption (тексты в Decisions); обновить doc-comment файла |
| `Onset/UI/Main/MainViewModel+Record.swift` | Modified | проброс свежего значения в `RecordingConfiguration.makeMVPDefault`; alert отказа start(): новая ветка pattern-match `captureSetupFailed(inner) where inner is StabilizationError` — прецедента в catch (:150) нет, пишется с нуля |
| `Onset/Configuration/RecordingConfiguration.swift` | Modified | поле `cameraStabilization`, параметр `makeMVPDefault` |
| `tools/verify-stabilization/` | New | перенос `measure-shake.swift`, `translational2x.swift` из spike + README (unsandboxed-запуск, отбрасывание warm-up-сегмента, гейт валидности стимула) |
| `scripts/verify-cfr.sh` | Modified | параметризация абсолютного гейта C (`MIN_FRESH_FPS` через env/аргумент) + машинно-извлекаемый вывод `fresh_fps` для дельты AC-2 |
| `Onset/Recording/Stabilize/StabilizationTelemetry.swift` (или внутри декоратора) | New | in-process агрегация латентности p50/p95 (владелец AC-8) + передача строки в отчёт сессии |
| `.github/workflows/` (CI-smoke Vision/Metal для AC-6) | Modified (conditional) | **мета-файл: owner-review, НЕ auto-merge** (CLAUDE.md-исключение) — вынести в отдельный микро-PR с явным ревью владельца |
| `scripts/preflight.sh` | Modified (conditional) | fallback AC-6: локальный preflight-гейт, если CI-стек недоступен |
| `OnsetTests/StabilizationSmootherTests.swift` | New | L2: rate-limit, ramp, координаты, warm-up, дрейф/всплеск-сценарии |
| `OnsetTests/StabilizingVideoSourceTests.swift` | New | L2: dual-facet форвардинг, merge drops, bypass, one-shot lifecycle, teardown при сбое start (Fake-паттерн `RecordingSessionTests.swift:150`) |
| `OnsetTests/StabilizationSignTests.swift` | New | AC-6: синтетическая пара сдвинутых буферов → знак коррекции |
| `OnsetTests/RecordingSessionTests.swift` | Modified | `FakeSourceFactory` — новая сигнатура `makeCameraSource` |
| `OnsetTests/DropMonitorTests.swift`, `OnsetTests/DropReportFormatterTests.swift` | Modified | новые case/поля breakdown (exhaustive switches, конструкторы) |
| `OnsetTests/…L5…` | New | env-гейт `ONSET_RUN_L5_CAPTURE` — живой прогон этапа (в #298) |
| `docs/architecture.md`, `docs/architecture/camera-recording-pipeline.md` | Modified | этап в карте пайплайна — в том же PR (#297) |
| `docs/quality/production-quality-bar.md` | Modified | L5-сьюта стабилизации + методика AC-1/AC-2 (§4.3 env-гейты) |

Key integration points:
- `SourceFactory.makeCameraSource(... cameraPlan:)` (`RecordingComponentFactories.swift:257`, протокол :249) — единственная точка включения декоратора; call-site — `buildCameraPipeline` (`RecordingSession.swift:559`).
- `VideoFrameSource` (`CaptureSource.swift:43`) + `AudioSampleSource` (`:95`) — контракт декоратора (dual-facet!).
- `VideoFrame` (`PipelineTypes.swift:113`) — инвариант read-only, `ptsHostTime`/`isHoldRepeat` переносятся как есть.
- `DropMonitor.observe` — получает merged-стрим декоратора, дополнительных вызовов не требуется.
- Превью (`MainViewModel.swift:601`, `CameraSource(role: .preview)`) — декоратором НЕ оборачивается (см. Out of Scope).

## Technical Approach

**Поток данных:** `CameraSource.frames` → `StabilizingVideoSource` (оценка → smoother →
рендер) → `VideoEncoder.ingest`. Hold-repeat кадров на этом отрезке не существует
(CFR-нормализация живёт внутри `VideoEncoder`) — оценка движения видит только реальные кадры.

**Декоратор (dual-facet).** `StabilizingVideoSource` конформит `VideoFrameSource &
AudioSampleSource`: `audioSamples`, `events` форвардятся обёрнутому `CameraSource` без
изменений; `frames` — трансформируемый поток; `drops` — собственный стрим, в который
внутренняя задача merge'ит дропы обёрнутого источника и собственные дропы этапа. One-shot
lifecycle: `start(anchoredTo:)` сначала аллоцирует пул/CIContext/executor (сбой ДО старта
обёрнутого → throw без side-effects), затем `wrapped.start`; сбой ПОСЛЕ старта обёрнутого →
`await wrapped.stop()` перед `throw RecordingError.captureSetupFailed` с **различимым
inner-error** `StabilizationError` (образец — `CameraSourceError`, `CameraSourceShims.swift:255`;
generic-case без дискриминатора не позволил бы alert'у достоверно назвать причину, а эвристика
«тумблер ON → стабилизационный текст» давала бы ложную инструкцию при реальном сбое камеры).
`stop()` идемпотентен. Alert показывает стабилизационный текст ТОЛЬКО при inner-типе
`StabilizationError`, иначе — существующий generic-текст; L2-тест teardown проверяет тип ошибки.

**Warm-up и выбор estScale (runtime, не pre-flight).** Плановый fps не отражает реальную
каденцию (Brio анонсирует 60, доставляет 20–25) — выбор по плану дал бы 2× ровно там, где
AC-1 доказан @3×. Поэтому: первые 60 реальных кадров — warm-up: кадры рендерятся с
correction = 0 (геометрия сессии уже активна — zoom-flicker исключён), меряется медианный
межкадровый интервал; медиана ≥ 40 мс → `estScale = 3×`, иначе `2×`. Выбор логируется,
неизменен до конца сессии; буферы оценки аллоцируются после выбора. Следствие: честные
30 fps (FaceTime) и 4K-план с честными 30 fps получают 2× (бюджет 33 мс не вмещает 3×) —
компромисс точности задокументирован в Decisions.

**Оценка движения.** `VNTranslationalImageRegistrationRequest` по паре соседних реальных
кадров на апскейле. **Рабочее разрешение оценки фиксировано на 1080p-эквиваленте**: буферы
оценки всегда `(1920×estScale) × (1080×estScale)` независимо от планового разрешения
(4K-кадр приводится тем же CI-рендером — иначе 4K×3 = 12K-оценка). Двойная буферизация
«предыдущий/текущий» — каждый кадр апскейлится один раз. Vision `perform` и CI-рендер
исполняются на выделенной serial work-очереди `DispatchQueue(label:…, qos: .userInitiated)` —
30 мс синхронной работы на кадр нельзя пускать в кооперативный пул Swift Concurrency (образец
изоляции — C-interop в `Onset/Encode/`). **Drain-цикл НЕ разделяет изоляцию с оценкой+рендером**:
work-очередь этапа — обычная очередь за continuation-мостом, НЕ executor актора-декоратора;
иначе выброс Vision 85–250 мс блокировал бы resume drain-цикла и переполнение утекало бы в
capture-счётчики (см. Дроп-политика). Drain-задача — QoS не ниже `.userInitiated`.

**Система координат (контракт).** Smoother работает в 1080p-эквивалентных координатах:
`shiftEq = shiftRaw / estScale` (raw — координаты буфера оценки). Масштабирование в плановые
координаты — один раз на выходе: `correctionPlan = correctionEq × (planWidth / 1920)`.
Параметры `alpha`/`maxRefStep` сохраняют эмпирически проверенный смысл на любом разрешении.
Знак: `correction = −alignmentTransform` (AC-6). Выходная коррекция клампится к границам
кропа: `|correctionPlan| ≤ margin` по каждой оси (одиночный крупный сдвиг — камеру задели —
не даёт edge-smear от clampToExtent; см. Decisions).

**Smoother (pure, `StabilizationSmoother`).** Каузальный lock-with-slow-recenter:
`cum += shiftEq; ref += clamp(alpha·(cum − ref), ±maxRefStep); correction = ref − cum`.
Параметры: `alpha = 0.05`, `maxRefStep = 0.01 px/кадр` (1080p-эквивалент). Начальное
состояние: `cum = ref = 0`, первый кадр (и весь warm-up) — correction = 0. Плоская EMA
запрещена (эмпирика spike: лаг даёт residual 1.8–2.3 px). Deadband к коррекции не
применяется; телеметрия «доля кадров с нулевой коррекцией» считается отдельно.

**Рендер (impure, GPU).** Каждый кадр без исключений: CIImage(input) → translate(correction)
→ clampToExtent → crop(session-fixed rect) → изотропный scale-back до плановых размеров →
render в НОВЫЙ CVPixelBuffer формата 420v из собственного `CVPixelBufferPool`. Кроп:
`marginX = roundEven(16 × planWidth / 1920)`, `marginY = marginX × 9/16`, rect ровно 16:9 с
чётными размерами. Для 1080p: `(16, 9, 1888, 1062)` (×1.016949); для 4K:
`(32, 18, 3776, 2124)`. «Skip render» запрещён — passthrough сырого буфера даёт zoom-flicker
(эмпирика spike).

**Пул и память.** Выходной пул — threshold-семантика:
`kCVPixelBufferPoolAllocationThresholdKey = 12` (= `maxPendingFrames` 4 энкодера + in-flight 1
+ retention VT 2 + `lastPixelBuffer` энкодера 1 (CFR hold-repeat держит последний реальный
кадр, `VideoEncoder.swift:166`) + глубина выходного стрима `.bufferingNewest(4)` под
encoder-backpressure), аллокация через `auxAttributes`, отказ аллокации → дроп кадра с
`DropEvent(.stabilizeCamera, .stabilizationDrops)` — НЕ ошибка, поток продолжается.
**Pool-exhaustion-дропы НЕ кормят bypass-триггер** (bypass — только по вытеснениям слота
оценки: исчерпание пула — симптом downstream-затора, который bypass не лечит). Бюджет памяти
этапа: апскейл-буферы @3× ≈ 56 МБ (2 × 5760×3240 NV12), выходной пул ≈ 37 МБ @1080p /
≈ 150 МБ @4K (пиковые, lazy-аллокация).

**Дроп-политика и атрибуция (eager-drain).** Vision имеет редкие латентные выбросы
(85–250 мс). Внутренний цикл потребления входного стрима НИКОГДА не суспендится на работе
этапа: кадры немедленно перекладываются в собственный слот глубины 1 (newest wins;
вытесненный → `DropEvent(.stabilizeCamera, .stabilizationDrops)`), обработка идёт отдельной
задачей на executor. Иначе переполнение утекало бы вверх в `bufferingNewest(4)`
`CameraSource` и атрибутировалось capture-счётчикам — bypass никогда бы не сработал.
Выходной стрим `frames` декоратора сохраняет bounded-контракт протокола
(`.bufferingNewest(4)`): его overflow (медленный энкодер) = reason
`.encoderBackpressureDrops`, source `.stabilizeCamera` — кормит degraded-окно как обычная
encoder-backpressure (это реальная потеря контента). Diagnostic-only — ТОЛЬКО reason
`.stabilizationDrops`. Ошибка Vision на паре → кадр проходит с correction предыдущего кадра
(freeze), счётчик ошибок в телеметрию; 60 подряд ошибок → bypass.

**Уточнения потока кадра (walk-through-закрытия).**
- *Continuation-мост*: работа этапа исполняется через `withCheckedContinuation` поверх serial
  work-очереди (checked, не unsafe; single in-flight гарантирован дизайном: слот глубины 1 +
  единственная work-задача). Границу пересекают только `CVPixelBuffer`-ссылки — тот же
  read-only инвариант, что у `VideoFrame` (@unchecked Sendable). Прецедента моста в кодовой
  базе нет — это первый, паттерн фиксируется здесь.
- *Слот глубины 1*: идиома проекта `AsyncStream(bufferingPolicy: .bufferingNewest(1))` с
  детекцией вытеснения по yield-результату (как в `CaptureSource.swift`).
- *Warm-up*: каденция меряется на drain-цикле по дельтам `ptsHostTime` входящих кадров
  (не wall-clock обработки); warm-up-кадры идут тем же путём слот → work-очередь → рендер
  (crop/scale-back без Vision) — отдельного короткого пути нет. **Bypass-триггеры активируются
  только после завершения warm-up** (до выбора estScale эвикции слота не считаются).
- *Freeze при ошибке оценки*: smoother не получает shift (cum не меняется); актор
  переиспользует кэшированный `lastCorrection` прошлого кадра.
- *Сбой CI-рендера* (Metal/command buffer): кадр дропается с
  `DropEvent(.stabilizeCamera, .stabilizationDrops)` и инкрементирует ОБЩИЙ счётчик
  последовательных ошибок (Vision + render; 60 подряд → bypass); passthrough сырого кадра
  запрещён и здесь (геометрия). Пропуск тика восполняется downstream `CFRNormalizer`
  hold-repeat'ом — осознанное поведение, как и при pool-exhaustion.
- *Штатный `stop()`* (порядок, по образцу cancel+await `VideoEncoder.stop()`):
  (1) `await wrapped.stop()` — upstream останавливается, его стримы финишируют;
  (2) drain-цикл дочитывает вход до finish; (3) await завершения in-flight work-айтема —
  последний кадр долетает в выход; (4) finish собственных стримов; (5) release пула/контекста.
  Потери кадров на штатном stop нет.

**Bypass-деградация (runtime).** Порог согласован с бюджетом AC-2 (5%): дропы этапа > 5%
кадров в скользящем окне 10 s, два ПОСЛЕДОВАТЕЛЬНЫХ окна → bypass (защита от транзиентов —
Spotlight, переключение GPU). В bypass: Vision-оценка останавливается, рендер session-fixed
геометрии продолжается, correction рампится к нулю с шагом ≤ 0.1 px/кадр (нет
translation-snap), нагрузка падает до render-cost (~1.5 мс/кадр). Возврат из bypass в рамках
сессии не выполняется. Переход: `os.Logger` warning + поле в `DropBreakdown` → строка в
отчёте сессии с временем перехода («стабилизация отключена на N-й секунде: перегруз»).

**Семантика телеметрии.** `DropReason.stabilizationDrops` — diagnostic-only: счётчик,
breakdown, строка отчёта; degraded-окно `DropMonitor`/`RecordingState` НЕ кормит (перегруз
этапа обрабатывается собственным bypass-механизмом, не UI-стейтом записи). Латентность:
`os_signpost`-интервалы вокруг оценки и рендера + p50/p95 в отчёт сессии (AC-8).

**Pre-flight.** `CapabilityResolver` вычисляет cropRect/scaleBack по плановому разрешению и
переносит `enabled` в `ResolvedCameraPlan`. Кода pre-flight-деградации в #297 НЕТ (условий
нет: оценка всегда на 1080p-эквиваленте); порядок рычагов на будущее — clamp →
drop stabilization → downscale → fps — фиксируется doc-комментарием у существующей
лестницы в `resolve()`. VT-бюджет (`EngineBudgetCap`) стабилизация не потребляет — выходные
размеры энкодера не меняются (осознанное отличие от research-предложения «множитель в
EngineBudgetCap», см. Decisions).

**Настройка.** Цепочка `cameraMirror`-паттерна: `SettingsKeys` → `SettingsPersisting`
(+ обе реализации) → `AppSettings` → `CameraPane` → `ControlAvailability.classify(.nextRecordingStart)`
→ чтение свежего значения в `MainViewModel+Record` →
`RecordingConfiguration.makeMVPDefault(cameraStabilization:)` → `CapabilityResolver` →
`ResolvedCameraPlan` → `LiveSourceFactory`.

## Technical Constraints

- Только системные фреймворки: Vision, CoreImage, Metal (первые импорты в таргете — запереть
  внутри `Onset/Recording/Stabilize/`; `Configuration` остаётся Foundation-only). Никаких новых
  зависимостей. `check-no-network.sh` инвариант не затрагивается (Vision/CI — не сетевые).
- Swift 6 strict concurrency `complete`, default MainActor isolation, warnings-as-errors,
  strict memory safety (`unsafe`-аннотации по образцу `Onset/Encode/`).
- Vision `perform`/CI-рендер — только на выделенной serial DispatchQueue (dedicated executor),
  НЕ в кооперативном пуле Swift Concurrency.
- Все новые enum с ручными `nonisolated static func ==` / `hash(into:)` (ловушка
  `InferIsolatedConformances` — см. `PipelineTypes.swift:445`).
- Входной `CVPixelBuffer` read-only (инвариант `@unchecked Sendable` `VideoFrame`); рендер
  только в новый буфер из собственного пула; `ptsHostTime` без переконвертации; `isHoldRepeat`
  переносится as-is.
- Screen-пайплайн и preview-путь не затрагиваются ни одним diff'ом.
- Pure-логика (`StabilizationSmoother`) не импортирует Vision/CoreImage — тестируется на L2
  без GPU.
- UI — только стандартные компоненты (Toggle/Form/Section + footer), строки — русский inline
  (локализационных ресурсов в проекте нет).
- Инструменты приёмки с AVAssetReader запускать unsandboxed (sandbox → −11800/−17913) —
  зафиксировать в README `tools/verify-stabilization/`.
- Docs обновляются в том же PR (#297).

## Decisions Made

| Decision | Choice | Rationale |
|----------|--------|-----------|
| API оценки | `VNTranslationalImageRegistrationRequest` на апскейле | эмпирика spike: 0 выбросов; homographic шумит (4.8 px паразит), VTMotionEstimation не создаётся на 4K и без confidence |
| Выбор масштаба оценки | runtime warm-up по ИЗМЕРЕННОЙ каденции (60 кадров, медиана ≥ 40 мс → 3×, иначе 2×) | плановый fps лжёт (Brio: план 60, реально 20–25) — выбор по плану дал бы 2× на референсном железе AC-1; честные 30 fps физически не вмещают 3× (29.6 > 33.3 мс бюджета) |
| Рабочее разрешение оценки | всегда 1080p-эквивалент × estScale | 4K×3 = 12K-оценка бессмысленна; стоимость оценки не зависит от планового разрешения |
| Система координат smoother | 1080p-эквивалент; ×(planWidth/1920) один раз на выходе | параметры alpha/maxRefStep тюнились на 1080p и сохраняют смысл на любом разрешении |
| Smoother | lock-with-slow-recenter, alpha 0.05, maxRefStep 0.01 px/кадр | плоская EMA даёт лаг-residual 1.8–2.3 px; rate-limit → теоретический residual 0.6 px |
| Знак коррекции | `correction = −alignmentTransform`, закреплён тестом | эмпирика: «+» удваивает тряску |
| Геометрия | session-fixed crop 16:9 чётный (формула margin ×planWidth/1920) + изотропный scale-back | VT требует неизменных dimensions; scale-back сохраняет заявленное разрешение файла; анизотропия запрещена |
| Рендер | каждый кадр, NV12/420v, свой пул глубиной ≥ 8 | skip-render = zoom-flicker (эмпирика); BGRA — лишняя конверсия; глубина покрывает maxPendingFrames+VT retention |
| Исчерпание пула mid-session | дроп кадра с DropEvent, не ошибка | стабильность записи важнее одного кадра |
| Executor этапа | выделенная serial work-очередь `qos: .userInitiated` за continuation-мостом; drain-цикл на ДРУГОЙ изоляции | 30 мс синхронного Vision в кооперативном пуле = голодание акторов; drain на той же очереди = утечка атрибуции в capture на выбросах Vision |
| Default тумблера | OFF (opt-in) | +30 мс/кадр GPU на каденции Brio, 1.7% zoom — осознанный выбор пользователя |
| Политика применения | `.nextRecordingStart` | геометрия и пул фиксированы на сессию, mid-session переключение = zoom-jump |
| Тексты UI | Toggle: «Стабилизация камеры». Footer enabled: «Подавляет дрожание от вибраций (например, при наборе текста). Действует только на запись — превью не стабилизируется. Изображение записи немного обрезается по краям. Применяется со следующей записи». Footer при disabled во время записи: «Недоступно во время записи» (формула mirror-контрола — панель говорит одним языком). Alert сбоя старта (только при inner-error `StabilizationError`): «Не удалось запустить стабилизацию камеры. Выключите её в настройках приложения (вкладка „Камера") и повторите запись.» | превью живёт мимо декоратора — без этой строки пользователь включит тумблер, увидит тряску в превью и решит, что фича не работает; название+caption скоупят обещание (не чинит смаз); disabled-текст согласован с соседним контролом |
| Размещение в UI | отдельная `Section` без заголовка в `CameraPane`, после секции зеркала, перед «Камера» | footer = единственный канал пояснения (VoiceOver); один footer на два контрола — каша; порядок фиксирован, чтобы не разбивать связанные блоки |
| Кламп коррекции | `|correctionPlan| ≤ margin` по каждой оси | одиночный крупный сдвиг (камеру задели, ~30 px) иначе даёт edge-smear от clampToExtent на десятки секунд, пока ref доползает (0.6 px/s) |
| Счётчики этапа | `DropCounters`/`DropHealthSnapshot` НЕ меняются; приватный tally `DropMonitor` + поле `DropBreakdown` | согласуется с diagnostic-only семантикой; не трогает потребителей снапшота |
| Порог AC-8 | адаптивный: p50 ≤ 0.8 × медианного межкадрового интервала warm-up | жёсткие 33 мс имели ~6% запаса от офлайн-замера и противоречили коридору выбора 3× (40+ мс); адаптивный порог самосогласован при любом estScale |
| Runtime-деградация | bypass, ДВА триггера: (1) > 5% вытеснений слота оценки в окне 10 s, два последовательных окна; (2) 60 подряд ошибок Vision. Счётчик триггера (1) кормят ТОЛЬКО вытеснения слота оценки — не pool-exhaustion и не encoder-backpressure. Ramp correction → 0 (≤ 0.1 px/кадр); без возврата в сессии | порог согласован с бюджетом AC-2 (было 20% — коридор 5–20% валил SLA молча); два окна — защита от транзиентов; ramp убирает translation-snap; pool/encoder-дропы — симптомы downstream, bypass их не лечит |
| Коммуникация bypass пользователю | строка в отчёте сессии + os.Logger; без live-алерта | не прерывать запись вниманием; отказ мягкий (запись продолжается, геометрия стабильна); отчёт сессии — существующий канал диагностики |
| Телеметрия дропов этапа | diagnostic-only (не кормит degraded-окно UI) | перегруз этапа обрабатывается собственным bypass; UI-стейт записи — про потерю контента, не про отказ опции |
| VT-бюджет | стабилизация НЕ потребляет `EngineBudgetCap` (отличие от research-предложения) | выходные размеры энкодера не меняются — VT-нагрузка та же; GPU-нагрузка этапа управляется bypass-механизмом, не пиксельным бюджетом |
| Порядок pre-flight рычагов (будущее) | doc-комментарий: clamp → drop stabilization → downscale → fps; кода в #297 нет | YAGNI: условий деградации сейчас нет; спекулятивная машинерия в резолвере — лишний код |
| UX-ограничения (blur/jello) | в UI не коммуницировать сверх footer-caption | UI-минимализм проекта; название/caption уже скоупят обещание («дрожание от вибраций»); детали в docs/research |

## Out of Scope

- **Стабилизация живого превью** — превью (`CameraSource(role: .preview)`, `MainViewModel.swift:601`)
  живёт мимо декоратора и показывает сырой кадр без кропа. Осознанное решение: превью — framing
  aid, не WYSIWYG; расхождение коммуницируется footer-caption тумблера.
- Стабилизация screen-потока (экран не трясётся).
- Траекторное сглаживание с look-ahead (буферы 15 кадров @4K ≈ 190 МБ — отклонено research).
- Ротационная/perspective-коррекция (rolling-shutter jello) — только трансляция.
- Компенсация motion blur внутри кадра (low-light Brio firmware — отдельная проблема экспозиции).
- Динамический (per-frame) кроп и mid-session переключение тумблера.
- Возврат из bypass-режима внутри сессии.
- Пере-выбор estScale в рантайме после warm-up.
- Pre-flight-деградация в `CapabilityResolver` (код) — только doc-комментарий порядка рычагов.
- Homographic-fallback с гейтингом *(owner: backlog, target: отдельный issue при недостаточности translational)*.
- Энерго/термо-оптимизация длинных сессий — замер в #298, оптимизация отдельным issue при необходимости.

## Open Questions

- [ ] Точная стоимость GPU-рендера на реальном 4K-материале (прототип — теория ×4 по пикселям,
  ~6 мс) — *non-blocking*: замеряется в #298 (AC-2 на 4K закрывает риск); при честных 30 fps
  на 4K warm-up выберет 2× — допущение о реальной каденции 4K-доставки Brio (~20 fps)
  зафиксировано и проверяется там же.
- [ ] Энергия/теплопакет при записи ≥ 30 мин с включённой стабилизацией (первая постоянная
  GPU-нагрузка приложения) — *non-blocking*: длинный прогон в #298; критерий — отсутствие
  деградации fresh_fps к концу записи.
- [ ] Поведение под живым backpressure всего пайплайна (прототип — офлайн) — *non-blocking*:
  закрывается AC-2/AC-4 на живой записи.
- [ ] Работоспособность Vision+CIContext(Metal) на GitHub CI runner'ах — *non-blocking*:
  CI-smoke первым шагом #297; fallback AC-6 — локальный preflight-гейт (см. AC-6).
- [ ] Полоса ложного отказа AC-8 при медиане каденции 40–44 мс (бюджет 32–35 мс при офлайн
  p50 31.2 мс + живая GPU-конкуренция) — *non-blocking*: на реальной каденции Brio
  (45–50 мс) запас комфортный; границу cut-in 3× перетюнить по факту замеров #298.

## Future Phases

Не планируются: фича одноэтапная. Потенциальные продолжения перечислены в Out of Scope.
