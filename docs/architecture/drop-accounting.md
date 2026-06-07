# Drop Accounting

Документ описывает фактическое (as-is) поведение механизма учёта пропущенных кадров в Onset.
Дефекты помечены явно и НЕ являются целевым дизайном — целевой дизайн описан в
`docs/specs/2026-06-02-onset-recording-mvp.md` (AC-8, строки ~139–163).

Механика CFR-часов (абсолютный дедлайн, catch-up эмиссия, grace-окно) обновлена в #102.

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
| `.cfrNormalizationDrops` | Кадр прибыл в уже эмитированный CFR-слот; нормализатор отбрасывает его. После #102 (абсолютный дедлайн + grace-окно 5 ms) встречается редко — только при задержке доставки > grace. Холды повторяют `lastPixelBuffer` и не конкурируют с реальным кадром. | `CFRNormalizer.cfrNormalizationDrops` (счётчик в нормализаторе); `VideoEncoder` передаёт значение в `DropMonitor` | Штатный механизм CFR; редкий при нормальной работе после #102 |
| `.encoderBackpressureDrops` | Downstream не успевает потреблять — переполнение `AsyncStream` или перегрузка энкодера/диска | Четыре эмиттера (см. раздел 3) | Аварийный — пользователь видит потерю кадров |

### `CFRDropReason` — локальный enum нормализатора

`Onset/Encode/CFRNormalizer.swift`, строки 33–63. Не наследует `DropReason`.

| Case | Семантика |
|------|-----------|
| `.preAnchor` | Кадр с `PTS < sessionStart` — отброшен до начала сессии. Не попадает в `DropMonitor`, не отображается в UI. Счётчика нет. |
| `.cfrNormalizationDrops` | Кадр прибыл в уже эмитированный слот — маппится в `DropReason.cfrNormalizationDrops` на уровне `VideoEncoder`. После #102 встречается редко (только при задержке доставки > grace). |

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
`cfrNormalizationDrops` — на `.preAnchor` счётчик не трогается.
`VideoEncoder` после каждого кадра читает `normalizer.cfrNormalizationDropCount`
и передаёт дельту в `DropMonitor` через собственный `drops: AsyncStream<DropEvent>`.
Таким образом, `CFRNormalizer` не создаёт `DropEvent` напрямую — это делает `VideoEncoder`.

**Механика эмиссии слотов (#102).** Каждый CFR-слот эмитируется ровно один раз в порядке
возрастания через единый гейт `lastEmittedSlot`. Два пути эмиссии:

- **Приём кадра (`catchUpThenEncode`)**: при получении реального кадра нормализатор сначала
  эмитирует синтетические холды для всех пропущенных слотов с момента последней эмиссии,
  затем — сам кадр. Реальный кадр атомарно занимает свой слот прежде, чем к нему обратятся часы.
- **CFR-часы (`catchUpHolds`)**: абсолютный дедлайн (`nextDeadlineSeconds`, вычисляется от
  якоря сетки); `Task.sleep(for:)` до дедлайна. Поздний пробуд безвреден — catch-up одним
  пакетом эмитирует все слоты, прошедшие за время oversleep. Часы заполняют только слоты,
  которые реальные кадры никогда не заняли (тишина источника, статичная картинка).

**Grace-окно**: слот N становится eligible для холда не раньше, чем
`anchorSeconds + (N + 0.5)/fps + graceSeconds`. Дефолтный `graceSeconds = 0.005` (5 ms) —
превышает p95-латентность capture→ingest и оставляет запас до половины слота при 60 fps (8.33 ms).
Благодаря grace реальный кадр гарантированно успевает занять слот до того, как часы выдадут холд.

**Холды** повторяют `lastPixelBuffer` и попадают в AVAssetWriter как синтетические кадры с
монотонно возрастающим PTS. Реальный кадр, прибывший в уже эмитированный слот, считается
`cfrNormalizationDrops` (редко после #102 — только при задержке > grace).

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

### ~~Дефект 3: отсутствие структурированного логирования стадии дропа (#100)~~ — исправлено в #102

**Спека**: источник backpressure логируется с признаком «энкодер vs writer/диск».

**Было**: `FileWriter` логировал `.debug(…)` (скрывался в release); `ScreenSource` и
`CameraSourceHelpers` не логировали дропы вообще. По логам нельзя было определить стадию.

**Сейчас**: добавлен `StageRateAggregator` — per-stage телеметрия каждые ~1 с через единый
логгер `Logger(subsystem: "dev.androidbroadcast.Onset", category: "telemetry")` на уровне
`.notice` (сохраняется по умолчанию, видно без `--info`/`--debug`). Каждая строка —
machine-parseable key=value с полями:

```
lane=camera stage=encoder fresh=29.8 drop_dup=0.1 holds=0.2 gate_drop=0 emit_rate=30.0
  nominal=30 tick_lag_ms_avg=1.2 tick_lag_ms_max=3.4 catchup_max=2 win_s=1.01
```

(`fresh` — реальные кадры/с, `drop_dup` — дубликаты-слота/с, `holds` — синтетические холды/с,
`gate_drop` — backpressure-дропы на гейте энкодера/с, `emit_rate` — суммарная эмиссия/с,
`tick_lag_ms_avg/max` — запаздывание пробуда часов в мс, `catchup_max` — максимальный
catch-up за один тик.)

Получить поток телеметрии:

```bash
log stream --predicate 'subsystem == "dev.androidbroadcast.Onset" and category == "telemetry"'
```

**Примечание**: телеметрия устраняет диагностическую часть Дефекта 3. Конфляция счётчиков
(Дефект 1) и некорректная формула `degradedWarning` (Дефект 2) остаются открытыми (#100).

### Issue #65 — предыстория

Гипотеза «дропы в UI — это `cfrNormalizationDrops`» опровергнута: UI читает только
`encoderBackpressureDrops`. Наблюдавшаяся сигнатура (~11 дропов/сек при 5K) — реальные
backpressure-дропы, не артефакт CFR-учёта. Issue #65 является поднабором #100.

### Issue #50 — camera capture fps

Camera capture работает с фиксированным форматом 30 fps вне зависимости от выбранного.
Может влиять на частоту camera-lane дропов, но не на механику их учёта.

---

## 7. Порядок диагностики

### Per-stage телеметрия (доступна после #102)

После #102 `StageRateAggregator` логирует per-stage статистику каждые ~1 с в категорию
`telemetry` на уровне `.notice`. По полям `gate_drop` (backpressure на гейте энкодера),
`drop_dup` (дубликаты CFR-слота), `holds` (синтетические холды) и `tick_lag_ms_avg/max`
(запаздывание CFR-часов) можно локализовать доминирующую проблему без сборки в Debug.

```bash
log stream --predicate 'subsystem == "dev.androidbroadcast.Onset" and category == "telemetry"'
```

Все четыре источника `encoderBackpressureDrops` по-прежнему суммируются в один счётчик в UI
(Дефект 1, #100 не закрыт). Телеметрия показывает `gate_drop` (гейт энкодера) отдельно,
но writer-backpressure в отдельное поле не вынесен — полное разделение счётчиков остаётся за #100.

### Устаревшая диагностика через FileWriter

До #102 единственным частичным сигналом был `.debug`-лог `FileWriter` (скрывался в release).
Для полноты: он пишет `FileWriter video input not ready (backpressure)` в категорию `FileWriter`.

```bash
log stream --predicate 'subsystem == "dev.androidbroadcast.Onset"' --level debug
```

### Открытые пункты (#100)

`VideoEncoder` пока не логирует encode-латентность слота (время submit → callback).
`FileWriter` не логирует длительность эпизодов `!isReadyForMoreMediaData`. Оба пункта —
часть плана #100.

---

## 8. Верификация CFR-кадров (`scripts/verify-cfr.sh`)

`scripts/verify-cfr.sh <screen.mp4> <camera.mp4> <screen_fps> <camera_fps>` — PASS/FAIL
скрипт, проверяющий фактические метки времени пакетов (не метаданные `r_frame_rate`/
`avg_frame_rate`, которым кодек может лгать).

```bash
scripts/verify-cfr.sh screen.mp4 camera.mp4 60 30
```

Проверки:

| Проверка | Метод |
|----------|-------|
| A — packet rate (fps) | `ffprobe -show_packets`, δPTS; отклонение ≤ 2% от номинала |
| B — равномерность PTS-дельт | δPTS; ≤ 10 гэпов/мин > 1.5 слота |
| C — свежесть кадров камеры | `ffmpeg -vf mpdecimate`; keep-fps ≥ 25 fps (требует движения в кадре) |
| D — длина серий дублей | modal run mode ≤ 2 (до #102: ~13) |

**PTS сортируются** перед вычислением дельт: потоки содержат B-кадры, пакеты приходят в
decode-порядке, а не в display-порядке — без сортировки появляются ложные отрицательные δ.
`r_frame_rate` не используется — номинальный fps передаётся явным аргументом.

Коды выхода: 0 — все проверки прошли, 1 — одна или более провалена, 2 — отсутствует зависимость.

---

## 9. Writer fault — отдельная поверхность, не backpressure-drop (#105)

Фолт `AVAssetWriter` — жёсткий, невосстановимый сбой записи (`append()` вернул `false` не из-за
`isReadyForMoreMediaData`, а из-за внутренней ошибки движка). Это не backpressure-drop [DROP-G] —
они семантически противоположны: backpressure означает «downstream не успевает, попробуй позже»,
фолт означает «writer мёртв, продолжать бессмысленно».

### Канал `FileWriter.faults`

```swift
nonisolated let faults: AsyncStream<Void>
```

Свойства канала:
- **At-most-once**: при фолте в стрим кладётся ровно один `Void`, после чего стрим финишируется.
- **Без yield при штатном завершении**: `markFinished()` вызывает `finish()` напрямую (без
  предшествующего `yield(())`), поэтому `for await _ in faults` завершается без итераций — канал
  не блокирует потребителей и не сигнализирует ложный фолт.
- `deinit` также вызывает `finish()` как safety-net; двойной `finish` — документированный no-op.

### Маршрутизация фолта

```
FileWriter.append() → false (writer faulted)
    ↓ isFaulted = true; faultsContinuation.yield(()); faultsContinuation.finish()
FileWriter.faults (AsyncStream<Void>)
    ↓ for await in DualFileOutputStage (fault-observer task, запускается при создании writer)
DualFileOutputStage.recordFault(for: kind)
    ↓ faultedWriterKinds.insert(kind)
    ↓ если faultedWriterKinds ⊇ liveKinds → onAllWritersFaulted()
RecordingSession.stop()   // немедленно, fail-fast; stop() идемпотентен через memoised stopTask
```

**Ключевой инвариант:** «live writers» — только те, для которых уже создан `FileWriter` (первый
видеокадр поступил и `createWriter` выполнился). Lazy-врайтеры (не созданные к моменту фолта —
нет входящих кадров) **не входят** в множество `liveKinds` и не блокируют срабатывание
`onAllWritersFaulted`. Это намеренно: если, например, камера не дала ни одного кадра, а экранный
writer фолтнул — запись останавливается немедленно, а не ждёт несуществующего camera-writer.

### Canary-лог смены аудио-формата

`DualFileOutputStage.routeAudio(_:)` содержит постоянный canary-лог:

```swift
self.logger.error("Audio format changed mid-stream (#105 regression): …")
```

Уровень `.error` выбран намеренно — смена формата после фикса #105 означает регрессию (pinning
перестал работать); `.debug` или `.warning` будут отфильтрованы в release-сборках и при диагностике
инцидента окажутся невидимы. Canary всегда проходит (никакая конфигурация логирования не обрезает
`.error`).

### Отличие от backpressure-дропов

| | Backpressure-drop [DROP-G] | Writer fault |
|---|---|---|
| Условие | `videoSeam.isReadyForMoreMediaData == false` | `append()` вернул `false` при готовом input |
| Восстановимо | Да — следующий `append()` может пройти | Нет — writer мёртв |
| Попадает в `DropMonitor` | Да, `.encoderBackpressureDrops` | Нет |
| Действие | Кадр отброшен, запись продолжается | `RecordingSession.stop()` немедленно |
| Канал | `FileWriter.drops: AsyncStream<DropEvent>` | `FileWriter.faults: AsyncStream<Void>` |

---

## 10. Pinning аудио-формата (`CameraSource.audioOutputSettings`) (#105)

### Root cause

`AVCaptureAudioDataOutput` с `audioSettings = nil` доставляет буферы в device-native transport
формате (например, int16 interleaved stereo для USB-микрофона MX Brio). После того как CoreAudio
устанавливает channel routing, формат переключается mid-stream на float32 non-interleaved.
`AVAssetWriterInput` (AAC) конфигурирует внутренний конвертер на **первом** буфере; смена layout
после этого вызывает сбой конвертера с кодами `-11800` (AVFoundation internal) / `-12737`
(ArrayTooSmall в AudioConverter), что убивает оба writer'а (#105).

### Фикс

`CameraSource.audioOutputSettings(sampleRate:channelCount:)` явно задаёт
`AVCaptureAudioDataOutput.audioSettings` = LPCM float32 interleaved:

```swift
AVFormatIDKey: kAudioFormatLinearPCM,
AVLinearPCMBitDepthKey: 32,
AVLinearPCMIsFloatKey: true,
AVLinearPCMIsNonInterleaved: false,   // interleaved
AVLinearPCMIsBigEndianKey: false,
```

CoreAudio нормализует формат один раз до прихода любого буфера в pipeline — формат фиксирован на
всю сессию. Параметры `sampleRate` и `channelCount` поступают из `RecordingConfiguration` — того же
источника, что использует `FileWriter` для настройки AAC-входа; capture-формат и mux-формат
согласованы конструктивно.

### Почему смена формата теперь регрессия

До фикса pipeline терпел mid-stream смену формата потому, что capture-формат не был закреплён.
После фикса `audioSettings` зафиксированы — формат **никогда** не должен меняться в течение
сессии. Любое срабатывание canary-лога `routeAudio(_:)` (см. раздел 9) означает, что pinning
сломался или новое устройство выходит за пределы заявленного spec. Это регрессия класса #105,
не диагностический шум.
