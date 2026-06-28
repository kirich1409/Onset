---
type: tasks
slug: continuity-camera-frozen-recording
---

# Tasks: фикс заморозки записи Continuity Camera (#268)

Ветка `fix/continuity-camera-frozen-recording` (чистая). Имплементация — general-purpose (нет
Swift-специалиста). Минимальный дифф в hot-path; без рефактора смежного. Swift 6 strict concurrency,
default MainActor, warnings-as-errors, no_magic_numbers, no force_unwrapping, missing_docs.

## T-1 — Чистый тип `LatencyGraceEstimator` (огибающая + пессимистичный init)
Files: `Onset/Encode/LatencyGraceEstimator.swift` (new)
- nonisolated pure struct (split «pure logic + impure actor», как `CFRNormalizer`). API:
  `init(floor: Double, ceiling: Double)` (ceiling — именованная `static let` ~0.5s), `mutating func
  observe(latencySeconds: Double)`, `func effectiveGrace(fps: Int) -> Double`. KDoc на тип + оба метода +
  хранимые свойства (`missing_docs`). Decay-алгоритм выбрать и обосновать (рекоменд. max-with-decay,
  fast-attack/slow-decay по observe, decay-rate константой).
- Отслеживает **верхнюю огибающую** Δ (max-with-decay: fast-attack вверх, slow-decay вниз; ИЛИ p95
  скользящего окна — выбрать с обоснованием в коде), НЕ среднее. Инициализация **пессимистичная**
  (на ceiling, ~0.5s), релакс вниз к измеренной Δ. `effectiveGrace = clamp(floor=defaultGrace(fps),
  envelope, ceiling)`. Игнорировать отрицательные/аномальные Δ.
- **Acceptance (THE SYSTEM SHALL):** (a) cold-start: `effectiveGrace` стартует у ceiling (не floor);
  (b) поток Δ выше текущей оценки → grace растёт немедленно (fast-attack); (c) длительно низкая Δ →
  grace релаксирует к floor; (d) джиттер: одиночный высокий Δ среди низких → grace покрывает его, не
  усредняет. Check: `LatencyGraceEstimatorTests` (pure L2, без устройства), тесты по пунктам a–d.

## T-2 — Интеграция estimator в VideoEncoder: Δ на всех кадрах + grace в ОБОИХ потребителях  (after: T-1)
Files: `Onset/Encode/VideoEncoder.swift` (CFRNormalizer+CatchUp.swift — verify/no-change)
- Держать `LatencyGraceEstimator` в изоляции VideoEncoder (per-lane), init `floor = grace ??
  defaultGrace(fps)`, `ceiling = static let`; **удалить мёртвое поле `self.graceSeconds`**. В `ingest`
  добавить `let clockNow = CMTimeGetSeconds(PipelineClock.currentHostTime())` (его там нет;
  `ContinuousClock.now` :603 — другой тип), `Δ = clockNow − CMTimeGetSeconds(frame.ptsHostTime)`.
  `estimator.observe(Δ)` вызвать в ДВУХ местах (единый guard :617 объединяет pre-anchor+dup — отдельной
  точки нет): внутри dup-ветки при `slotS >= 0`, И на valid-new-frame пути. Pre-anchor (slotS<0) —
  пропустить. См. plan.md «Implementation notes».
- `effectiveGrace = estimator.effectiveGrace(fps:)` передавать **вместо** `self.graceSeconds` в ОБОИХ
  call-site'ах ВНУТРИ VideoEncoder: `secondsUntilNextDeadline` (`VideoEncoder.swift:528`) и
  `clockTick`→`catchUpHolds` (`VideoEncoder.swift:569`). Сигнатуры `catchUpHolds`(:180)/
  `nextDeadlineSeconds`(:237) уже принимают `graceSeconds` → `CFRNormalizer+CatchUp.swift` НЕ менять.
  Добавить инвариант-коммент: `effectiveGrace` читается свежим каждый цикл (дедлайн пересчитывается
  пер-тик) → смена grace между планированием и тиком = повторный сон, не спин.
- **Acceptance:** Given кадры с capture-PTS, отстающими от wall-clock на Δ (floor<Δ<ceiling) со старта
  сессии, When через ingest+clockTick, Then они НЕ dup-дропаются (идут как real в свой capture-PTS слот).
  Check: encoder-уровневый L2 (T-5) на dup-drop. Busy-spin — НЕ L2 (тест-вход минует sleep-петлю),
  проверяется L5 CPU-чеком (T-6).

## T-3 — (investigate) Согласование camera grid-fps с активированным форматом
Files: `Onset/Recording/Pipeline/ResolvedRecordingPlan.swift`, `CapabilityResolver.swift`
- Исследовать contract-mismatch: grid `Int(CameraFormat.maxFps)`=60 vs `activateFormat` пинит 1/30 для
  Continuity. Привязать grid-fps к фактически активированному формату/доставке (рантайм), если безопасно
  для других камер (FaceTime built-in, Brio) и screen; иначе обоснованно отклонить.
- **Acceptance / DoD:** записать в progress.md фактический активированный camera fps (из debug-дока:
  Continuity = 30 при grid 60) И решение (привязать grid к активированному fps — с тестом; ИЛИ отклонить
  с причиной). Если сделано: camera grid-fps == активированный fps; FaceTime built-in/Brio/screen не
  затронуты. T-3 должен приземлиться ДО L5-тюнинга констант (T-6). Check: L2 на resolver + L5 no-regress.

## T-4 — Observability: dup-drop эмитит DropEvent → виден в tech-info  (after: T-2)
Files: `Onset/Encode/VideoEncoder.swift`, verify `DropReportFormatter.swift`, `DropMonitor.swift`
- На dup-drop (`ingest:618-630`), ТОЛЬКО при `slotS >= 0` (не pre-anchor), заэмитить
  `DropEvent(reason: .cfrNormalizationDrops, source: .encode, count: 1, detectedAt: frame.ptsHostTime)`
  (shared `DropReason` из PipelineTypes, НЕ локальный CFRDropReason) в `dropsContinuation`. `recordDropDup`
  оставить (телеметрия `drop_dup`). Не консолидировать три счётчика в этом PR. Обновить doc-comment
  `drops` (VideoEncoder.swift:221).
- **Acceptance:** Given серию dup-drop, When сессия завершается, Then tech-info «Нормализация CFR» > 0
  (а не структурный 0), И «Деградация» НЕ зажигается от этого (DropMonitor.swift:414-418). Check: L2
  VideoEncoder — dup-drop yield'ит DropEvent(.cfrNormalizationDrops); проверка отсутствия degraded-latch.

## T-5 — Encoder-уровневый регресс-тест (cold-start гонка) + observability  (after: T-2,T-4)
Files: `OnsetTests/VideoEncoderTests.swift` (+ при нужде CFRNormalizerCatchUp тесты)
- Детерминированный L2: со старта сессии интерливить `clockTick(nowSeconds:)` (гонит фронтир вперёд) и
  поток high-latency `ingest` (capture-PTS отстаёт на Δ). Без фикса — все кадры dup-swallow (демонстрация
  бага); с фиксом — устойчивый `recordEncodedReal>0`, нет вечного `drop_dup`. Чистый CFRNormalizer-тест
  слот-арифметики НЕ покрывает эту гонку (она в actor) — нужен encoder-уровень. ПРИМ.: busy-spin этот
  L2 НЕ покрывает (`clockTick(nowSeconds:)` минует sleep-петлю `startClock`) — спин только в L5 (T-6).
- **Acceptance:** тест RED на старой логике / GREEN после фикса; существующие CFR/encoder-тесты целы.
  Check: `xcodebuild test` — тест по имени проходит.

## T-6 — L5: iPhone Continuity live + no-regress (FaceTime built-in, Brio 4K, screen)  (after: T-2,T-4)
Files: — (runtime, целевой Mac)
- Подписанный билд → запись iPhone Continuity (движение в кадре) → `freezedetect`/`mpdecimate`/хэш-свип
  ⇒ live; телеметрия `drop_dup→~0`, `fresh→~30/с`; **снять распределение Δ** (калибровать ceiling ≥
  наблюдаемого max Δ); CPU camera-лейна не растёт (busy-spin). **No-regress (все три):** FaceTime built-in,
  Brio (4K), screen остаются live + **первая ~1с** на низколатентных лейнах (cold-start) live + cadence
  холдов на **статичном screen** (без движения) не зависает за ceiling. T-3 должен приземлиться до тюнинга.
- **Acceptance:** iPhone Continuity live (нет сплошного freeze, mpdecimate ≫ 1, разные хэши при движении);
  FaceTime built-in + Brio + screen без регресса (вкл. первую 1с и статичный screen); CPU без спина;
  ceiling ≥ max Δ. Check: артефакты `~/Movies/Onset <ts>/` + лог телеметрии + Δ-распределение; результаты
  в progress.md / debug-док. L5 только на целевом Mac (CLAUDE.md) — cloud не закрывает.
