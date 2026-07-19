---
type: plan
slug: continuity-camera-frozen-recording
date: 2026-06-28
status: approved
spec: none
issue: 268
risk_areas: [recording-hot-path, cfr-timing, av-sync, stability, concurrency]
review_verdict: conditional
---

# План: фикс заморозки записи с Continuity Camera (#268)

## Context & Decision

P0-баг (issue #268, полный разбор — `swarm-report/continuity-camera-frozen-recording-debug.md`):
запись с iPhone-as-Continuity-Camera даёт замороженное видео (1 уникальный кадр на весь клип), при
живом превью и **живой записи с Brio, встроенной FaceTime HD Camera и screen**. Root cause подтверждён
эмпирически.

**Механизм (доказан по коду + телеметрии):** camera-lane CFR-сетка self-clocked: `clockTick`
продвигает `lastEmittedSlot` по **wall-clock** через `catchUpHolds`
(`CFRNormalizer+CatchUp.swift:203`: `eligibleThrough = floor((nowSeconds − anchor − grace)·fps − 0.5)`).
Реальные кадры мапятся в слоты по **capture-PTS** (`VideoEncoder.ingest:616`, `CFRNormalizer.slotFor:250`).
Латентность доставки Continuity Δ≈100–200ms ≫ `grace=max(5ms,2/fps)=33ms@60fps` → к ingest'у кадра его
слот уже `≤ lastEmittedSlot` → dup-drop (`VideoEncoder.ingest:618`, return **без обновления
`lastPixelBuffer`**, оно пишется только на не-dup ветке :665) → все hold-слоты повторяют кадр №0.
Телеметрия camera-lane: `fresh→0`, `drop_dup≈30/с`, `holds≈60/с`. Brio/FaceTime built-in (низкая Δ) и
screen — проходят. ffmpeg того же устройства — живой (нет wall-clock CFR-драйвера).

**Решение (план реализации; «что чинить» решено):** сделать hold-фронтир **latency-aware** — `grace`
лейна должен покрывать его реальную capture→ingest латентность, чтобы реальные кадры успевали прийти до
hold-заполнения их слота и шли по настоящему пути в **корректный** capture-PTS слот. `grace` задерживает
только момент hold-эмиссии относительно wall-clock — НЕ меняет назначение слотов → A/V-синхрон цел
(видео и аудио по capture-PTS), stall-hold цел (при настоящем простое >grace холды эмитятся, лишь
задержанно). Для низколатентных лейнов (FaceTime built-in, Brio, screen) grace остаётся на floor →
поведение не меняется (требование no-regress).

## Technical Approach

**Оценщик латентности — чистый тип, верхняя огибающая.** Вынести в новый nonisolated pure-тип
(напр. `LatencyGraceEstimator`) — по правилу проекта «pure logic + impure actor» (как `CFRNormalizer`,
`CapabilityResolver`). API: `mutating func observe(latencySeconds: Double)` + `func effectiveGrace(fps:)
-> Double`. `VideoEncoder` лишь скармливает `Δ` и читает grace.
- **Огибающая, не среднее.** Кадр выживает только если `grace > Δ` ИМЕННО этого кадра → оценщик должен
  отслеживать **верхнюю границу** Δ (max-with-decay: fast-attack вверх, slow-decay вниз; либо p95
  скользящего окна), не центрированное среднее. EWMA(mean)+const margin оставлял бы половину кадров
  выше mean+margin в dup-drop (джиттер Continuity 100–200ms).
- **Пессимистичный cold-start.** Инициализировать оценщик на `ceiling` (~0.5s), релаксировать вниз к
  измеренной Δ. Иначе пока он сходится от floor, self-clock угоняет `lastEmittedSlot` к wall-present →
  стартовая заморозка (с B1 — вечная). Floor = `defaultGrace(fps)` — нижняя граница для низколатентных
  лейнов. Ceiling — защита от безграничного роста при стрелле.

**Измерять Δ на всех post-anchor кадрах, включая dup.** `Δ = clockNow − CMTimeGetSeconds(
frame.ptsHostTime)`; `estimator.observe(Δ)` вызывать **после** pre-anchor guard (`slotS >= 0`), но **до**
dup-проверки (`slotS <= lastEmittedSlot`) — так dup-кадры (load-bearing для подкормки оценщика во время
заморозки) учитываются, а pre-anchor-выбросы (раздутый Δ от pts<anchor) НЕ загрязняют огибающую вверх.
НЕ повторять паттерн `lastPixelBuffer` (:665, только не-dup) — иначе оценщик слепнет ровно когда кадры
начинают dup-drop'аться (старт заморозки).

**Применять effectiveGrace в ОБОИХ потребителях grace.** Динамический grace обязан заменить
`self.graceSeconds` в обоих **call-site'ах внутри `VideoEncoder`**: `secondsUntilNextDeadline`
(`VideoEncoder.swift:528`) и `clockTick`→`catchUpHolds` (`VideoEncoder.swift:569`). Сигнатуры
`catchUpHolds` (:180) и `nextDeadlineSeconds` (:237) уже принимают `graceSeconds: Double` —
`CFRNormalizer+CatchUp.swift` **НЕ меняется** (правка только источника в двух call-site'ах). Иначе:
планировщик считает дедлайн по статическому grace, просыпается рано, `catchUpHolds` (с бо́льшим grace)
ничего не эмитит, `lastEmittedSlot` не двигается, дедлайн снова ранний → `remaining ≤ 0` → сон
пропускается → **busy-spin** на camera hot-path. Оба сайта читают `effectiveGrace` **свежим каждый цикл**
(дедлайн пересчитывается пер-тик) → смена grace между планированием и тиком ведёт к повторному сну, не к
спину (добавить инвариант-коммент в оба сайта).

**Complement — согласовать camera CFR-сетку с реально активированным fps.** `ResolvedCameraPlan.fps =
Int(CameraFormat.maxFps)` (60), но `activateFormat` пинит 1/30 для Continuity (debug-док) → сетка 60 vs
активирован 30 — **contract-mismatch**, не просто аггрегатор: вдвое режет grace-floor и удваивает холды.
T-3: привязать grid-fps к фактически активированному формату/доставке (рантайм), не к теоретическому
`maxFps`. Делать до подбора констант оценщика (grid-fps задаёт floor grace и масштаб джиттера).
Smягчает, но не заменяет основной фикс (Δ≈150ms > grace@30=66ms).

**Observability — сделать dup-drop видимым.** Заэмитить `DropEvent(reason: .cfrNormalizationDrops,
source: .encode, count: 1, detectedAt:)` на dup-drop (`ingest:618-630`), чтобы DropMonitor/tech-info
(«Нормализация CFR», `DropReportFormatter.swift:64`) перестали быть слепы. **Валидировано безопасно:**
`DropMonitor.ingest` (`DropMonitor.swift:414-418`) маршрутизирует `.cfrNormalizationDrops` как «never a
degraded-state trigger» (счётчик+лог, без latch) → ложного «Деградация: да» при Continuity не будет. Без
двойного счёта: `recordDropDup` → телеметрия `drop_dup`, новый DropEvent → tech-info (разные стоки).

## Rejected alternatives

1. **PTS-driven фронтир (вести сетку от PTS последнего ingested-кадра, не wall-clock)** — debug-док
   ставил его №1, но он **ломает stall-hold**: при настоящем простое источника входящих кадров нет →
   фронтир не двигается → синтетические холды не эмитятся → теряется само назначение wall-clock-драйвера
   (держать CFR при стрелле). grace-sizing — корректная реконсиляция: сохраняет wall-clock-драйвер,
   лишь задерживает его на латентность лейна. Устойчивость PTS-фронтира (нет cold-start/сходимости)
   достигается у grace-подхода пессимистичным init + огибающей.
2. **Обновлять `lastPixelBuffer` на dup-drop ветке** — band-aid: холды несли бы свежий контент, но кадры
   остаются в wall-clock-слотах → видео отстаёт от аудио на Δ (A/V-рассинхрон), причина не устранена.

## Affected Modules & Files

| Path | Change type | Note |
|---|---|---|
| `Onset/Encode/LatencyGraceEstimator.swift` (new) | add | pure nonisolated тип: observe(Δ) + effectiveGrace(fps); огибающая + floor/ceiling + пессимистичный init |
| `Onset/Encode/VideoEncoder.swift` | modify | держать estimator; observe(Δ) после pre-anchor guard, до dup-check (все post-anchor кадры); effectiveGrace в ОБА call-site: secondsUntilNextDeadline (:528) и clockTick→catchUpHolds (:569); emit DropEvent на dup-drop (:618-630); инвариант-коммент про пер-тик пере-чтение grace |
| `Onset/Encode/CFRNormalizer+CatchUp.swift` | verify / no-change | сигнатуры `catchUpHolds` (:180) и `nextDeadlineSeconds` (:237) уже принимают `graceSeconds: Double`; правка только источника в VideoEncoder call-site'ах |
| `Onset/Recording/Pipeline/ResolvedRecordingPlan.swift` | investigate/modify | camera grid fps по активированному формату (T-3) |
| `Onset/Recording/Pipeline/CapabilityResolver.swift` | investigate | fps-fallback (140-141) взаимодействие с T-3 |
| `Onset/Recording/Pipeline/DropReportFormatter.swift` | verify | поле «Нормализация CFR» оживёт после DropEvent |
| `OnsetTests/LatencyGraceEstimatorTests.swift` (new) | add | L2: огибающая, пессимистичный init, релакс, floor/ceiling |
| `OnsetTests/VideoEncoderTests.swift` | modify | L2 encoder-уровневый: clockTick × high-latency ingest со старта → нет вечного drop_dup, recordEncodedReal>0; dup-drop эмитит DropEvent; нет busy-spin |

## Decisions Made

1. **grace-sizing, не PTS-фронтир** — сохраняет stall-hold (см. Rejected #1). Устойчивость добирается
   огибающей + пессимистичным init.
2. **Оценщик — чистый тип, верхняя огибающая** (не actor, не EWMA-среднего) — split проекта + L2-тест +
   покрытие джиттер-хвоста.
3. **Δ на всех кадрах до ветвления; grace в обоих потребителях** — устраняет deadlock-слепоту (B1) и
   busy-spin (B2).
4. **Пессимистичный cold-start (init=ceiling, релакс вниз)** — нет стартовой заморозки by construction (B3).
5. **fps-grid match — complement** по рантайм-активированному fps (T-3), до подбора констант.
6. **Observability обязателен в этом PR** — иначе регресс снова невидим; валидировано безопасным.

## Risks & Mitigations

- **Регресс низколатентных лейнов (FaceTime built-in, Brio 4K, screen) — critical.** В steady-state
  floor=defaultGrace → grace не меняется, поведение **live-эквивалентно**. На cold-start init=ceiling
  поднимает grace для всех лейнов ~0.5s → онсет synthetic-холдов отложен, но **запись live не страдает**
  (реальные кадры идут через `catchUpThenEncode` :634, который PTS-driven и grace-независим). Mitigation:
  **no-regress L5 для всех трёх** (FaceTime built-in, Brio 4K, screen) + адресная проверка первой ~1с.
- **Busy-spin на camera hot-path — critical.** Устранён применением grace в обоих call-site'ах (B2).
  **Верифицируется L5 CPU-чеком** «CPU camera-лейна не растёт при высокой латентности» — НЕ L2
  (тест-вход `clockTick(nowSeconds:)` минует sleep-петлю `startClock`, где живёт спин).
- **Cold-start / джиттер-хвост — critical/major.** Пессимистичный init + огибающая (B3, I1).
- **A/V рассинхрон — major.** grace не меняет слот-маппинг (capture-PTS) → синхрон цел; подтвердить L5
  (губы/звук) + анализ PTS. Для записи-в-файл grace = задержка эмиссии вывода, не A/V-lag.
- **Hot-path, код из #266 (сегодня) — process.** `Onset/Encode/*` — **продуктовый код** (не meta);
  по правилам проекта auto-merge допустим **после зелёных гейтов вкл. L5 на reference-железе** (не
  owner-review). Минимальный дифф, без рефактора смежного; тройной счётчик dup НЕ консолидировать в этом PR.

## Verification & Sources

**Source of truth:** issue #268 + `swarm-report/continuity-camera-frozen-recording-debug.md` (репро +
телеметрия). **Before-state baseline (НЕ регрессировать):** Brio пишет live (4K), **FaceTime built-in
пишет live**, screen пишет live — iPhone Continuity должен СТАТЬ live.

**Testing strategy (пирамида):**
- L0 build (warnings-as-errors); L1 lint (swiftformat + swiftlint --strict).
- **L2:** (a) `LatencyGraceEstimatorTests` — огибающая (max-with-decay/p95), пессимистичный init, релакс,
  floor/ceiling, джиттер (одиночный высокий Δ покрыт, не усреднён); (b) `VideoEncoderTests`
  encoder-уровневый детерминированный — интерливинг `clockTick(nowSeconds:)` и потока high-latency
  `ingest` со старта ⇒ устойчивый `recordEncodedReal>0`, нет вечного `drop_dup`; (c) dup-drop эмитит
  `DropEvent(.cfrNormalizationDrops)`. ВАЖНО: L2 НЕ покрывает busy-spin (`clockTick(nowSeconds:)` минует
  sleep-петлю `startClock`) — спин верифицируется только L5 CPU-чеком. Чистый CFRNormalizer-тест
  слот-арифметики НЕ покрывает cold-start гонку (она в actor) — обязателен encoder-уровневый.
- **L5 (mandatory):** iPhone 11 Pro Max Continuity — детерминированный верификатор (`ffmpeg freezedetect`
  + `mpdecimate` уникальные + плотный хэш-свип, **с движением в кадре**) ⇒ live; телеметрия `drop_dup→~0`,
  `fresh→~30/с`; **снять распределение Δ** (калибровать ceiling ≥ наблюдаемого max Δ); CPU camera-лейна
  не растёт (busy-spin). **No-regress L5 для всех трёх:** Brio (4K), **FaceTime built-in**, screen остаются
  live + адресная проверка первой ~1с (cold-start) + cadence холдов на **статичном screen** (без движения)
  не зависает за ceiling. Env-gate `ONSET_RUN_L5_ENCODE=1`; подписанный билд.
  [[feedback-l5-recording-freeze-diagnosis]].

Достаточность: baseline и репро воспроизводимы (3/3); верификатор детерминированный — «done» проверяемо.

## Implementation notes (red-team resolutions — точные инструкции имплементеру)

Red-team подтвердил все типы/сигнатуры/номера строк. Точные правки (иначе не соберётся / неверная точка):
- **Точка `observe(Δ)`:** в коде единый guard `if slotS < 0 || slotS <= self.normalizer.lastEmittedSlot`
  (`VideoEncoder.swift:617`) — pre-anchor и dup в ОДНОЙ ветке; «точки между ними» нет. Реализация:
  внутри этой ветки добавить `if slotS >= 0 { estimator.observe(Δ) }` (учесть dup, исключить pre-anchor),
  И на valid-new-frame пути (после :629, до submit) тоже `estimator.observe(Δ)`. Δ считать один раз в
  начале (см. ниже). Итог: observe на всех post-anchor кадрах (dup и real), не на pre-anchor.
- **`clockNow`:** в `ingest` его НЕТ; `ContinuousClock.now` (:603) — другой тип (для telemetry). Добавить
  `let clockNow = CMTimeGetSeconds(PipelineClock.currentHostTime())` (паттерн из :524/:473). `Δ = clockNow
  − CMTimeGetSeconds(frame.ptsHostTime)`.
- **DropEvent на dup (T-4):** `DropEvent(reason: .cfrNormalizationDrops, source: .encode, count: 1,
  detectedAt: frame.ptsHostTime)` — `detectedAt` это `CMTime` (взять `frame.ptsHostTime`, как `submit`
  :744). Эмитить ТОЛЬКО при `slotS >= 0` (dup), НЕ при pre-anchor. Использовать **shared** `DropReason`
  из `PipelineTypes.swift`, НЕ локальный `CFRDropReason` (CFRNormalizer.swift:62) — одноимённый кейс,
  легко перепутать.
- **Судьба `graceSeconds`/`grace:` (blocking):** после T-2 оба call-site (:528,:569) больше не читают
  `self.graceSeconds`. Решение: **передать `grace` (init-параметр) как `floor` в `LatencyGraceEstimator`**
  (`floor = grace ?? defaultGrace(fps)`), удалить мёртвое поле `self.graceSeconds`. Тогда тесты с
  `grace: 0.0` задают floor=0 (детерминизм сохранён для floor); для детерминированной проверки cold-start/
  огибающей тест управляет потоком Δ (а не `grace:`). Зафиксировать в T-1 init estimator'а `(floor,
  ceiling)` и в T-2 — удаление поля + проброс floor.
- **Константы:** ceiling — именованная `static let` (~0.5s, обосновать комментарием; калибровать L5 по
  max Δ). Decay-алгоритм огибающей выбрать в T-1 (рекоменд.: max-with-decay, fast-attack/slow-decay по
  `observe()`; decay-rate именованной константой) — зафиксировать выбор и поведение при разреженных кадрах.
- **Docs/lint:** новый `LatencyGraceEstimator` — `missing_docs` (KDoc на тип + оба метода + хранимые
  свойства), иначе `swiftlint --strict` падает. Обновить doc-comment `drops` (`VideoEncoder.swift:221`) —
  теперь и CFR-normalization drops, не только backpressure.

## Out of Scope

- Info.plist `NSCameraUseContinuityCameraDeviceType` (на macOS 26 не требуется; опциональный hardening).
- Консолидация трёх счётчиков dup (hot-path, минимальный дифф) — отдельно.
- Глубокий рефактор CFR/clock-источника (OBS-стиль OutputPresentationTimeStamp) — отдельное упрощение.
- Desk View / Center Stage square-формат.

## Open Questions

- (non-blocking) T-3: привязка camera grid-fps к рантайм-активированному fps — решается исследованием;
  если рискует другими камерами — оставить только grace-фикс, задокументировать.
- (non-blocking) Параметры огибающей (attack/decay или окно p95), ceiling — подобрать по измеренной Δ в
  L5; обосновать комментарием. Floor = defaultGrace(fps). Решить и задокументировать в T-1: decay
  привязан к `observe()` или к времени — при разреженных кадрах (статичный screen) observe-decay может
  зависнуть grace на ceiling; для файла benign (холды эмитятся, PTS-сетка верна, лишь задержка эмиссии),
  но выбор осознанный + L5-чек cadence холдов на статичном screen.
- (non-blocking) T-1/T-2 fps-агностичны (порядок свободен); T-3 должен приземлиться **до** L5-тюнинга
  констант в T-6 (активированный fps задаёт floor grace и масштаб джиттера).
