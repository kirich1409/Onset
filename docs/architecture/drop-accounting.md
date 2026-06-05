# Drop Accounting

Документ описывает фактическое (as-is) поведение механизма учёта пропущенных кадров в Onset.
Дефекты помечены явно и НЕ являются целевым дизайном — целевой дизайн описан в
`docs/specs/2026-06-02-onset-recording-mvp.md` (AC-8, строки ~139–163).

---

## 1. Обзор пайплайна

```
SCStream                        AVCaptureSession / AVCaptureAudioDataOutput
   |                                  |              |
ScreenSource                    CameraSource (video) (audio)
   | frames: AsyncStream<VideoFrame>    |              |
   | .bufferingNewest(4)                | .bufferingNewest(...)
   |                                    |
   |  [DROP-A] переполнение буфера     [DROP-B] переполнение буфера
   |   → .encoderBackpressureDrops      → .encoderBackpressureDrops (video или audio)
   |                                    |  (Camera: capture-didDrop → [DROP-C] .captureDrop)
   v                                    v
VideoEncoder (screen)           VideoEncoder (camera)
   |                                    |
   | CFRNormalizer                      | CFRNormalizer
   |  [DROP-D] preAnchor (внутренний)   |  (аналогично)
   |  [DROP-E] duplicate-slot           |
   |   → .cfrNormalizationDrops (только внутри нормализатора, не в AsyncStream)
   |                                    |
   | backpressure gate                  | backpressure gate
   | pendingFrameCount >= 4             | pendingFrameCount >= 4
   |  [DROP-F] → .encoderBackpressureDrops
   |                                    |
   v                                    v
DualFileOutputStage
   |
   v
FileWriter (экран)              FileWriter (камера)
   |                                    |
   | AVAssetWriter.isReadyForMoreMediaData == false
   |  [DROP-G] → .encoderBackpressureDrops
   v                                    v
AVAssetWriter → файл .mov
```

**Точки возникновения дропов:**
- [DROP-A] `ScreenSource` — переполнение `AsyncStream` экранных кадров
- [DROP-B] `CameraSource` — переполнение `AsyncStream` кадров/аудио камеры
- [DROP-C] `CameraSource` — аппаратный дроп (`captureOutput(_:didDrop:from:reason:)`)
- [DROP-D] `CFRNormalizer` — кадр до временного якоря (pre-anchor), не попадает в `DropMonitor`
- [DROP-E] `CFRNormalizer` — дубликат слота (два кадра в один CFR-слот)
- [DROP-F] `VideoEncoder` — backpressure-гейт `VTCompressionSession`
- [DROP-G] `FileWriter` — `AVAssetWriter` не готов принять данные

---

## 2. Таксономия `DropReason`

Определение: `Onset/Recording/Pipeline/PipelineTypes.swift`, строки 210–240.

```swift
nonisolated enum DropReason {
    case captureDrop
    case cfrNormalizationDrops
    case encoderBackpressureDrops
}
```

| Case | Семантика | Кто эмитит | Штатный / аварийный |
|------|-----------|------------|---------------------|
| `.captureDrop` | Аппаратный дроп — AVCapture не успел доставить кадр в pipeline | `captureDropEvent()` в `CameraSourceHelpers.swift:52` | Штатный при перегрузке capture-очереди |
| `.cfrNormalizationDrops` | Дублирующийся кадр попал в уже закрытый CFR-слот; нормализатор отбрасывает лишний | `CFRNormalizer.cfrNormalizationDrops` (счётчик в нормализаторе); `VideoEncoder` передаёт значение в `DropMonitor` | Штатный механизм CFR |
| `.encoderBackpressureDrops` | Downstream не успевает потреблять — переполнение `AsyncStream` или перегрузка энкодера/диска | Четыре эмиттера (см. раздел 3) | Аварийный — пользователь видит потерю кадров |

### `CFRDropReason` — локальный enum нормализатора

`Onset/Encode/CFRNormalizer.swift`, строки 33–63. Не наследует `DropReason`.

| Case | Семантика |
|------|-----------|
| `.preAnchor` | Кадр с `PTS < sessionStart` — отброшен до начала сессии. Не попадает в `DropMonitor`, не отображается в UI. Счётчика нет. |
| `.cfrNormalizationDrops` | Дубликат слота — маппится в `DropReason.cfrNormalizationDrops` на уровне `VideoEncoder` |

---

## 3. Таблица эмиттеров `DropEvent`

| Файл | Строки | Стадия | `DropReason` | Условие срабатывания |
|------|--------|--------|--------------|----------------------|
| `Onset/Recording/Capture/ScreenSource.swift` | 49–56 | Capture overflow | `.encoderBackpressureDrops` | `AsyncStream.yield()` → `.dropped` (переполнение `.bufferingNewest(4)`) |
| `Onset/Recording/Capture/CameraSourceHelpers.swift` | 52–53 | Capture hardware drop | `.captureDrop` | `captureDropEvent(pts:count:)` — вызывается из делегата `didDrop` |
| `Onset/Recording/Capture/CameraSourceHelpers.swift` | 60–67 | Camera video overflow | `.encoderBackpressureDrops` | `cameraBackpressureDropEvent(for:pts:)` — переполнение `AsyncStream<VideoFrame>` |
| `Onset/Recording/Capture/CameraSourceHelpers.swift` | 70–77 | Camera audio overflow | `.encoderBackpressureDrops` | `audioBackpressureDropEvent(for:pts:)` — переполнение `AsyncStream<AudioSample>` |
| `Onset/Encode/VideoEncoder.swift` | 458–462 | Encoder backpressure gate | `.encoderBackpressureDrops` | `session.pendingFrameCount() >= maxPendingFrames` (default = 4) |
| `Onset/Storage/FileWriter.swift` | 245–262 | Writer/disk backpressure | `.encoderBackpressureDrops` | `videoSeam.isReadyForMoreMediaData == false` |

### Примечание по `CFRNormalizer`

`CFRNormalizer` (`Onset/Encode/CFRNormalizer.swift`) инкрементирует внутренний счётчик
`cfrNormalizationDrops` (строки 218, 253) — на `.preAnchor` счётчик не трогается.
`VideoEncoder` после каждого кадра читает `normalizer.cfrNormalizationDropCount`
и передаёт дельту в `DropMonitor` через собственный `drops: AsyncStream<DropEvent>`.
Таким образом, `CFRNormalizer` не создаёт `DropEvent` напрямую — это делает `VideoEncoder`.

---

## 4. Агрегация: `DropMonitor`

Файл: `Onset/Recording/Pipeline/DropMonitor.swift`.

### `DropCounters` — накопительные счётчики сессии

```swift
nonisolated struct DropCounters {
    nonisolated let encoderBackpressureDrops: Int  // единственный, попадающий в sliding window
    nonisolated let captureDrops: Int              // только накопительный, не триггерит Degraded
    nonisolated let cfrNormalizationDrops: Int     // только накопительный, не триггерит Degraded
}
```

Счётчики суммируют `DropEvent.count` за всю сессию и никогда не сбрасываются.

### `BackpressureDegradationWindow` — sliding window

- Хранит timestamp'ы backpressure-дропов (только `.encoderBackpressureDrops`).
- Запись: entry с `atSeconds` добавляется `count` раз (один `DropEvent(count: N)` → N stamp'ов).
- Eviction: `stamp < now − windowSeconds` → удаляется при каждом `record()` и `evaluate()`.
- Degraded: `stamps.count > threshold` (строгое неравенство).

### Параметры degraded-триггера

Определены в `Onset/Configuration/RecordingConfiguration.swift`, строки 283–284:

```swift
degradedBackpressureThreshold: 30,
degradedWindowSeconds: 2.0,
```

`DropMonitor` получает их при создании (`RecordingSession.swift:287–291`).

### Подписка на каналы в `RecordingSession`

`Onset/Recording/Pipeline/RecordingSession.swift`:

| Строка | Канал |
|--------|-------|
| 300 | `monitor.observe(writer.drops)` — FileWriter экрана или камеры (lazy, при создании writer) |
| 377 | `monitor.observe(source.drops)` — ScreenSource |
| 378 | `monitor.observe(encoder.drops)` — VideoEncoder экрана |
| 417 | `monitor.observe(source.drops)` — CameraSource |
| 418 | `monitor.observe(encoder.drops)` — VideoEncoder камеры |

### Маршрутизация по `DropReason` внутри `DropMonitor`

```
.encoderBackpressureDrops → encoderBackpressureDrops (накопитель) + sliding window (Degraded)
.captureDrop              → captureDrops (накопитель только)
.cfrNormalizationDrops    → cfrNormalizationDrops (накопитель только)
```

---

## 5. UI-поверхности

### 5.1 Живой счётчик и pill (`RecordingView`)

Файл: `Onset/UI/Recording/RecordingView.swift`, строка 157:

```swift
let dropCount = self.drops.encoderBackpressureDrops
```

Читает **только** `encoderBackpressureDrops`. Текст pill:
- `.normal`: `"\(encoderBackpressureDrops) пропущенных кадров"` (строка 342)
- `.degraded`: `"Пропущено \(encoderBackpressureDrops) кадров · диск"` (строка 345)

Цвет dot записи (`statusSection`): красный при `.normal`, оранжевый при `.degraded` (строка 325–327).

### 5.2 Menu bar (`MenuBarLabelMapper`)

Файл: `Onset/UI/MenuBar/MenuBarLabelMapper.swift`.

- Фаза `.recording` + состояние `.normal` → красный dot.
- Фаза `.recording` + состояние `.degraded` → жёлтый dot + иконка предупреждения (`showsWarning: true`).

Menu bar реагирует на `RecordingState` (`.normal` / `.degraded`), а не на `DropCounters` напрямую.
Состояние приходит через `RecordingCoordinator.recordingState`.

### 5.3 Completion-алерт (`MainView`)

Файл: `Onset/UI/Main/MainView.swift`, строки 59–346.

После остановки сессии `RecordingCoordinator` устанавливает `lastDegradedWarning = result.degradedWarning`.

`RecordingResult.degradedWarning` (`Onset/Recording/Pipeline/RecordingResult.swift:31–34`):

```swift
// degradedWarning = drops.encoderBackpressureDrops > 0
```

Приоритет алертов (`.writeError` > `.degradedWarning` > `nil`): при одновременном write-failure
алерт про диск перекрывает алерт про дропы.

### 5.4 `captureDrops` и `cfrNormalizationDrops` не достигают ни одной UI-поверхности

Оба счётчика хранятся в `DropCounters` и передаются через `RecordingResult`, но ни один View,
ни алерт не обращается к ним. Это явное следствие текущего кода, не намеренный дизайн.

---

## 6. Спека vs код — известные дефекты

Документ описывает фактическое поведение. Расхождения со спекой (#100):

### Дефект 1: конфляция источников дропов в `.encoderBackpressureDrops` (#100)

**Спека** (`docs/specs/2026-06-02-onset-recording-mvp.md`, AC-8): счётчики раздельны по семантике;
`encoderBackpressureDrops` — только `isReadyForMoreMediaData == false` (перегрузка энкодера/диска);
источник backpressure логируется с признаком «энкодер vs writer/диск».

**Код**: в `.encoderBackpressureDrops` попадают **четыре разных** события:
1. Переполнение `AsyncStream` экрана (`ScreenSource`) — стадия capture, не encode.
2. Переполнение `AsyncStream` камеры video/audio (`CameraSourceHelpers`) — стадия capture.
3. Гейт `pendingFrameCount >= 4` в `VideoEncoder` — стадия encode.
4. `isReadyForMoreMediaData == false` в `FileWriter` — стадия write/disk.

Следствие: degraded-pill «Пропущено N кадров · диск», completion-алерт «пропущены кадры
из-за перегрузки диска» и degraded-состояние срабатывают на любой overflow capture-стрима —
в т.ч. когда диск ни при чём. Пользователь получает заведомо ложный диагноз.

### Дефект 2: `degradedWarning = encoderBackpressureDrops > 0` (#100)

**Спека**: Degraded — backpressure-дропы за скользящее окно выше порога (30 за 2с).

**Код**: `RecordingResult.degradedWarning` вычисляется как `encoderBackpressureDrops > 0` —
любой единственный дроп за всю запись приводит к алерту. Скользящее окно (`DropMonitor`)
влияет на живое `.degraded`-состояние, но не на completion-алерт.

### Дефект 3: отсутствие структурированного логирования стадии дропа (#100)

**Спека**: источник backpressure логируется с признаком «энкодер vs writer/диск».

**Код**: `FileWriter` логирует `.debug("FileWriter video input not ready (backpressure)…")`,
что скрывается в release. `ScreenSource` и `CameraSourceHelpers` не логируют дропы вообще.
Subsystem `dev.androidbroadcast.Onset`, категория `FileWriter` — только для FileWriter.
По текущему коду невозможно по логам определить, на какой стадии происходит дроп.

### Issue #65 — предыстория

Гипотеза «дропы в UI — это `cfrNormalizationDrops`» опровергнута: UI читает только
`encoderBackpressureDrops`. Наблюдавшаяся сигнатура (~11 дропов/сек при 5K) — реальные
backpressure-дропы, не артефакт CFR-учёта. Issue #65 является поднабором #100.

### Issue #50 — camera capture fps

Camera capture работает с фиксированным форматом 30 fps вне зависимости от выбранного.
Может влиять на частоту camera-lane дропов, но не на механику их учёта.

---

## 7. Порядок диагностики

### Сегодня (без дополнительного логирования)

По текущему коду определить стадию дропа нельзя — все четыре источника суммируются в один счётчик.
Доступна только общая цифра `encoderBackpressureDrops` в UI.

Единственный частичный сигнал: `FileWriter` пишет `.debug`-лог при writer-backpressure.
Чтобы увидеть его в Console.app или `log stream`:

```bash
log stream --predicate 'subsystem == "dev.androidbroadcast.Onset"' --level debug
```

### После реализации плана логирования (#100)

Каждый эмиттер будет логировать `stage` (screenSource | cameraSource | encoder | fileWriter),
`reason`, количество дропов за окно и PTS последнего дропа. Это позволит по логам найти
доминирующую стадию и подтвердить или исключить диск как причину.

`VideoEncoder` должен логировать глубину очереди (`pendingFrameCount`) и encode-латентность
слота (время submit → callback). `FileWriter` — длительность эпизодов `!isReadyForMoreMediaData`.
