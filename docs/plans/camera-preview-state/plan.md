---
type: plan
slug: camera-preview-state
date: 2026-06-21
status: approved
spec: none
risk_areas: [perf-critical]
review_verdict: pass   # 3 review cycles (type-design+ux+perf) + red-team; all blockers resolved & incorporated
review_blockers: []
---

# Plan: Превью камеры — модель состояния, таймаут подключения, VoiceOver-анонсы

## Context & Decision

Три отложенных follow-up из PR #253 (плейсхолдер превью камеры), все решены и зафиксированы в issue:

- **#254** (type-design/altitude, P2/S) — заменить пару полей `previewHandle: SessionHandle?` + `previewFailed: Bool` единым enum `CameraPreviewState`. Ревьюеры отметили fragile-altitude: `previewFailed` пишется в 4 разбросанных местах с неочевидным двойным сбросом.
- **#255** (ux, P2/S, зависит от #254) — ограничить «вечный спиннер» при медленном-но-идущем подключении (Continuity: iPhone заснул/ушёл из сети в процессе) мягким таймаутом.
- **#256** (a11y, P2/XS, зависит от #254) — постить VoiceOver-анонс при смене состояния превью; сегодня `.updatesFrequently` не озвучивает переход для несфокусированного пользователя.

Это HOW для уже принятых решений. Источник истины — три issue (отдельного spec нет). Для #254 (рефактор «1:1») baseline истины — существующие зелёные тесты.

## Technical Approach

### Текущее состояние (карта кода)

Состояние превью сегодня — неявный автомат на паре полей `MainViewModel`:
- `previewHandle: SessionHandle?` (`MainViewModel.swift:339`), `previewFailed: Bool` (`:346`).
- Предикаты: `cameraPlaceholderPending = isCameraActive && previewHandle == nil` (`:242`), `isCameraConnecting = cameraPlaceholderPending && !previewFailed` (`:253`), `isCameraActive = activeCamera != nil` (`:233`).
- Все переходы — в `MainViewModel+Preview.swift`: `managePreview` (`:33-70`: `previewFailed=false` на входе `:36`, `=true` на unplug-guard `:49` и build→nil `:55`), `buildAndStartPreview` (`:83-116`: `previewHandle=…` `:112`), `stopCurrentPreview` (`:73-79`: `previewHandle=nil` `:77`, `previewFailed=false` `:78`).
- Читатели — `MainView+Sections.swift`: gate `isCameraActive` (`:100`), `cameraPlaceholderPending` (`:102,118`), `previewHandle`→representable (`:107`), `previewFailed`→label/icon (`:150-169`), `activeCamera?.isContinuityCamera`→copy (`:149`).
- `SessionHandle` = `nonisolated struct { let session: AVCaptureSession }` (`CameraSourceHelpers.swift:42`), **не Equatable**.

### #254 — enum как единственное хранилище, предикаты без изменений (Option A)

Новый тип в отдельном файле `Onset/UI/Main/CameraPreviewState.swift` (doc-комментарии — `missing_docs`):

```swift
/// Состояние ПРОГРЕССА подключения превью камеры. Заменяет нелегальную комбинацию
/// (previewHandle установлен И previewFailed==true) одним исчерпывающим перечислением.
/// NB: `isCameraActive` (cameraEnabled && selectedCamera) — НЕЗАВИСИМАЯ ось by design,
/// в enum не сворачивается (см. Decisions). Кейсы .idle/.connecting/.connectingSlow
/// различимы только для #255/#256; для предикатов #254 различает лишь live vs failed vs прочее.
enum CameraPreviewState {
    case idle               // превью не запущено (камера выключена ИЛИ teardown)
    case connecting         // попытка подключения идёт (валидная камера, хендла ещё нет)
    case connectingSlow     // #255: порог превышен, всё ещё пытаемся (не терминальное)
    case live(SessionHandle)
    case failed             // явный сбой старта / hot-unplug (терминальное до пере-выбора)
}
```

`MainViewModel` хранит одно поле `var previewState: CameraPreviewState = .idle`. Поля `previewHandle`/`previewFailed` становятся **get-only computed-мостами** (через `if case`, без `==`):

```swift
var previewHandle: SessionHandle? { if case let .live(h) = previewState { h } else { nil } }
var previewFailed: Bool { if case .failed = previewState { true } else { false } }
// #255: третий (additive) мост — вью иначе не отличит slow от обычного connecting
// (оба схлопываются в handle==nil && !failed). Не влияет на 1:1: ветвь slow срабатывает
// только в новом состоянии .connectingSlow.
var previewIsConnectingSlow: Bool { if case .connectingSlow = previewState { true } else { false } }
```

Существующие предикаты (`cameraPlaceholderPending`, `isCameraConnecting`, `isCameraActive`) и **все** read-sites во вью остаются дословно — теперь читают мосты. `.idle` и `.connecting`/`.connectingSlow` все дают `previewHandle==nil && !failed` → `isCameraConnecting`/`cameraPlaceholderPending` ведут себя как до рефактора (в т.ч. транзиентный кадр `isCameraActive==true && .idle` до старта `.task` даёт `isCameraConnecting=true`, как раньше). Это и есть провабельное 1:1.

**Полная миграция write-sites (get-only мосты ⇒ мигрируют ВСЕ присваивания, не «3 метода»).** Verified repo-wide (гейт исчерпанности — grep ниже, не число строк):

| Site | Старое | Новый таргет | activeCamera |
|---|---|---|---|
| `+Preview.swift:36` (вход managePreview) | `previewFailed=false` | поглощается `stopCurrentPreview→.idle`; отдельного write нет | — |
| `+Preview.swift:38-41` deselect-guard | `previewGeneration+=1` | остаётся `.idle` (после stopCurrentPreview), gen++ | nil |
| `+Preview.swift:49` hot-unplug-race | `previewFailed=true` | `.failed` (синхронно, до await — clobber не грозит) | non-nil |
| `+Preview.swift` после guard'ов (новый) | — | `.connecting` (бамп `previewAttempt` ровно раз перед этим) | non-nil |
| `+Preview.swift:55` build→nil | `previewFailed=true` | `.failed` (гейт `attempt == previewAttempt`) | non-nil |
| `+Preview.swift:66` teardown (post-park) | `previewHandle=nil` | `.idle` (под guard `previewSource===source`) | non-nil |
| `+Preview.swift:77-78` stopCurrentPreview | `previewHandle=nil; previewFailed=false` | `.idle` | — |
| `+Preview.swift:112` success | `previewHandle=…` | `.live(handle)` (гейт `previewSource===source` И `attempt==previewAttempt`) | non-nil |
| `+Record.swift:118` teardown-перед-записью | `previewHandle=nil` | `.idle` (камера ещё активна, превью снято под device-contention) | non-nil |
| watchdog (новый, #255) | — | `.connecting → .connectingSlow` (гейт `attempt == previewAttempt`) | non-nil |

`.connecting` ставится **ПОСЛЕ guard'ов** cameraID и camera-lookup (валидная камера в руках), **не на входе** managePreview — иначе deselect/hot-unplug вернули бы `.connecting` без камеры (type-design finding). `previewGeneration`/`previewSource` не трогаем — отдельная ответственность.

**Дискриминирующий гейт 1:1:** после рефактора repo-wide `grep -nE '\bpreview(Handle|Failed)\s*=' Onset/ OnsetTests/` (исключая определения мостов) → **0 присваиваний**. Три теста присваивают напрямую и входят в migration set (переписать на `previewState`): `MainViewModelCameraToggleTests.swift:653` (`previewHandle=SessionHandle(...)` → `previewState=.live(...)`), `:663` (`previewFailed=true` → `.failed`), `MainViewModelTests.swift:290` (`previewFailed=true` → `.failed`). Утверждение «без правок» относится только к ассертам существующих connecting/placeholder-тестов (поведение), не к их setup.

**Почему НЕ буквальный rewrite предикатов из issue** (`isCameraConnecting → previewState == .connecting`): сломал бы транзиентный кадр `.idle`-while-active (мигание live-слоя с nil-handle). Issue требует «1:1» → 1:1 выигрывает; формулировка issue про предикаты не выполняется намеренно.

### #255 — мягкий таймаут через `.connectingSlow` (attempt-id + identity gated, structured)

Вводится **выделенный attempt-id** `previewAttempt: Int` (НЕ переиспользуем `previewGeneration` — у него другая каденция бампа: `stopCurrentPreview` его не бампит, плюс он драйвит `.id()` пересоздания NSView, type-design finding). `previewAttempt` бампается ровно один раз на входе в попытку (после guard'ов, перед `.connecting`). После установки `.connecting` запускается watchdog, **структурно привязанный** к попытке, с захватом `attempt`:

```swift
// seam + порог объявлены на MainViewModel (init-параметры, как существующие closure-seam'ы):
//   let connectSleep: @Sendable (Duration) async throws -> Void   // default { try await Task.sleep(for: $0) }
//   nonisolated func connectTimeout(isContinuity: Bool) -> Duration  // именованные константы (Continuity > builtin)

self.previewAttempt += 1
let attempt = self.previewAttempt        // (а) НЕТ await между bump и capture
self.previewState = .connecting
let threshold = self.connectTimeout(isContinuity: camera.isContinuityCamera)  // вычислить ДО группы (не захватывать camera в @Sendable addTask)
let source = await withTaskGroup(of: Void.self) { group in   // отменяется родительским .task(id:)
    group.addTask { await self.runConnectWatchdog(threshold: threshold, attempt: attempt) }
    let s = await self.buildAndStartPreview(for: camera, attempt: attempt)  // .live(handle) под identity+attempt-гейтом
    group.cancelAll()
    return s
}

func runConnectWatchdog(threshold: Duration, attempt: Int) async {
    do { try await self.connectSleep(threshold) } catch { return }   // CancellationError → выход
    guard attempt == self.previewAttempt, case .connecting = self.previewState else { return }
    self.previewState = .connectingSlow
}
```

`buildAndStartPreview` получает новый параметр `attempt: Int` (для гейта `.live`/`.failed`). `withTaskGroup(of: Void.self)` возвращает `CameraSource?` — тип группы выводится из `return s` (прецедент `+Devices.swift:30`). Полный новый `managePreview` реконструируется из текущего `:54-69` (guard→group→park→teardown) — фрагмент выше показывает только connect-окно.

Барьеры против cross-talk (type-design + perf конвергенция: watchdog A портил состояние камеры B). **Нагрузку несёт attempt-гейт; остальные два сами по себе дырявы:**
1. **Attempt-id гейт** `attempt == self.previewAttempt` (LOAD-BEARING) — каждая попытка бампит счётчик ровно раз; watchdog A с `attempt_A` не пройдёт против `previewAttempt == attempt_B`. Закрывает узкое окно «sleep watchdog A завершился ровно в момент переключения на B»: completed-sleep continuation выполняется до того, как cancellation отменит уже-завершённый child → структурная отмена (барьер 2) его НЕ ловит. State-гейт (барьер 3) тоже НЕ ловит — B в этот момент тоже `.connecting`.
2. **Структурная привязка** (`withTaskGroup` в scope managePreview) — отмена родительского `.task(id:)` пропагируется в watchdog; нет долгоживущего детач-Task. Покрывает общий случай, не узкое окно.
3. **State-гейт** `if case .connecting` — защита от перетирания уже наступивших `.live`/`.failed`; недостаточен против cross-talk (см. выше).

`.live`-присваивание в `buildAndStartPreview` гейтится по **identity** `previewSource === source` **И** `attempt == previewAttempt`: identity закрывает персистентный clobber (suspended `start()` камеры A резюмится после старта B → `previewSource === sourceB ≠ sourceA` → skip; паттерн уже на `+Preview.swift:64`); attempt-гейт дополнительно закрывает краткое окно, где корректность identity иначе опиралась бы на необъявленный FIFO-порядок continuation на акторе `CameraSource` (perf hardening). Late-handle promotion не ломается: slow-but-no-switch путь не бампит новый attempt → оба гейта проходят. `.failed` после build-nil (`:55`) гейтится по `attempt == previewAttempt` (source там nil). NB: `.live`/`.failed`-clobber — латентная гонка существующего кода (writes :49/:55/:112 не гейтятся сегодня); рефактор её закрывает попутно тем же паттерном `:64`.

**Code-инварианты (хрупкие, зафиксировать в acceptance):** (а) между `previewAttempt += 1` и `let attempt = previewAttempt` — НИКАКОГО `await` (иначе B перебьёт attempt до захвата A); (б) `previewSource = source` присваивается ДО `await source.start()`. `sleep` — инъектируемый seam (`Clock`/closure), чтобы порядок timeout-vs-build в L2 был **детерминированным**, а не таймингозависимым.

Порог — именованные константы по типу устройства (Continuity ~10 с / встроенная/USB ~5 с, `connectTimeout(isContinuity:)`). `.connectingSlow`: спиннер сохраняется (не error-icon), `cameraPlaceholderPending`/`isCameraConnecting` остаются true (мосты). **Вью различает slow через новый мост** `previewIsConnectingSlow`: `cameraPlaceholderLabel` (`MainView+Sections.swift:148-154`) получает третью ветку (slow → recovery-guidance copy), сегодня ветвится только по `previewFailed`. **Соединение НЕ отменяется** — поздний хендл всё ещё промотируется `.connectingSlow → .live` (покрыть тестом late-handle).

Copy для `.connectingSlow` обязана нести **recovery-guidance** (что сделать: «разбудите iPhone / поднесите ближе»), не только статус (ux finding: иначе «мягкий» = вечный спиннер с другим текстом). Финальные формулировки — бриф пользователю (UI-копирайт агентами не финализируется). Второй, более длинный порог `.connectingSlow → .failed` с явным retry — см. Out of Scope (опционально, вне MVP-скоупа #255).

### #256 — VoiceOver-анонс: политика постинга + текст (две чистые функции)

Текст — недостаточный contract: реальные a11y-баги (спам, дедуп, приоритет) живут в **решении постить ли**, а не в тексте. Поэтому ДВЕ чистые функции (обе табличные L2):

```swift
/// Решение о постинге при переходе. nil = не озвучивать (подавление спама).
nonisolated func previewAnnouncement(from old: CameraPreviewState,
                                     to new: CameraPreviewState,
                                     isContinuity: Bool) -> PreviewAnnouncement?
struct PreviewAnnouncement { let text: String; let isHighPriority: Bool }
```

Политика (ux finding — суб-секундный `connecting→live` спамил «Подключение… Подключено»):
- `→ .connecting`: **nil** (визуальный спиннер + on-focus label покрывают старт; не озвучиваем, чтобы не спамить на быстром connect).
- `→ .connectingSlow`: текст со статусом + guidance, обычный приоритет.
- `→ .live`: «Камера подключена», обычный приоритет (одиночный анонс, не пара — спама нет, т.к. connecting не озвучивался).
- `→ .failed`: текст как видимый label (включая hot-unplug/disconnected — зеркалит `cameraPlaceholderLabel`/`disconnectedCameraName`), **высокий приоритет/interrupt** (прерывает висящий connectingSlow-анонс).
- `→ .idle`: nil.

Постинг на **call-sites переходов** (НЕ `didSet` — он требовал бы Equatable). `AccessibilityNotification.Announcement(_:).post()` (Accessibility framework, macOS 14+, MainActor). **Приоритет/interrupt:** если SwiftUI/`AttributedString.accessibilitySpeechAnnouncementPriority` не экспонирует приоритет на macOS 26 — fallback `NSAccessibility.post(element:notification:userInfo:[.priority: NSAccessibilityPriorityLevel])`. Помечено как API-verify (L5/SDK), не утверждённый факт.

**Сопутствующее (ux finding):** при добавлении анонсов убрать трейт `.accessibilityAddTraits(.updatesFrequently)` с оверлея (`MainView+Sections.swift:179`) — он даёт повторное чтение для сфокусированного пользователя поверх анонса (двойное озвучивание); **сохранить** `.accessibilityLabel` (on-demand чтение текущего состояния).

**Единый источник текста (red-team finding):** `cameraPlaceholderLabel` сегодня — `private var` во `MainView`, а маппер — `nonisolated` на VM; чтобы текст анонса реально совпадал с видимой подписью (а не дублировал её строки, рискуя разойтись), логика подписи извлекается в **общий nonisolated pure helper** (state + isContinuity + disconnectedName → String, паттерн `MenuBarLabelMapper`); и `cameraPlaceholderLabel` во вью, и `previewAnnouncement` читают его. `cameraPlaceholderLabel` становится тонкой обёрткой над helper'ом.

**PII:** текст анонса == видимый label (теперь буквально единый источник); это user-facing UI, не лог — имя устройства в произносимом тексте допустимо ровно в той мере, в какой оно уже на экране. Запрет PII в `os.Logger` (имена устройств) остаётся неизменным; новых device-name в логи не добавляем.

### Disconnect живой камеры — отдельная поверхность, отдельный анонс

Verified в коде (исправляет ошибочную посылку): доминирующий disconnect-флоу — `+Devices.swift:145-148` `.disconnected(name)` ставит `selectedCameraID = nil` → `activeCamera == nil` → блок `cameraPreview` демонтируется (`MainView+Sections.swift:100`), `managePreview(nil)` → `.idle`, анонс по политике = **nil**. Параллельный notice рисует `CameraUnavailableRow` (`:364-391`) — только статический `.accessibilityLabel`, **без анонса**. Значит `.failed`-путь disconnect НЕ покрывает (он требует, чтобы cameraID остался выставлен) — для основного флоу disconnect остаётся **silent** для несфокусированного VoiceOver. Новый enum-кейс не нужен (disconnect — device-selection state, не preview-state), но **нужен отдельный анонс**:

- **Механизм (red-team finding — НЕ глобальный `didSet`):** `disconnectedCameraName` имеет 6 write-sites в 3 методах (`+Devices.swift:136/142/148`, `MainViewModel.swift:156`/`:289`/`:309`); `didSet` выстрелил бы и на user-deselect/clears. Поэтому — **явный вызов анонса точечно** в `case .disconnected(name)` внутри `loadCamerasAndMicrophones` (`+Devices.swift:145-148`), единственная точка реального live-unplug. Сайты :156/:289/:309 (picker→nil, enableCamera stale-pick) НЕ анонсят.
- **Session-live дискриминатор (новое stored-свойство):** объявить `private var hasObservedPresentCamera = false` на `MainViewModel`, ставить true там, где камера наблюдается present/active (в том же `loadCamerasAndMicrophones`, ветка present). Анонс disconnect — только если флаг true → при запуске с сохранённой-но-отсутствующей камерой (флаг ещё false) спурьёзного «<Камера> отключена» нет. Текст «<Камера> отключена» зеркалит видимый `CameraUnavailableRow`-label.

Так VoiceOver-сигнал отключения существует для живого unplug, но не звучит ложно при старте. (Фокус-менеджмент при демонте превью и mic-disconnect-анонс — вне скоупа, см. Out of Scope.)

## Affected Modules & Files

| Path | Change | Note |
|---|---|---|
| `Onset/UI/Main/CameraPreviewState.swift` | New | enum 5 кейсов + чистые: общий label-helper (state+isContinuity+disconnectedName→String), `previewAnnouncement(from:to:isContinuity:)`, `connectTimeout(isContinuity:)`; `PreviewAnnouncement` |
| `Onset/UI/Main/MainViewModel.swift` | Modified | `previewState` хранилище; get-only мосты `previewHandle`/`previewFailed`/`previewIsConnectingSlow`; предикаты без изменений; (#255) `previewAttempt` + `connectSleep`-seam (init-параметр); (#256) `hasObservedPresentCamera` флаг |
| `Onset/UI/Main/MainViewModel+Preview.swift` | Modified | enum-переходы (по таблице); (#255) structured watchdog (`withTaskGroup`) + `attempt`-гейт на `.connectingSlow`/`.failed`, identity-гейт `previewSource===source` на `.live`; (#256) `.post()` на переходах |
| `Onset/UI/Main/MainViewModel+Devices.swift` | Modified | (#256) анонс на переходе `disconnectedCameraName` nil→non-nil (disconnect live-камеры) |
| `Onset/UI/Main/MainViewModel+Record.swift` | Modified | site :118 `previewHandle=nil` → `previewState = .idle` (4-й write-site) |
| `Onset/UI/Main/MainView+Sections.swift` | Modified | (#255) copy+recovery-guidance для `.connectingSlow` (спиннер сохраняется); (#256) убрать `.updatesFrequently` (:179), сохранить `.accessibilityLabel` |
| `OnsetTests/MainViewModelCameraToggleTests.swift` | Modified | migration: `:653`→`previewState=.live(...)`, `:663`→`.failed` |
| `OnsetTests/MainViewModelTests.swift` | Modified | migration: `:290`→`.failed`; новые тесты: мост, connecting→slow (детерм. seam), late-handle→live, gen-гейт cross-talk, маппер политики; существующие connecting/placeholder **ассерты** без правок |
| `docs/architecture.md` | Modified | модель состояния превью камеры в том же PR |

## Decisions Made

| Decision | Rationale | Alternatives rejected |
|---|---|---|
| Option A: enum как хранилище + get-only мосты, предикаты и read-sites дословно | Провабельное 1:1; ассерты существующих тестов без правок; реальная жалоба ревью (4 разбросанных `previewFailed`) устранена | Буквальный rewrite предикатов из issue (`isCameraConnecting → ==.connecting`) — ломает транзиентный `.idle`-while-active кадр (мигание), нарушает «1:1» |
| Честная рамка: enum устраняет ОДНУ нелегальную комбинацию (handle set И failed); `isCameraActive` остаётся независимой осью | type-design finding: не оверселить «illegal states unrepresentable»; `isCameraActive` 1:1-ограничением сворачивать нельзя | Сворачивать `isCameraActive` в enum — нарушает 1:1, добавляет рассинхрон |
| enum БЕЗ Equatable; `if case` везде | `SessionHandle` не Equatable (обёртка над `AVCaptureSession`); обходит enum/MainActor `==` gotcha | Equatable + nonisolated `==` witness — лишний boilerplate; identity-Equatable для дедупа SwiftUI не нужен (`.live` ставится один раз за попытку + gen-гейт) |
| #255 мягкий таймаут: `.connectingSlow`, без отмены соединения; поздний хендл → `.live` | Continuity может прийти позже; issue: «всё ещё подключаюсь»; пере-выбор = ручной retry | Жёсткий таймаут → `.failed` + cancel — бросает соединение, которое могло бы успеть |
| Watchdog: structured `withTaskGroup` + выделенный **`previewAttempt`**-гейт на flip; `.live` гейтится по **identity** `previewSource===source` | type-design+perf конвергенция (critical): gen-гейт несостоятелен — `stopCurrentPreview` не бампит `previewGeneration`, каденции расходятся, A и B захватывают один gen; `previewGeneration` уже несёт `.id()`-ответственность. attempt-id = чистый per-attempt identity; identity для `.live` держится независимо от тайминга | gen-гейт (несостоятелен); голый `Task{}`+`defer cancel` (не отменяется родителем); переиспользовать `previewGeneration` (смешивает два инварианта с разной каденцией) |
| `sleep` инъектируется как seam (Clock/closure), не только значение порога | perf finding: голая инъекция порога оставляет реальный `Task.sleep` → флак L2; детерминированный порядок timeout-vs-build | Инъекция только значения — недетерминированный тест |
| #256 ДВЕ чистые функции: политика постинга `previewAnnouncement(from:to:)` + текст; `.post()` на call-sites | ux finding (critical): табличный тест только текста нефальсифицируем — баги (спам/дедуп/приоритет) в политике; `connecting` не озвучивается (анти-спам) | Один text-маппер — не тестирует «постить ли»; `didSet`-дедуп требует Equatable |
| Disconnect: новый enum-кейс не нужен, но нужен ОТДЕЛЬНЫЙ анонс на `disconnectedCameraName` nil→non-nil | verified: disconnect нилит `selectedCameraID` → `.idle` (анонс nil), `CameraUnavailableRow` молчит → иначе silent для VoiceOver | `.failed`-анонс покрывает disconnect (ОПРОВЕРГНУТО кодом — `.failed` не наступает); отдельный `.disconnected` кейс (дублирует device-selection поверхность) |
| Один branch/PR `feature/camera-preview-state`, закрывает #254/#255/#256, покоммитно T-1..T-4 | Один малый связный набор файлов; T-1 (рефактор) остаётся отдельным коммитом, корректность = неизменённые ассерты | Три stacked-PR — оверхед; один коммит — размывает proof рефактора |

## Risks & Mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| Watchdog cross-talk: таймаут камеры A портит состояние камеры B при быстрой смене | critical | Выделенный `previewAttempt`-гейт на flip (+ structured `withTaskGroup` + state-гейт); `.live` гейтится по identity `previewSource===source`; тест на реальном A→B device-switch пути (не ручной счётчик) |
| Неполная миграция write-sites (get-only мосты) → не компилируется | critical | Полный verified-список 9 сайтов в таблице; 3 теста в migration set; дискриминирующий гейт repo-wide grep `\bpreview(Handle\|Failed)\s*=` → 0 |
| Нефальсифицируемая a11y-acceptance (тест текста, не политики) | critical | Отдельная чистая `previewAnnouncement(from:to:)` (политика постинга) + табличный тест включая `connecting→live`<1с → nil |
| Flaky таймаут-тест (реальное время `Task.sleep`) | major | Инъектируемый `sleep`-seam (Clock/closure) → детерминированный порядок timeout-vs-build; живой slow-Continuity — best-effort L5 |
| Спам VoiceOver на быстром `connecting→live` | major | Политика: `connecting` не озвучивается; одиночный `live`-анонс |
| Двойное озвучивание (`.updatesFrequently` + announcement) | major | Убрать `.updatesFrequently` (:179), сохранить `.accessibilityLabel` |
| `.connectingSlow` без actionable-affordance | major | Copy обязана нести recovery-guidance (в Acceptance); опц. 2-й порог → `.failed` (Out of Scope) |
| Транзиентный кадр `.idle`-while-active → мигание | major | Option A сохраняет предикаты дословно; `.idle` даёт те же мосты, что старое «active-no-handle» |
| Приоритет/interrupt анонса не экспонируется SwiftUI на macOS 26 | minor | API-verify; fallback `NSAccessibility.post` + `NSAccessibilityPriorityKey`; L5-критерий «`.failed` прерывает висящий `.connectingSlow`-анонс» (interrupt-семантика, не только наличие) |
| `async let _watchdog` unused под warnings-as-errors | minor | Дефолт `withTaskGroup` (избегает диагностики); compile-spike при T-2 решает форму |
| Поздний хендл после `.connectingSlow` теряется | major | Соединение не отменяется; тест late-handle `connectingSlow→.live` |
| L5 (живой Continuity/VoiceOver) не закрывается в cloud | major | Гоняется на целевом Mac (MX Brio); PR-body фиксирует оставшиеся hardware-гейты; cloud-merge только при зелёном CI и без остаточного L5 |
| enum/MainActor `==` gotcha | minor | enum без Equatable, `if case` везде |

## Out of Scope

- Кнопка явного retry в UI (пере-выбор устройства уже работает как retry — зафиксировано в #255).
- Второй, более длинный порог `.connectingSlow → .failed` с явным retry — опционально, вне MVP-скоупа #255 (включить только если тривиально и пользователь подтвердит).
- Изменения `previewGeneration` / `previewSource` / логики пересоздания NSView (кроме чтения `previewGeneration` для gen-гейта).
- Новый enum-кейс под disconnect — не нужен (`.failed`/`.idle` + `disconnectedCameraName` + отдельный анонс).
- Фокус-менеджмент VoiceOver при демонте блока превью (`isCameraActive→false`) — pre-existing, вне скоупа #256 (known-gap).
- Анонс disconnect микрофона (`disconnectedMicName`) — тот же silent-паттерн, что был у камеры; вне #256 (known consistency-gap, не расширяем скоуп).
- Узкий двойной анонс при unplug ровно во время connect (`.failed` + disconnect-notice на одно событие) — допустимо/best-effort; дедуп по тексту закрыл бы попутно, если дёшево.
- Формат/разрешение камеры, системный звук, любые изменения вне трёх issue.
- Жёсткая отмена/перезапуск подключения по таймауту (явно отвергнуто).

## Open Questions

- [non-blocking] Точные пороги таймаута (10с/5с — ориентир из #255); финализировать на L5 с реальным Continuity; в именованных константах.
- [non-blocking] Формулировки анонсов/copy `.connectingSlow` (с recovery-guidance) — бриф пользователю; UI-копирайт агентом не финализируется (CLAUDE.md).
- [non-blocking] Экспонирует ли SwiftUI/`AttributedString` приоритет анонса на macOS 26 — API-verify при имплементации; fallback `NSAccessibility.post`.
