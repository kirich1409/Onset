# Пайплайн записи камеры

Детальное описание пути видеокадра с камеры от захвата до записи в файл:
текущий дизайн, испробованные подходы и причины их отклонения, известные
ограничения. Срез по состоянию `main` (2026-07-02).

---

## 1. Текущая цепочка

```
AVCaptureSession
  └─ CameraFormatSelector.pickBestFormat   // 16:9 ≤1080p-target при maxFps≥30
  └─ activateFormat: min=max frame dur.    // пиннинг кадровой частоты

videoQueue (.userInteractive)
  └─ VideoOutputShim.captureOutput(…)
       └─ CMSyncConvertTime → host-time PTS   // единственная конверсия
       └─ VideoFrame(pixelBuffer, ptsHostTime, isHoldRepeat: false)

AsyncStream<VideoFrame>  .bufferingNewest(4)
  └─ overflow → evict oldest + DropEvent(.encoderBackpressureDrops)

[опционально, #297: тумблер «Стабилизация камеры» ON → LiveSourceFactory
 оборачивает CameraSource в StabilizingVideoSource; OFF → декоратора нет]
StabilizingVideoSource  (actor-декоратор, только record-путь)
  └─ eager-drain: вход → слот глубины 1 (newest wins)
       └─ вытеснение → DropEvent(.stabilizeCamera, .stabilizationDrops)
  └─ warm-up 60 кадров (медиана интервалов ≥40 мс → estScale 3×, иначе 2×)
  └─ StabilizationRenderer (serial queue, continuation-мост):
       Vision translational на 1080p-эквивалентном апскейле →
       StabilizationSmoother (pure, correction = −смещение контента; знак Vision инвертируется в рендерере) →
       CI translate → clampToExtent → session-fixed crop → scale-back →
       НОВЫЙ CVPixelBuffer 420v из пула (threshold 12)
  └─ выход AsyncStream<VideoFrame> .bufferingNewest(4)
       └─ overflow → DropEvent(.stabilizeCamera, .encoderBackpressureDrops)
  └─ bypass при перегрузе (>5% вытеснений 2×10 s ИЛИ 60 ошибок подряд):
       оценка стоп, геометрия рендерится, correction рампится к нулю

VideoEncoder.framesTask  (actor, for await …)
  └─ ingest(frame:)
       └─ CFRNormalizer.catchUpThenEncode(ptsSeconds:anchorSeconds:fps:cap:)
            └─ holds для пропущенных слотов (round(pts*fps))  // атомарно
            └─ реальный кадр
       └─ submitEmission → submit(pixelBuffer:slotIndex:pts:detectedAt:)
            └─ backpressure gate:
               pendingFrameCount() >= maxPendingFrames(4) → gate_drop, return

VTCompressionSession  (HEVC HW required)
  kVTCompressionPropertyKey_RealTime             = true
  kVTCompressionPropertyKey_AllowFrameReordering = false   // DTS == PTS

C callback → EncodedSampleSink
  └─ AsyncStream<EncodedSample>  (unbounded)
       └─ DualFileOutputStage → FileWriter   (fragmented MP4, 4 s fragment)
```

Телеметрия (`StageRateAggregator`, ~1 s flush, `os.Logger` category `telemetry`):

| Поле | Стадия | Семантика |
|---|---|---|
| `role` | capture | `preview\|record` — идентификатор роли источника; preview не подключает data output и не запускает telemetry task |
| `fresh` | capture | пакеты со свежим содержимым (не hold-repeat) |
| `overflow` | capture | выселений из bounded stream |
| `gap_ms` | capture | средний интервал между реальными кадрами |
| `enc_real` | encoder | реальных кадров подано в VT |
| `drop_dup` | encoder | дублей отброшено CFRNormalizer |
| `holds` | encoder | hold-repeat кадров эмитировано |
| `gate_drop` | encoder | дропов backpressure-гейтом |
| `emit_rate` | encoder | итоговый fps на выходе из encoder |
| `tick_lag_ms_avg/max` | encoder | wake-latency клока (см. §6) |
| `catchup_max` | encoder | максимальный batch hold за один тик |
| `enc_ms` | encoder | время VTCompressionSessionEncodeFrame |
| `pend_ms` | encoder | время pendingFrameCount() |
| `pending_max` | encoder | пик NumberOfPendingFrames за окно |
| `ing_ms` | encoder | полное время ingest() |

---

## 2. Выбор формата и пиннинг частоты

`CameraFormatSelector.pickBestFormat` реализует политику 16:9 (issue #145), с двумя
резолюционными ярусами через `allowAboveFullHD`:

1. Отфильтровываются форматы с `maxFps < 30` (инвариант AC-5).
2. Из оставшихся выбираются форматы 16:9 (`pixelWidth * 9 == pixelHeight * 16`).
3. Среди 16:9-форматов:
   - `allowAboveFullHD == false` (дефолт — preview / device-list) — предпочитается наибольший
     с `height ≤ 1080` (1080p при наличии, иначе шаг вниз до 720p и т.д.); если все 16:9-форматы
     выше 1080p — берётся наименьший из них (ближайший сверху к целевому разрешению).
   - `allowAboveFullHD == true` (record path, `resolveCameraFormat`) — кэп снят: выбирается
     формат с максимальным числом пикселей среди всех 16:9-кандидатов (4K, когда камера
     его отдаёт).
4. При равном разрешении побеждает бо́льший `maxFps` (60 перед 30).
5. Если 16:9-форматов нет — fallback на максимальное число пикселей (tie-break: бо́льший fps).
6. `RecordingError.noSuitableCameraFormat` бросается только при пустом qualifying-множестве.

Следствие: Brio, предлагающий и 4K30, и 1080p60, получит **1080p** на preview/device-list пути
(16:9, ≤1080, выше fps), но **4K на record-пути** — 4K достижим через AVFoundation на macOS
(hold-lock через `startRunning()`, #265; см. [`docs/quality/macos-avfoundation-camera-limits.md`](../quality/macos-avfoundation-camera-limits.md)
за полной историей вердикта). Камера-энкодер строится от resolved-размеров фактически выбранного
формата (`CapabilityResolver` → `RecordingComponentFactories`), поэтому апскейл-рассогласования
между 4K-энкодером и 1080p-доставкой нет ни на одном пути. 60fps остаётся недостижим на любом
пути — hardware-constraint конкретной камеры (Brio ~20-25fps фактической каденции), не лимит
AVFoundation; отслеживается в [#178](https://github.com/kirich1409/Onset/issues/178).
Встроенная камера FaceTime HD (квадратный Center-Stage формат 1552×1552) теперь получит
16:9-режим (например, 1920×1080) — центральное следствие введения 16:9-предпочтения.

Пиннинг кадровой частоты в `activateFormat(_:fps:on:)`:

```swift
device.activeVideoMinFrameDuration = bestRange.minFrameDuration
device.activeVideoMaxFrameDuration = bestRange.minFrameDuration  // min == max
```

Оба лимита выставляются в одно и то же значение — нативное CMTime-представление
устройства для целевой частоты. Это запрещает адаптивный AE-throttle снижать fps,
хотя при недостаточной яркости камера всё равно может нарушить контракт (§8.1).

---

## 3. Конверсия времени и T0-эпоха

Конверсия временной метки из clock-домена `AVCaptureSession` в host-time происходит
**один раз** — в `VideoOutputShim.captureOutput(_:didOutput:fromConnection:)` в
`CameraSourceShims.swift` через `CMSyncConvertTime`. Ниже по пайплайну PTS
представляет собой host-time offset от T0-якоря (`HostTimeAnchor`), созданного
`RecordingSession` при старте. Повторных конверсий нет.

Это исключает расхождение часов между экраном и камерой при двухфайловой записи:
оба источника используют один и тот же host-clock.

---

## 4. Bounded stream и backpressure

`CameraSource` выдаёт кадры через `AsyncStream<VideoFrame>` с политикой
`.bufferingNewest(4)`. При переполнении:

1. Старейший кадр в буфере вытесняется.
2. `DropMonitor` получает `DropEvent(.encoderBackpressureDrops, count: 1)`.
3. `StageRateAggregator` фиксирует `overflow`.

`VideoEncoder.framesTask` — единственный подписчик (`for await`). Нет fan-out,
нет broadcast. Это гарантирует, что кадры обрабатываются строго по порядку.

---

## 5. CFRNormalizer и клок

`CFRNormalizer` — чистый (nonisolated) state machine без зависимостей от CoreMedia.
Работает с вещественными секундами относительно T0.

**catchUpThenEncode** — атомарный вызов при приёме реального кадра:
1. Вычисляет пропущенные CFR-слоты между последним эмитированным и текущим PTS.
2. Заполняет пропуски hold-кадрами (копия последнего реального кадра).
3. Эмитирует текущий реальный кадр.

Атомарность важна: если hold и реальный кадр выходят из разных путей, возникает
гонка (см. §6, медленный эмиттер).

**catchUpHolds** — вызывается из clock-задачи при пропуске тика (нет реального
кадра в слоте). Grace window по умолчанию 5 мс: слот N становится eligible после
`anchor + (N + 0.5) / fps + grace`. Это оставляет кадру возможность прийти
чуть позже тика и не дублировать его.

**Клок с абсолютным дедлайном**: `Task.sleep(until:)` к абсолютному моменту времени
устраняет кумулятивный дрейф. При позднем пробуждении клок эмитирует catch-up batch
за все пропущенные слоты в одном вызове.

---

## 6. Испробованные подходы и почему отвергнуты

### 6.1 Медленный relative-sleep эмиттер (до issue #102)

Исходная реализация спала относительным интервалом (`Task.sleep(nanoseconds:)`) и
эмитировала holds из clock-задачи, реальные кадры — из ingest-задачи.

**Проблема 1 — кумулятивный дрейф.** Относительный сон накапливал ошибку:
каждый тик смещался относительно CFR-сетки. На 60 fps за минуту дрейф достигал
десятков мс, что приводило к систематическому пропуску слотов.

**Проблема 2 — гонка hold-vs-real.** Hold-задача и ingest-задача работали независимо.
Если реальный кадр приходил одновременно с hold-тиком, в выходном потоке появлялись
дубли или инверсии порядка. Наблюдалось 2.88 fps свежего содержимого на камере при
номинальных 30 fps.

**Решение (#102):** `catchUpThenEncode` объединил hold-эмиссию и real-эмиссию в один
атомарный вызов на actor'е; `Task.sleep(until:)` к абсолютному дедлайну.

### 6.2 B-кадры как структурный дефект (#112, 2026-06-07)

**Изначальное решение:** `allowFrameReordering: true` (значение по умолчанию VT).
Логика: «это не live-stream, B-кадры дают лучший коэффициент компрессии».

**Дефект:** HEVC-энкодер с `AllowFrameReordering=true` держит reorder-окно.
`NumberOfPendingFrames` при нормальной работе находится на полу ≈4 — что в точности
равно порогу backpressure-гейта `maxPendingFrames = 4`. В результате гейт стохастически
срабатывает на **здоровом** пайплайне:

- Камера: потеря ~17% слотов (≈5/30 кадров/с).
- Экран: потеря ~40% слотов на 4K60.

Это не перегрузка и не медленный консьюмер — это структурное противоречие между
порогом гейта и поведением энкодера. `pending_max` стабильно показывал 4 при
исправном захвате.

**Решение:** `AllowFrameReordering = false`. `NumberOfPendingFrames` падает ниже 4;
гейт перестаёт срабатывать на здоровом пайплайне. DTS == PTS и минимальная латентность
энкодера — дополнительные плюсы для записи в реальном времени. Компрессионный выигрыш
от B-кадров не стоит сломанного каденса.

**Изменение:** ветка fix #112 (конфиг-флип + телеметрия + L5 A/B-харнесс).

### 6.3 Гипотезы #112, опровергнутые A/B на железе (2026-06-07)

Три гипотезы были выдвинуты до нахождения корневой причины и проверены на
Logitech MX Brio:

**H1: кросс-полосная конкуренция VT (camera vs screen sharing одного сервиса).**
A/B: camera-only vs dual-mode — идентичное поведение (те же gate_drop, та же потеря
слотов). Конкуренция опровергнута.

**H2: переполнение capture-очереди как первопричина overflow.**
На тихой машине overflow = 0/с при той же потере fresh content. Overflow был следствием,
а не причиной — гейт отклонял кадры, они накапливались в stream.

**H3: QoS-голодание framesTask.**
tick_lag после фикса: avg 2.3 мс, max 9 мс. Задача получала процессор в срок,
консьюмер не был медленным. Гипотеза отвергнута.

### 6.4 Старая семантика tick_lag — артефакт измерения

Старый `tick_lag` измерялся как разница между временем wake и **пересчитанным**
дедлайном после приёма ingest-данных. Это давало ~33 мс фантомного лага на здоровом
пайплайне при 30 fps — ровно один период слота.

Именно эта метрика увела диагностику #112 в сторону «консьюмер не успевает».
После переопределения `tick_lag` как wake-latency (разница между реальным пробуждением
и дедлайном, к которому клок засыпал) показания стали честными: avg 2–3 мс, max 9 мс.

### 6.5 Баг единиц elapsedMs (1000× ошибка)

В ранних версиях телеметрии `enc_ms` вычислялся как
`Duration.attoseconds / 1e18 * 1000`. Из-за деления на `1e18` вместо умножения
значение было занижено в 1000 раз (показывало `≈0`). Это создало ложную уверенность
в том, что VT-вызовы не являются узким местом. Урок: новые метрики требуют проверки
размерности перед интерпретацией. Исправлено в той же ветке (#112).

### 6.6 Реверты в #104 (2026-06-05/06)

В ходе диагностики остаточного `gate_drop` на экране были опробованы два изменения,
впоследствии отклонённые:

**Локальный pending-счётчик вместо `VTSessionCopyProperty`:** попытка обойти
предполагаемую латентность `pendingFrameCount()` собственным счётчиком.
Не повлияло на `gate_drop`. Откат: 7d93d4b.

**Hold-soft-gate:** пропускать hold-кадры через гейт независимо от pending.
Не устранило корневую проблему. Идея отложена, откат: 170dc1a.

---

## 7. Таблица констант: решение → причина

| Константа | Значение | Причина |
|---|---|---|
| `AsyncStream .bufferingNewest(4)` | 4 кадра | Буфер на ~133 мс при 30 fps; overflow вытесняет старейший кадр, не блокирует producer |
| `maxPendingFrames` | 4 | Порог backpressure-гейта; согласован с floor `NumberOfPendingFrames` при `AllowFrameReordering=false` (< 4) |
| `RealTime = true` | `kVTCompressionPropertyKey_RealTime` | HW-HEVC encoder приоритизирует latency над компрессией в реальном времени; required property |
| `AllowFrameReordering = false` | `kVTCompressionPropertyKey_AllowFrameReordering` | B-frame reorder-окно держит pending floor = порог гейта → структурные gate_drop на здоровом пайплайне (#112); DTS == PTS как следствие |
| `frame duration min = max` | `bestRange.minFrameDuration` дважды | Пиннинг кадровой частоты к нативному CMTime устройства; запрет адаптивного throttle |
| Единственный подписчик | `RecordingCoordinator` через `framesTask` | `AsyncStream` не поддерживает broadcast; порядок кадров гарантирован одним `for await` |

---

## 8. Известные ограничения и открытые вопросы

### 8.1 AE-droop в тёмной сцене

UVC-камеры (включая MX Brio) снижают фактическую частоту кадров при недостаточной
яркости несмотря на пиннинг `activeVideoMinFrameDuration`. Наблюдалось 23.4 fps,
`gap_ms_avg = 42.8` в тёмной сцене (2026-06-07, L5). Это ограничение устройства,
не дефект пайплайна.

Следствие для QA: метрика `fresh_fps ≥ 95%` валидна только при дневном свете
с движением в кадре. Статичная или тёмная сцена даёт ложно-негативный результат.
(см. `docs/quality/production-quality-bar.md §4.1`).

### 8.2 Capture overflow под нагрузкой

В прогонах в присутствии активной agent-сессии на том же Mac зафиксировано
overflow 12–15/с (2026-06-07, issue #112). На тихой машине overflow ≈ 0/с.
Потолок дренажа framesTask не воспроизведён в изолированных условиях.

Показания overflow 12–15/с были атрибутированы превью-экземпляру `CameraSource`
(создаётся в `MainViewModel.makeCameraSource`): он подключал `AVCaptureVideoDataOutput`,
но `frames`-stream никто не дренировал — результат постоянное переполнение буфера.
Исправлено в issue #119: preview-экземпляр создаётся с `role: .preview` и не
подключает data output.

Кандидаты на фикс остаточного overflow (отложены до дискриминирующего замера):
- Повышение приоритета framesTask (Task priority bump).
- Увеличение буфера `.bufferingNewest(4 → 8)`.

Проблема отслеживается как follow-up к #112.

### 8.3 Остаточный gate_drop экрана (~3/с на 4K60)

После отключения B-кадров `gate_drop` экрана снизился с ~20/с до ~3/с, но не до нуля
(issue #104, открыт, board: Ready). Корневая причина не установлена. Два отклонённых
направления описаны в §6.6. Пайплайн камеры этим не затронут.

### 8.4 Режимы камеры

`CameraFormatSelector` переключён на политику 16:9 (issue #145): вместо «максимум пикселей»
алгоритм предпочитает наибольший 16:9-формат — на два яруса, через `allowAboveFullHD`:

- **Preview / device-list** (`allowAboveFullHD: false`, дефолт) — кэп `height ≤ 1080`. Для Brio
  это означает автовыбор 1080p для превью и для чеклист-лейбла (`MainViewModel+Devices.swift`).
- **Record path** (`allowAboveFullHD: true`, `resolveCameraFormat` в `MainViewModel+Record.swift`) —
  кэп снят: выбирается наибольшее доступное 16:9-разрешение (4K для Brio). Камера-энкодер строится
  от этих же resolved-размеров (`CapabilityResolver` → `RecordingComponentFactories`), поэтому
  рассогласования VT-сессии с фактически доставляемым форматом нет.

4K достижим через AVFoundation на macOS: изначальный вывод «4K недостижимо, нужен CMIO/IOKit»
([#177](https://github.com/kirich1409/Onset/issues/177)) опровергнут — 4K реверсировался в 1080p
из-за бага lock-lifecycle приложения (`unlockForConfiguration()` до `startRunning()`), исправлено
в [#265](https://github.com/kirich1409/Onset/issues/265). L5-прогон полного record-пути
(2026-07-02, MX Brio) подтвердил native 4K, удержанный всю запись, с нулём потерь кадров даже под
worst-case полноэкранным движением экрана 4K60. Подробности:
`docs/quality/macos-avfoundation-camera-limits.md`.

60fps остаётся недостижим на обеих камерах — hardware-constraint конкретно Brio
(отслеживается в [#178](https://github.com/kirich1409/Onset/issues/178)), не связано со
снятием 4K-кэпа выше. MVP-скоуп камеры: 16:9, авто-выбором, без ручного пикера (issue #113 закрыт).

Ручное управление источником камеры реализовано через
`MainViewModel.cameraPickerSelection` (#224, поверх `cameraEnabled` из #77, #76):
в секции «Камера» один пикер «Устройство», первый пункт которого — «Выключена»
(`nil`-selection). Выбор «Выключена» выключает камеру — тогда `activeCamera` равен
`nil`, превью скрыто, и `RecordingStartPlan.includeCamera` равен `false`; выбор
устройства включает камеру и задаёт `selectedCameraID`. Превью камеры отображается
как карточка 16:9 (#74) только при выбранном устройстве.

---

## 9. Ссылки

- `Onset/Recording/Capture/CameraSource.swift` — актор камеры, videoQueue
- `Onset/Recording/Capture/CameraSourceShims.swift` — `VideoOutputShim`, конверсия PTS
- `Onset/Recording/Capture/CameraSource+SessionSetup.swift` — `activateFormat`, пиннинг
- `Onset/Encode/VideoEncoder.swift` — `ingest`, `submit`, backpressure gate, clock task
- `Onset/Encode/CFRNormalizer.swift` — `catchUpThenEncode`, `catchUpHolds`, grace window
- `Onset/Encode/VideoEncoder+Configuration.swift` — `RealTime`, `AllowFrameReordering`
- `Onset/Configuration/RecordingConfiguration.swift` — `allowFrameReordering: false`, KDoc
- `docs/architecture/drop-accounting.md` — учёт дропов по стадиям пайплайна
- `docs/quality/production-quality-bar.md` — целевые метрики и условия измерения
- Issue #102: CFR-clock, slow emitter, hold-vs-real race
- Issue #104: screen gate_drop residual, 4K60
- Issue #112: camera fresh content loss, B-frames root cause
