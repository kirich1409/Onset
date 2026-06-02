---
type: spec
slug: onset-recording-mvp
date: 2026-06-02
status: approved
platform: [desktop]
surfaces: [ui, background-job]
risk_areas: [perf-critical, pii]
non_functional:
  sla: "HW HEVC-энкодер обязателен; CFR; файл валиден при краше; dropped frames наблюдаемы"
  a11y:
acceptance_criteria_ids: [AC-1, AC-2, AC-3, AC-4, AC-5, AC-6, AC-7, AC-8, AC-9, AC-10, AC-11, AC-12]
design:
  figma:
  design_system: docs/design-ref/
---

# Spec: Onset — Recording (MVP Core)

Date: 2026-06-02
Status: approved
Slug: onset-recording-mvp

---

## Context and Motivation

Ядро Onset: пользователь выбирает источник экрана, камеру и микрофон, нажимает «Записать» — и получает два отдельных файла (экран и камера), каждый со звуком выбранного микрофона, готовые к монтажу в NLE. Это самый минимальный полезный продукт: zero-config, без меню настроек. Технический фундамент — path B (два независимых low-level пайплайна) из [`onset-product-overview`](2026-06-02-onset-product-overview.md). Источник истины UI — макеты `docs/design-ref/main/` (главный экран), `docs/design-ref/recording/` (окно записи), `docs/design-ref/menu-bar-recording/` (menu bar). Предусловие — разрешения из [`onset-permissions-onboarding`](2026-06-02-onset-permissions-onboarding.md).

## Acceptance Criteria

- [ ] **AC-1** — Главный экран показывает три селектора: Дисплей (если дисплеев > 1; иначе единственный выбран по умолчанию), Камера (устройство) и Микрофон (устройство), плюс live-превью выбранной камеры. Настроек кодека/контейнера/разрешения/папки на экране нет.
- [ ] **AC-2** — Активация кнопки «Записать»: (а) при наличии хотя бы одного видео-источника (экран или камера) кнопка активна; (б) если доступный микрофон есть, но не выбран в пикере — кнопка disabled + подсказка «Выберите аудио-вход, чтобы начать запись» (макет пустого состояния); (в) если микрофон недоступен (нет устройства / нет разрешения) — кнопка активна, запись идёт без аудио, рядом индикатор «без звука». Отсутствие микрофона НЕ блокирует запись (согласовано с graceful «Записать без звука» онбординга).
- [ ] **AC-3** — По «Записать» стартует запись: открывается окно записи (статус «● ИДЁТ ЗАПИСЬ», таймер, чек-лист источников с параметрами, кнопка «Остановить») и menu bar переходит в состояние Recording (● + таймер).
- [ ] **AC-4** — Записываются **два файла** в `~/Movies/Onset/`: экран и камера, кодек **HEVC Main 8-bit**, контейнер **.mp4 (hvc1)**, **CFR**. Звук выбранного микрофона пишется в **оба** файла.
- [ ] **AC-5** — Экран пишется с разрешением выбранного дисплея, **но не выше cap по бюджету encode-движка** (CapabilityProbe; дефолт ≤ 4K60 — дисплеи 5K/6K downscale до вписывания), CFR (целевой fps = **min(нативная частота обновления дисплея, 60)**: дисплей ≤60 Гц → его частота; 120 Гц → 60, кратным понижением; >60 — post-MVP). Камера — авто-выбранный формат (наибольшее разрешение при fps ≥ 30; CFR на своём fps). Разные fps экрана и камеры допустимы и пишутся независимо.
- [ ] **AC-6** — Перед стартом `CapabilityProbe` проверяет наличие аппаратного HEVC-энкодера; если HW-энкодер недоступен, запись **не стартует молча в software** — показывается сообщение об ошибке.
- [ ] **AC-7** — Файлы выровнены на общем таймлайне: оба `AVAssetWriter` стартуют `startSession(atSourceTime:)` от **одной** host-time эпохи старта сессии; PTS каждого сэмпла приведены к этому корню через `CMClock.convertTime` per-sample. Звук микрофона в обоих файлах **семплово идентичен** (один `CMSampleBuffer`, одно приведение PTS, дублируется в оба input'а) → audio-waveform авто-sync. Расхождение видео между файлами по общему host-time ≤ 1 кадр на макс. fps. (Не «покадровое совпадение» — fps потоков различаются.)
- [ ] **AC-8** — Пропущенные кадры считаются **раздельно по причинам** (backpressure энкодера/диска vs late-кадр камеры; отсутствие нового кадра статичного экрана в SCStream НЕ считается дропом) и отображаются в окне записи. Degraded (🟡⚠ + таймер) включается при backpressure-дропах > порога за скользящее окно T секунд (порог и T — параметры конфигурации, калибруются post-MVP; единичный исторический дроп не деградирует).
- [ ] **AC-9** — Остановка доступна тремя путями: кнопка «Остановить» в окне записи, глобальный hotkey ⌘⌥⌃R, действие из menu bar. По остановке оба файла финализируются и становятся валидными; пользователю показывается результат (reveal в Finder и/или уведомление). **Если за сессию были существенные backpressure-дропы — результат несёт предупреждение** («запись завершена, пропущено N кадров — возможны рывки»).
- [ ] **AC-10** — При аварийном завершении приложения во время записи уже записанная часть обоих файлов остаётся валидной и проигрываемой; теряется не более одного `movieFragmentInterval`-окна хвоста (проверка: `kill -9` во время записи → оба файла открываются, потеря хвоста ≤ интервала).
- [ ] **AC-11** — Graceful по разрешениям: без доступа к экрану пишется только файл камеры; без микрофона — файлы пишутся без аудио-дорожки; без камеры — только файл экрана. Невозможность записать ни экран, ни камеру блокирует старт.
- [ ] **AC-12** — При отзыве разрешения (экран / камера / микрофон) во время активной записи затронутый поток останавливается, его файл финализируется валидным (`movieFragmentInterval`), захват по отозванному разрешению прекращается немедленно; второй поток продолжает запись.

**Authoritative definition of done.** Реализующий агент валидирует против этого списка.

## Prerequisites

| Prerequisite | Status | Owner | Notes |
|--------------|--------|-------|-------|
| Разрешения (Screen/Camera/Mic) выданы | ⬜ Gate | — | Обеспечивается `onset-permissions-onboarding`; запись использует effective permissions |
| Каталог `~/Movies/Onset/` | ⬜ Todo | Agent | Создавать при первом запуске записи, если отсутствует |
| Регистрация глобального hotkey ⌘⌥⌃R | ⬜ Todo | Agent | Через системный API глобальных горячих клавиш |

## Affected Modules and Files

| Module / File | Change type | Notes |
|---------------|-------------|-------|
| `Capture/ScreenSource` | New | `SCStream` + `SCStreamConfiguration` (нативное разрешение, CFR `minimumFrameInterval`), `SCStreamOutput` → CVPixelBuffer + host-time |
| `Capture/CameraSource` | New | `AVCaptureSession` + выбранный `AVCaptureDevice`, авто `activeFormat`, `AVCaptureVideoDataOutput` |
| `Capture/MicrophoneSource` | New | выбранный аудио-`AVCaptureDevice`, `AVCaptureAudioDataOutput`; один поток → оба writer'а |
| `Capture/DeviceDiscovery` | New | списки дисплеев (`SCShareableContent`), камер и микрофонов (`AVCaptureDevice.DiscoverySession`) |
| `Encode/VideoEncoder` | New | `VTCompressionSession` HEVC; настройки записи (см. ниже); один инстанс на поток |
| `Encode/FileWriter` | New | `AVAssetWriter` (.mp4/hvc1) + video/audio `AVAssetWriterInput`(PixelBufferAdaptor); `movieFragmentInterval` |
| `Recording/RecordingSession` | New | Оркестрация двух пайплайнов, общий host-time clock, старт/стоп, финализация |
| `Recording/DualFileOutputStage` | New | event-driven: каждый источник → свой энкодер/файл; микрофон-буфер дублируется в оба |
| `Capability/CapabilityProbe` | New | HW HEVC-энкодер (Require/Using) перед стартом |
| `Capability/DropMonitor` | New | счётчик пропущенных кадров (SCStream drop / AVCaptureVideoDataOutput drop delegate / `isReadyForMoreMediaData`), сигнал Degraded |
| `Configuration/RecordingConfiguration` | New | дефолт-профиль MVP (HEVC/.mp4/CFR/папка); читается базовым экраном |
| `UI/Main/MainView` | New | Селекторы источников, превью камеры, кнопка Записать (по макету main) |
| `UI/Recording/RecordingView` | New | Окно записи (таймер, dropped frames, чек-лист, Остановить) |
| `UI/MenuBar/MenuBarController` | New | `MenuBarExtra`: Idle/Recording/Degraded + таймер |
| `Hotkey/GlobalHotkey` | New | ⌘⌥⌃R старт/стоп |
| `Storage/RecordingOutput` | New | пути/имена файлов; reveal в Finder; (опц.) метаданные через SwiftData |

Key integration points:
- `PermissionsService.effectivePermissions` (из onboarding) определяет, какие источники доступны.
- `RecordingConfiguration` — дефолт-профиль; в MVP не редактируется UI (two-tier — post-MVP).

## Technical Approach

### Главный экран — дельта от макета `docs/design-ref/main/`
Макет показывает ПОЛНУЮ версию. MVP-экран — строгое подмножество. Контракт «что из макета остаётся / удаляется / read-only»:

| Элемент макета | В MVP |
|---|---|
| Секция ЭКРАН: тумблер «Запись экрана» | Остаётся (вкл/выкл записи экрана) |
| Секция ЭКРАН: селектор Дисплея | Остаётся (скрыт/задизейблен при единственном дисплее) |
| Секция ЭКРАН: режимы Весь экран/Область/Окно | **Удалено** (режим = Весь дисплей фикс; Область/Окно — Phase 2) |
| Секция КАМЕРА: селектор Устройства | Остаётся |
| Секция КАМЕРА: Разрешение, Частота кадров | **Удалено** (авто; Phase 2) |
| Секция КАМЕРА: превью | Остаётся (`AVCaptureVideoPreviewLayer`) |
| Секция МИКРОФОН: селектор Устройства | Остаётся |
| Секция МИКРОФОН: уровень-meter | **Удалено** (Phase 2) |
| Секция ВЫВОД: Кодек, Контейнер, Папка, warning | **Удалена целиком** (HEVC/.mp4/`~/Movies/Onset` фикс; Phase 2) |
| Кнопка «Записать» | Остаётся |
| Строка-сводка внизу («экран + камера + микрофон · …») | Упрощённая: перечень активных источников; оценку битрейта/места — опционально (не блокер MVP) |

Удалённые секции **убираются из layout целиком** (не disabled-заглушки), экран перекомпоновывается компактно. Скрытые параметры живут в дефолт-профиле `RecordingConfiguration`.

### Состояния источников → вид UI (контракт с effectivePermissions)
Главный экран реагирует на `effectivePermissions` и наличие устройств:

| Источник / состояние | Селектор | Превью / индикатор |
|---|---|---|
| Экран: granted | активен (выбор дисплея) | — |
| Экран: denied | задизейблен + «Доступ к экрану не выдан» + ссылка в онбординг | — |
| Камера: granted, устройство есть | активен | live-превью |
| Камера: denied / нет устройства | задизейблен + пояснение | placeholder вместо `AVCaptureVideoPreviewLayer` (не пустой слой) |
| Микрофон: granted, не выбран | активен | подсказка «Выберите аудио-вход» (кнопка Record disabled — AC-2б) |
| Микрофон: denied / нет устройства | задизейблен | индикатор «без звука» (Record активна — AC-2в) |
| 0 видео-источников (ни экрана, ни камеры) | — | пустое состояние «Запись недоступна — выдайте разрешения» + кнопка возврата в онбординг |

### Захват
- **Экран:** `SCStream` с `SCStreamConfiguration`: `width/height` = разрешение выбранного дисплея (с учётом cap из pre-flight, см. ниже); `minimumFrameInterval = CMTime(1, targetFps)`, где `targetFps = min(нативная частота дисплея, 60)` — частота дисплея определяется на старте (зависит от разрешения), 120 Гц пишется как 60; подходящий `pixelFormat` (8-bit 4:2:0, напр. `420v`); `queueDepth` достаточный для backpressure. `SCContentFilter` = весь дисплей. `SCStreamOutput` отдаёт `CMSampleBuffer` (IOSurface-backed) на выделенной `sampleHandlerQueue`.
- **Камера:** `AVCaptureSession` (НЕ MultiCam) с выбранным `AVCaptureDevice`; `activeFormat` подбирается авто-эвристикой (наибольшее разрешение среди форматов с поддерживаемым fps ≥ 30; при равенстве — больший fps). `AVCaptureVideoDataOutput` → `CVPixelBuffer` на своей очереди.
- **Микрофон:** выбранный аудио-`AVCaptureDevice` → `AVCaptureAudioDataOutput`; единый аудио-поток дублируется в audio-вход обоих файлов.

### Кодирование (на поток)
`VTCompressionSession` HEVC со свойствами (из research v2.1):
- `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder = true` (детект HW; падение = нет HW → ошибка пользователю).
- `ProfileLevel = HEVC_Main_AutoLevel`, 8-bit, color SDR Rec.709.
- `RealTime = true`; `AllowFrameReordering = true` (B-кадры, лучше сжатие — файл не стриминг).
- Rate control: VBR — `AverageBitRate` + `DataRateLimits` (peak-cap). Целевые средние битрейты — диапазонами под разрешение/fps (калибровать; см. Open Questions).
- `MaxKeyFrameInterval` — стабильный (для CFR/seek), разумный GOP.

### CapabilityProbe и pre-flight бюджет
На старте записи (до захвата):
1. **HW-энкодер** — тестовый `VTCompressionSession` с `RequireHardwareAcceleratedVideoEncoder`; падение / `Using==false` → HW нет → запись не стартует, сообщение (AC-6).
2. **Pre-flight бюджет под фактическое разрешение** — оценить суммарный pixel-rate выбранных источников (`экран_w×h×fps + камера_w×h×fps`) против бюджета движка. Research-якорь: один движок ≈ 4K120 ≈ ~995M px/s; 4K60+1080p60 ≈ 0.62×, 5K60+камера ≈ 1.01–1.14× (НЕ влезает на 1-движковый чип). При превышении — **стартовать с пониженного стартового профиля** (downscale экрана до вписывания, дефолт ≤ 4K60; при необходимости fps 60→30). Это корректный стартовый профиль, НЕ runtime-авто-деградация (та — post-MVP). Применяет cap из AC-5.

Pre-flight даёт защиту от сценария «M1 Air + внешний 5K-монитор → непрерывный backpressure → час брака»: на слабом чипе с большим дисплеем запись стартует уже в выполнимом разрешении, а не пишет брак под молчаливым Degraded.

### Запись в файл
`AVAssetWriter` (fileType `.mp4`, codec tag `hvc1`) с video `AVAssetWriterInput` (или `AVAssetWriterInputPixelBufferAdaptor`) + audio `AVAssetWriterInput`. **`movieFragmentInterval`** задан (устойчивость к крашу). Имена: `~/Movies/Onset/Onset YYYY-MM-DD HH.mm.ss — Screen.mp4` и `— Camera.mp4` (единый timestamp на сессию записи).

### CFR
Каждый поток пишется с фиксированным целевым fps; **VFR недопустим** (ломает NLE). Экран — `minimumFrameInterval` фиксирует сетку на стороне SCStream. Камера даёт джиттер UVC → нормализация к сетке fps:
- **Snap PTS к ближайшему слоту сетки `CMTime(1, fps)`, сохраняя привязку к host-time-якорю** (не независимый счётчик кадров — иначе накопление дрейфа против экрана и подрыв AC-7).
- **«Дырка» (камера не дала кадр на слот)** → hold: повтор последнего `CVPixelBuffer` в энкодер на этот слот.
- **«Лишний/ранний» кадр (два в один слот)** → drop с инкрементом отдельного счётчика `cfrNormalizationDrops`.
- **Нормализационные дропы/дубли — штатный механизм CFR, НЕ Degraded** (в отличие от backpressure-дропов). Учитываются отдельно от `encoderBackpressureDrops`.

Уточнение к «event-driven, нативный fps» (product-overview принцип 2): «ноль дублирования» — описание идеального случая (источник попадает в сетку), а не инвариант; при реальном джиттере CFR обеспечивается hold/drop на промахах сетки.

### Синхронизация
- **Общий clock-корень — `CMClockGetHostTimeClock()`** (единый стабильный host-clock; не `synchronizationClock` одной из подсистем, чтобы корень не зависел от порядка старта).
- **Единая эпоха старта.** `RecordingSession` фиксирует `T0 = host-time момента старта сессии`. Оба `AVAssetWriter` вызывают `startSession(atSourceTime: T0)` от **одной и той же** эпохи — иначе внутренние таймлайны файлов разъедутся на дельту прихода первых кадров (этого недостаточно покрыть только per-sample конверсией).
- **Порядок старта.** Подготовить оба пайплайна (writer'ы в состоянии `.writing`, `startSession(atSourceTime: T0)` вызван) ДО старта захвата; затем стартовать источники (`SCStream.startCapture()` и `AVCaptureSession.startRunning()` — порядок между ними не важен, т.к. эпоха уже зафиксирована). Кадры с host-time < T0 отбрасываются.
- **Per-sample конверсия.** PTS каждого `CMSampleBuffer` приводится к host-clock через `CMClock.convertTime(_:to:)` per-sample (не разовый offset — иначе дрейф на длинной записи).
- **Mic fan-out.** Один `CMSampleBuffer` микрофона приводится к PTS один раз, затем отправляется в **каждый** writer-actor независимо; append к каждому writer'у сериализован на его собственном actor (нет общего shared-append — `AVAssetWriterInput.append` не потокобезопасен). Звуковые дорожки обоих файлов от одного буфера → семплово идентичны.

### Concurrency
Каждый пайплайн (экран, камера) — изолированный actor; падение одного не роняет второй. `AVAssetWriterInput.append` не потокобезопасен → все append к одному writer'у сериализованы на его actor, гейт на `isReadyForMoreMediaData`. Очереди delegate'ов источников не смешиваются.

### Dropped frames / Degraded
`DropMonitor` — отдельный actor (или `@MainActor`-observable), принимающий сигналы от recorder-actor'ов через async-каналы; UI читает его published-состояние. **Счётчики раздельны по семантике** (объединение даёт ложные Degraded):
- `encoderBackpressureDrops` — `isReadyForMoreMediaData == false` после таймаута ожидания (энкодер/диск не успевает). **Главный сигнал нехватки → триггер Degraded** (AC-8).
- `captureDrops` — `captureOutput(_:didDrop:)` камеры (late/discarded на capture-очереди).
- `cfrNormalizationDrops` — штатные дропы CFR-нормализации (НЕ Degraded).
- Отсутствие нового кадра экрана в SCStream при статичном UI — **НЕ дроп** (SCStream легально не шлёт неизменившиеся кадры; закрывается hold-кадром CFR).

Degraded-триггер (AC-8) вешается на `encoderBackpressureDrops` за скользящее окно, не на сумму. Источник backpressure логируется с признаком «энкодер vs writer/диск» (данные для post-MVP тиров). **Авто-изменение параметров во время записи в MVP не делается** — только наблюдение (калибровка и авто-тиры — post-MVP). Защитный pre-flight — см. ниже.

### Остановка и финализация
Стоп (кнопка / hotkey / menu bar) → остановить источники → `markAsFinished()` всех input'ов → `finishWriting()` обоих writer'ов **параллельно** (`async let`; независимость писателей; падение финализации одного не прерывает второй) → проверить статус каждого → reveal в Finder и/или уведомление (с предупреждением о дропах — AC-9). Окно записи закрывается, menu bar → Idle.

### Окна и menu bar (жизненный цикл)
Onset — menu bar утилита (`MenuBarExtra`) + окна.
- **Menu bar Idle (○)** — клик открывает меню/popover: «Открыть Onset» (главное окно), «Начать запись» (если источники уже валидны — старт; иначе открывает главный экран), «Выход». Из menu-bar-only состояния (окна закрыты) это единственная точка входа.
- **Menu bar Recording (● таймер) / Degraded (🟡⚠ таймер)** — клик: «Остановить», «Открыть окно записи».
- **Переход в запись.** По «Записать» главное окно **скрывается**, открывается окно записи (`RecordingView`). Источники во время записи менять нельзя (макет: «Настройки недоступны во время записи») — окно записи их показывает read-only чек-листом.
- **После остановки** — окно записи закрывается; возврат на главный экран (если он был исходной точкой) либо menu-bar-only (если запись стартовала из menu bar). Фокус — на результат (reveal/уведомление).
- **Красная кнопка в title bar окна записи** (макет) — это **альтернативный «Остановить»** (тот же эффект, что основная кнопка и hotkey; учтена в AC-9 как один из путей, не отдельный). Если в реализации окажется чисто индикатором — сделать non-interactive; не вводить четвёртый расходящийся control.
- **a11y:** см. кросс-режущий принцип 13 overview — состояния не только цветом (текст «ЗАПИСЬ»/«ДЕГРАДАЦИЯ» + иконка), таймер и счётчик дропов — VoiceOver live-region, все интерактивы с `accessibilityLabel`.

### Graceful
`RecordingSession` стартует пайплайны по `effectivePermissions`: нет экрана → только камера-файл; нет камеры → только экран-файл; нет микрофона → файлы без audio-input. Старт блокируется, если нет ни экрана, ни камеры.

## Technical Constraints

- API: ScreenCaptureKit, AVFoundation, VideoToolbox, Core Media; SwiftUI + AppKit (menu bar, hotkey, Finder reveal). Без сторонних медиа-библиотек.
- HW HEVC-энкодер обязателен (`Require`); software-fallback запрещён молча.
- CFR обязателен; VFR запрещён.
- `movieFragmentInterval` обязателен.
- `AVAssetWriterInput.append` строго сериализован; не блокировать main thread.
- Не использовать `AVCaptureMultiCamSession`, `SCRecordingOutput` (основной путь), Presenter Overlay.
- Логирование — `os.Logger`; не логировать имена устройств/пути как PII без нужды.
- Параметры записи в MVP берутся из дефолт-профиля `RecordingConfiguration` и не редактируются UI.
- **Zero-copy путь:** вход `VTCompressionSession` — IOSurface-backed `CVPixelBuffer` без CPU-копий. Pixel format источников приводится к энкодер-совместимому (`420v`/`420f`) на захвате; для камеры зафиксировать pixel format в `AVCaptureVideoDataOutput.videoSettings` (UVC может отдать UYVY/NV12/BGRA — иначе скрытая поквадровая конверсия). Конверсия — только если источник не отдаёт совместимый формат, и она учитывается в бюджете.
- **Глобальный hotkey** — через `RegisterEventHotKey` (Carbon-class), без Accessibility/Input Monitoring (нет 4-го TCC, MAS-ready). Hotkey активен только когда запись возможна/идёт; во время онбординга (нет разрешений) нажатие игнорируется (не стартует запись без разрешений).
- **`movieFragmentInterval`** — задать (рекомендуется 2–5 с; определяет максимальный теряемый хвост при краше — AC-10).
- **Права файлов:** каталог `~/Movies/Onset/` и файлы создаются с владельцем-пользователем, без group/other-доступа; не использовать `/tmp`, `/Users/Shared` или иные world-readable локации даже как промежуточные (запись экрана может содержать чувствительные данные).
- **Storage за абстракцией** `Storage`-слоя: MVP — прямой `~/Movies` (Developer ID, без sandbox); post-MVP MAS добавляет security-scoped bookmark/NSSavePanel без переписывания вызывающего кода.

## Decisions Made

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Главный экран MVP | 3 селектора + превью камеры, без настроек | Zero-config; настройки — post-MVP (two-tier) |
| Кодек/контейнер | HEVC Main .mp4/hvc1, CFR, фикс | research decode-матрица; без выбора в MVP |
| Звук | Один микрофон в оба файла | Явное требование + audio-waveform sync в NLE |
| Файлов | 2 (экран + камера) | Явное требование (макетное «3» — расхождение) |
| Sync | host-time + convertTime per-sample | Кросс-файловое выравнивание без дрейфа |
| Деградация | Наблюдение (счётчик + Degraded), без авто-тиров | Калибровка на железе post-MVP (M1 Air … M3 Max) |
| Папка | `~/Movies/Onset/` фикс | Без UI-выбора в MVP |
| Остановка | Кнопка + hotkey ⌘⌥⌃R + menu bar | Все три в макетах |
| Превью камеры | В MVP | В макете; дёшево (`AVCaptureVideoPreviewLayer`) |
| Активация «Записать» | ≥1 видео-источник; микрофон не обязателен | Согласовано с graceful «Записать без звука»; различать «не выбран» vs «недоступен» (AC-2) |
| Разрешение экрана | Cap по бюджету движка (pre-flight); дефолт ≤ 4K60, 5K/6K downscale | research считал 4K60; 5K на 1-движковом чипе не влезает |
| Sync двух файлов | Единая `startSession(atSourceTime: T0)` эпоха + `CMClockGetHostTimeClock` + per-sample convert | Только per-sample конверсии недостаточно — таймлайны разъедутся |
| Hotkey | `RegisterEventHotKey` | Без 4-го TCC (Accessibility), MAS-ready |
| Деградация MVP | Наблюдение (раздельные счётчики) + pre-flight стартовый cap; без runtime-авто-тиров | Защита от брака на слабом чипе без полной авто-деградации (post-MVP) |

## Out of Scope

- Меню настроек, выбор кодека/контейнера/разрешения/fps/папки — *(Phase 2)*
- Режимы «Область»/«Окно» захвата экрана — *(Phase 2)*
- Системный звук, per-file микрофон — *(Phase 2/3)*
- Composite PiP, ProRes/H.264 опции — *(Phase 3)*
- Авто-деградация (понижение параметров) + performance-test — *(Phase 3)*
- Уровень микрофона (live meter), пауза записи, постобработка/обрезка — *(later)*
- SMPTE timecode-track — *(Phase 2)*

## Open Questions

- [x] **РЕШЕНО** Эвристика авто-выбора формата камеры: дефолт = **наибольшее доступное разрешение** среди форматов с fps≥30 (опрос `AVCaptureDevice.formats`; Brio → 4K30; встроенная камера MacBook → её максимум, напр. 1080p/720p). Явный пользовательский выбор формата — post-MVP (Phase 2, настройки).
- [x] **РЕШЕНО** Целевой fps экрана: определять нативную частоту обновления дисплея (зависит от разрешения) и писать **min(native, 60)** CFR. 120 Гц → 60 (кратное понижение). Частота >60 — post-MVP.
- [ ] Целевые битрейты HEVC (VBR average + peak) по разрешению/fps — *non-blocking*
  - Recommendation: задать диапазонами как стартовую гипотезу, калибровать при обкатке (M1 Air … M3 Max)
- [ ] `DataRateLimits` может вернуть `kVTPropertyNotSupportedErr` на части энкодеров — *non-blocking, implementation-time*
  - Recommendation: graceful fallback на `AverageBitRate`-only при ошибке установки peak-cap; залогировать
- [ ] Точное имя константы HEVC AutoLevel в SDK macOS 26.5 (`kVTProfileLevel_HEVC_Main_AutoLevel`) — *non-blocking, implementation-time*
  - Recommendation: подтвердить по актуальному заголовку VideoToolbox перед кодом (research-отчёт пометил как Known Unknown)

## Future Phases

См. roadmap в [`onset-product-overview`](2026-06-02-onset-product-overview.md) (Phase 2 — настройки/режимы; Phase 3 — аудио-расширение/composite/деградация-тиры/performance-test).
