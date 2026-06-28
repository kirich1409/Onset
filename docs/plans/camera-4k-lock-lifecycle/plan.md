---
type: plan
slug: camera-4k-lock-lifecycle
date: 2026-06-23
status: approved
spec: none
issue: 265
risk_areas:
  - device-lock-lifetime (удержание lockForConfiguration до stop — проверенный OBS-вариант)
  - actor-isolation (Swift 6, actor CameraSource; lock через teardown-пути)
  - AC-12 mic single-object lifecycle / disconnect-перехват
  - format-selection scope (cap 1080p → 4K) + preview/record разделение
  - shared budget 995M px/s (4K-камера ужимает экран) + preview-4K perf
  - L5 hardware verification (Brio, прямой USB3)
review_verdict: CONDITIONAL
review_blockers: []
---

# Plan: Камера 4K — фикс lock-lifecycle + выбор 4K-формата

## Context & Decision

Issue #265. Камера (MX Brio) не отдаёт 4K: при `device.activeFormat = 4K` формат молча реверсится
в 1080p. **Root cause установлен эмпирически** (research `swarm-report/research/research-unified-capture-backend.md`,
repro-спайк, 108/108 настоящих 4K-буферов методом OBS): причина — **преждевременный
`device.unlockForConfiguration()` до `session.startRunning()`**. AVFoundation на macOS реконсилит
`activeFormat` к дефолту сессии, если device-lock отпущен до старта. CMIO/IOKit/dext/смена фреймворка
НЕ нужны (проверено).

**Эмпирически проверены РОВНО два пути доставки 4K** (research стр.21/30/36/55):
- (a) `session.sessionPreset = AVCaptureSessionPreset3840x2160` (OBS `use_preset`-path);
- (b) `device.activeFormat = 4K` с device-lock, удержанным через `commitConfiguration` **до `stopRunning`**
  (OBS format-path).

**Decision:** идём путём (b) — `activeFormat` + удержание lock **до `stop()`** (проверенный вариант),
потому что Onset управляет CFR через `activeVideoMin/MaxFrameDuration` на конкретном формате, чего
preset-путь (a) напрямую не даёт (см. Decision 1). Снятие lock сразу после `startRunning` (до stop) —
НЕ выбираем: этот вариант research НЕ проверял (только до-stop), а приоритет проекта — стабильность,
и empiricism-non-negotiable запрещает дефолтить на непроверенную гипотезу. Дополнительно — снять cap
1080p в выборе формата на record-пути, чтобы 4K реально выбирался (иначе фикс delivery невидим).

## Technical Approach

Текущая структура (`CameraSource+SessionSetup.swift`): `device` — локальная переменная в
`addCameraInput` (стр.74), умирает после `makeCameraInput` (стр.103); `activateFormat` лочит (127) и
**разлочивает (155)** внутри `configureSession`, до `commitConfiguration` (70) и за ~24 строки до
`startRunning` (37).

**Целевая структура — удержать lock до `stop()` (вариант b), ТОЛЬКО для `role == .record`:**

0. **Скоуп hold-lock на record-роль.** `buildAndStartSession`/`activateFormat` вызываются и для
   `.preview`, и для `.record` (роль гейтит лишь `attachOutputs`, стр.202). Удержание lock до stop —
   ТОЛЬКО для `.record`; **preview сохраняет текущее поведение** (моментальный unlock после activateFormat).
   Это by-construction снимает конфликт «preview держит lock → record не возьмёт» (perf-ревью) и оставляет
   preview-путь неизменным.
1. Резолв+валидацию `AVCaptureDevice` (`AVCaptureDevice(uniqueID:)` + guard `!isSuspended`) поднять из
   `addCameraInput` в `buildAndStartSession`. `configureSession`/`addCameraInput`/`makeCameraInput`/`activateFormat`
   принимают device параметром (не создают сами).
2. В `buildAndStartSession`: `try device.lockForConfiguration()` ДО `configureSession`. `activateFormat`
   теряет внутренний lock/unlock — только `activeFormat = …` + frame-duration на уже залоченном устройстве.
   Для `.preview` lock снимается сразу после конфигурации (как сейчас); для `.record` — держится дальше.
3. **(record) Lock НЕ снимается в `buildAndStartSession`.** Залоченный `device` кладётся в bundling-struct
   `CameraCaptureShims` полем `AVCaptureDevice?` (nil для preview; НЕ 3-м associated value `.running` —
   иначе `large_tuple` lint, см. `CameraSourceHelpers.swift:20-23`; обновить doc-комментарий struct, т.к.
   device — не delegate-shim). Снятие — в teardown: `stop()`, `handleCameraDisconnect()`,
   `handleCameraSessionFault()` через единый helper `releaseRunning()`: `device?.unlockForConfiguration()` +
   `session.stopRunning()`. `unlockForConfiguration()` на отключённом устройстве — безопасный no-op (отметить).
   **Единый флаг `locked` (без `!movedToRunning`):** `var locked = true` после `lockForConfiguration()`;
   preview-ветка после ручного unlock ставит `locked = false`; record при переходе в `.running` (ownership
   к teardown) ставит `locked = false`; `defer { if locked { device.unlockForConfiguration() } }` срабатывает
   ТОЛЬКО если ни preview-unlock, ни hand-off не случились (ошибка до них) → **двойного unlock нет на всех
   путях, включая preview-error** (ранее предложенный `locked && !movedToRunning` давал двойной unlock на
   preview-throw — исправлено). AVCaptureDevice не Sendable, хранение в actor-isolated state безопасно.

> **ВАЖНО (build НЕ ловит):** раз `device` в struct, а не associated value — 4 сайта `guard case let
> .running(session, shims)` компилируются БЕЗ изменений; компилятор НЕ заставит обновить teardown.
> Корректность снятия lock держится на дисциплине `releaseRunning()` во всех 3 teardown + ревью-чеклист
> + L2-тест (error-путь и каждый teardown не оставляют lock). НЕ опираться на «build поймает».

**Инвариант (load-bearing, комментарий в коде):** между `lockForConfiguration` и переходом в `.running`
синхронный регион configure→startRunning НЕ должен содержать `await` (сейчас тело синхронно с т.з. actor:
`await` только в `@Sendable`-замыканиях `onDisconnect`/`onSessionFault`, исполняемых позже). `await` в этом
регионе растянул бы lock через приостановку actor и открыл reentrancy/deadlock со `stop()`.

**Вариант-fallback:** если L5 покажет, что hold-до-stop почему-то не доставляет 4K на референс-железе —
переключиться на preset-путь (a). Оба проверены; (b) выбран дефолтом по CFR-контролю.

## Affected Modules & Files

| Path | Change | Note |
|---|---|---|
| `Onset/Recording/Capture/CameraSource+SessionSetup.swift` | edit | Поднять resolve+lock в buildAndStartSession; убрать lock/unlock из activateFormat; hold-до-stop ТОЛЬКО для .record (preview — моментальный unlock) |
| `Onset/Recording/Capture/CameraSource.swift` | edit | teardown (`stop`/`handleCameraDisconnect`/`handleCameraSessionFault`) снимают lock через `releaseRunning()`; обновить ВСЕ матчи `.running` |
| `Onset/Recording/Capture/CameraSourceHelpers.swift` | edit | `device` положить в bundling-struct состояния `.running` (НЕ 3-й tuple-член — `large_tuple` lint, см. стр.20-23); затронет 4 сайта матча `.running`: `CameraSource.swift` stop:206 / disconnect:222 / fault:243 / sessionHandle:260 |
| `Onset/Recording/Capture/CameraFormatSelector.swift` | edit | Добавить параметр `allowAboveFullHD: Bool = false` в `pickBestFormat`/`bestSixteenByNineFormat`; при true — снять cap `fullHDMaxHeight` (стр.41,94-102), выбрать макс 16:9 (4K). Default false СОХРАНЯЕТ текущее ≤1080p поведение. Обновить KDoc #145 AC-5 (стр.13-23): «≤1080p по умолчанию; record opt-in выше» |
| `Onset/UI/Main/MainViewModel+Record.swift` | edit | record-вызов `pickBestFormat` (стр.91) передаёт `allowAboveFullHD: true` |
| `Onset/UI/Main/MainViewModel+Preview.swift` | verify | preview-вызов (стр.86) — default false → ≤1080p, изменений не требует (подтвердить) |
| `Onset/UI/Main/MainViewModel+Devices.swift` | verify | 3-й caller `pickBestFormat` (стр.259, availability) — default false, поведение не меняется (подтвердить, что для UI-доступности этого достаточно) |
| `OnsetTests/CameraFormatSelectorTests.swift` | edit | Существующие тесты (`fourKLosesToFullHD`:59-68, `realisticMixPicksFullHD`:192-205, `allSixteenByNineAboveFullHDPicksSmallest`:89-100, `allAboveFullHDSameResolutionPicksHigherFps`:102-114) тестируют DEFAULT (false) — остаются валидны; ДОБАВИТЬ кейсы `allowAboveFullHD:true` → 4K выбирается |
| `Onset/Encode/EncoderConfigBuilder.swift` + bitrate-таблица (`RecordingConfiguration`) | verify/edit | Есть ли запись битрейта под 4K; нет → добавить или явно отложить с обоснованием (placeholder-bitrate — pre-existing) |
| `Onset/Recording/Pipeline/CapabilityResolver.swift` | verify/edit | НЕ cap (cap в селекторе) — резолвер делит бюджет 995M px/s по advertised maxFps (conservative); зафиксировать поведение при 4K-камере (Decision 3, T-6) |
| `OnsetTests/CameraSource4KDeliveryL5Tests.swift` | **create** | Файла НЕТ — создать с нуля: ассерт delivered 3840×2160 + дропы/битрейт на Brio (L5) |
| `OnsetTests/CameraSourceLogicTests.swift` | edit | `:353` строит `.running(session:shims:)` явно → обновить под новую struct-форму; `:656` — caller `pickBestFormat` (default-параметр, проверить) |
| `OnsetTests/RecordingSessionTests.swift` | verify | `:1488/:1856` — callers `pickBestFormat` (default false, не сломаются); подтвердить |

## Decisions Made

1. **activeFormat+hold-до-stop (b), не preset (a):** preset-путь (a) проверен и проще (не нужен
   lock-танец), но Onset задаёт CFR через `activeVideoMin/MaxFrameDuration` на конкретном формате
   (`activateFormat:141-153`) — preset напрямую этого не даёт. Выбираем (b); (a) — задокументированный
   fallback. Молча не выбираем (code-policies): trade-off назван — CFR-контроль vs простота.
2. **Удержание lock до `stop()` (только record), НЕ снятие после старта:** research проверил доставку
   4K ровно при удержании до `stopRunning` (вариант b/var5). Снятие сразу после `startRunning` — НЕ
   тестировалось; дефолтить на него = armchair-инференс, нарушает empiricism-non-negotiable. Lock живёт
   record-сессию, снимается в teardown. **Только role==.record** — preview сохраняет моментальный unlock,
   чем by-construction снимается конфликт preview/record за device-lock (perf-ревью). Concurrency-штрафа
   нет: lock device-level; между стартом и stop actor свободен; teardown снимает детерминированно.
3. **Cap-lift через параметр `allowAboveFullHD: Bool = false`, opt-in только record:** cap =
   `fullHDMaxHeight` в `bestSixteenByNineFormat`. Вместо глобального снятия — параметр с default=false,
   сохраняющим текущее ≤1080p поведение для preview (`+Preview:86`) и device-availability (`+Devices:259`);
   record (`+Record:91`) передаёт true. Это: (а) не тянет 4K в preview (GPU/память); (б) **сохраняет
   валидными существующие тесты селектора** (они тестируют default-путь), нужны лишь НОВЫЕ кейсы для
   true. Cross-effect бюджета: `CapabilityResolver` считает камеру в общий 995M px/s по advertised maxFps
   (conservative over-downscale, безопасная сторона); 4K-камера (~249M px/s @30) vs 1080p (~62M) →
   `downscaleIfNeeded` может ужать ЭКРАН в screen+camera. Решение: проверить L2 (4K+4K → экран не ужат
   неожиданно или поведение принято явно) — T-6.
4. **fps-фильтр `maxFps >= minCameraFps` проходит для 4K Brio:** спайки (cmio_probe/capture_repro) показали,
   что 4K-формат Brio анонсируется как `3840×2160 420v @30` — `maxFrameRate=30` проходит строгий `>=30`.
   T-4 acceptance это подтверждает на реальном устройстве; если другой Brio/прошивка анонсит 4K@<30 или
   29.97 — понизить порог `minCameraFps` или ослабить фильтр (NTSC-tolerance). Реальная доставка ~25fps
   не влияет на выбор (фильтр смотрит advertised maxFrameRate).
5. **Pixel format 420v** уже запрашивается явно (`videoSettings`, стр.204-205) — подтвердить, не менять.

## Risks & Mitigations

- **Утечка lock на error-пути старта** → явный `defer { if locked && !movedToRunning { unlock } }` в
  `buildAndStartSession`; после перехода в `.running` ответственность переходит teardown-путям. Проверить:
  throw-путь (`sessionDidNotStart`) и stop-during-start не оставляют устройство залоченным.
- **Lock не снят в одном из teardown-путей** → unlock во ВСЕХ трёх (`stop`, `handleCameraDisconnect`,
  `handleCameraSessionFault`); единая точка (helper `releaseRunning()`), чтобы не забыть. Idempotent stop.
- **Budget: 4K-камера ужимает экран** (Decision 3) → L2 на `CapabilityResolver` + L5 проверяет
  комбинированный screen+camera выход, не только камеру.
- **Preview-4K perf** → cap-lift скоупится на record-путь, preview ≤1080p (Decision 3).
- **AC-12 (mic single-object)** → mic-input НЕ лочится (addMicInput независим, Explore подтвердил);
  удержание camera-lock дольше mic-путь не ломает. Mitigation: прогнать disconnect-тесты.
- **actor reentrancy при `await` в lock-регионе** → инвариант-комментарий «no await между lock и .running»
  (Technical Approach). Build не ловит — защита через комментарий + review.
- **startRunning() залипнет с удержанным lock** → пре-существующий риск (startRunning уже блокирует actor);
  удержание lock его не усугубляет принципиально (teardown в очереди actor разрулит после возврата start).

## Verification & Sources

**Источник истины:** issue #265 + research-доку (`swarm-report/research/research-unified-capture-backend.md`).
Bug-fix, контракт = «4K реально доставляется».
**Before-state baseline (durable):** зафиксирован в research-доку — «при раннем unlock доставляется
1080p (ревёрт)», подтверждено спайком `capture_delivery.swift`. Спайки лежат в gitignored `scratchpad/`
(эфемерны) — durable свидетель = текст research-доку; на него и ссылаемся, НЕ на отсутствующий тест.
After-state: 3840×2160 доставляется. Baseline достаточен (red→green по разрешению задокументирован).

**Testing strategy (пирамида):**
- **L0 Build** — strict-concurrency сборка проходит.
- **L1 Lint** — swiftformat/swiftlint clean.
- **L2 Unit** — (1) `CameraFormatSelector`: устройство с 4K → выбран 4K, без 4K → макс доступный;
  (2) `CapabilityResolver`: 4K-дисплей+4K-камера → экран не ужимается неожиданно (или поведение принято);
  (3) lock-lifecycle инвариант, если выразим через seam/fake (teardown снимает lock, error-путь не течёт).
- **L5 (ОБЯЗАТЕЛЬНО, real hardware)** — Brio, **ПРЯМОЙ USB3** (хаб режет до 1080p!),
  `-testPlan Onset-L5`/`ONSET_RUN_L5_CAPTURE=1`: новый `CameraSource4KDeliveryL5Tests` ассертит delivered
  = 3840×2160; `scripts/verify-cfr.sh` на реальном выходе (ожидаемо ~24-25fps — hardware Brio, это ОК);
  проверить screen+camera комбинированный выход (экран не деградировал неожиданно). Перед прогоном
  `pgrep -la Onset`→`pkill -9 Onset`; убедиться, что Logi Options+/RightSight не держит камеру.

## Out of Scope (known constraints)

- **60fps** — hardware-cap Brio (~24-25fps при cap формата 30); #178 закрыт как hardware-constraint.
- **HDR с камеры** — «HDR» Brio = RightLight 5 (внутренняя SDR-обработка 8-bit), не захватываемый сигнал
  (офиц. Logitech + deep-research). Вне скоупа.
- **4K в preview** — preview остаётся ≤1080p (Decision 3); 4K-preview — отдельное решение при необходимости.
- **User-facing пикер режимов камеры (4K/1080p в UI)** — UI-дизайн (агенты UI не проектируют); здесь
  только авто-выбор макс-формата на record-пути. Пикер — отдельный issue + бриф на дизайн.
- **preset-путь (a) как дефолт** — задокументированный fallback, не основной; переключение только если
  (b) не подтвердится на L5.
- **CMIO/IOKit/dext/унифицированный swappable capture-слой** — не нужны (research). **HDR/4K экрана** — #169.

## Open Questions

- (resolved) Место cap 1080p — `CameraFormatSelector.bestSixteenByNineFormat` (`fullHDMaxHeight`,
  стр.41/94-102). НЕ в `CapabilityResolver`.
- (non-blocking, → T-6) Считать camera pixel-rate в бюджете по advertised `maxFps` или по реально
  доставляемому (~25 у Brio) — влияет на агрессивность downscale экрана. Решить при правке `CapabilityResolver`.
