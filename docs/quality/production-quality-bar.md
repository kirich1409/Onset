# Production Quality Bar

Документ описывает измеримые критерии «с чем можно выходить» для Onset. Это **живой документ** —
критерии корректируются по мере изменения железного стенда, накопления данных и закрытия issues.
Правка планки = PR с обновлением раздела «Последнее обновление».

Критерии построены не от идеала, а от **пользовательского восприятия**: слайдшоу, артефакты,
битые файлы, молчаливая потеря данных — это блокеры. Субоптимальное, но честно
атрибутируемое поведение — не блокер, если пользователь информирован.

---

**Последнее обновление:** 2026-07-02 (v0.5)
**Владелец:** @kirich1409
**Статус критериев:** черновик (v0.5) — §2.1/§5/§6: снят кэп «4K недостижимо через AVFoundation /
требует CMIO/IOKit» ([#177](https://github.com/kirich1409/Onset/issues/177) superseded #265); record
path пишет native 4K с MX Brio (L5 2026-07-02, ноль потерь под worst-case нагрузкой); 60fps остаётся
недостижим (Brio hardware-constraint, [#178](https://github.com/kirich1409/Onset/issues/178))

---

## 1. Назначение

Этот файл — единственный источник истины для acceptance-критериев перф- и качество-фиксов:

- до начала фикса — задаёт, что именно починить (контракт);
- после фикса — служит чеклистом для `scripts/verify-cfr.sh` и телеметрии;
- при регрессии — позволяет однозначно установить, какой конкретный критерий нарушен.

**Предложить изменение:** открыть PR с правкой этого файла, обновить «Последнее обновление»
и статус затронутых строк. Мнения приветствуются в виде Review-комментариев.

## 2. Поддерживаемая матрица устройств

Минимальный набор конфигураций, которые обязаны работать корректно (по состоянию на 2026-06-07).

### 2.1 Камера

Матрица разбита на два яруса. **Tier 0 (baseline)** гоняется при каждой приёмке — это минимум, который должен работать у любого пользователя Onset. **Tier 1 (extended)** — production-сетап владельца; проверяется при наличии подключённого устройства. Наличие MX Brio у пользователя не предполагается — устройство опциональное (см. также §3.4 graceful-поведение и §6).

#### Tier 0 — baseline (минимум для любого пользователя)

| Устройство | Режим | Статус поддержки |
|---|---|---|
| MacBook Pro (встроенная камера FaceTime HD) | 16:9-режим (авто, ≥30 fps; напр. 1920×1080) | ✅ автовыбор подтверждён (live: 1920×1080); реально ~30 fps |

#### Tier 1 — extended (production-сетап владельца)

| Устройство | Режим | Статус поддержки |
|---|---|---|
| Logitech MX Brio | **1080p** 16:9 (автовыбор; реально ~20 fps из-за AE-droop UVC) | ✅ функционально работает; критерии качества ❌ (#112). Brio рекламирует 60fps, AVFoundation доставляет ~20fps (L5-verified, [подробности](macos-avfoundation-camera-limits.md)) |
| Logitech MX Brio | **4K30** (record path — `allowAboveFullHD: true`) | ✅ достижимо через AVFoundation, hold-lock через `startRunning()` ([#265](https://github.com/kirich1409/Onset/issues/265)); [#177](https://github.com/kirich1409/Onset/issues/177) закрыт как superseded. L5 2026-07-02: camera 4K + экран 4K60 записаны с нулём потерь даже под полноэкранным движением ([подробности](macos-avfoundation-camera-limits.md)) |
| Logitech MX Brio | **1080p60** | Future — [#178](https://github.com/kirich1409/Onset/issues/178) закрыт как hardware-constraint Brio (~24–25 fps на любом конфиге, не лимит AVFoundation/macOS, не фиксится сменой стека захвата) |

> **Примечание:** MX Brio — опциональное внешнее устройство; его отсутствие не является ошибкой.
> Приложение обязано корректно работать без него (нет краша, понятное состояние UI — §3.4).

> **MVP-скоуп камеры (issue #145, #113 закрыт):** камера пишется в **16:9**, авто-выбором, без
> ручного пикера режима. `CameraFormatSelector.pickBestFormat` выбирает наибольший 16:9-формат с
> `maxFps ≥ 30`; на record-пути (`allowAboveFullHD: true`) — наибольшее доступное разрешение (4K,
> когда камера его отдаёт); на preview/device-list пути (`allowAboveFullHD: false`, дефолт) — кэп
> ≤ 1080p. При fps-равенстве — бо́льший fps. Реальная доставка: встроенная FaceTime HD — 1080p30
> (чисто); MX Brio — record-путь пишет native 4K, ~26–30 fps (L5-verified 2026-07-02). 60fps
> **недостижим через AVFoundation на macOS** ни на одной из этих камер (Brio hardware-constraint,
> не лимит стека захвата) — отслеживается в [#178](https://github.com/kirich1409/Onset/issues/178).
> Подробности: [`docs/quality/macos-avfoundation-camera-limits.md`](macos-avfoundation-camera-limits.md).

### 2.2 Экран

| Конфигурация | Статус поддержки |
|---|---|
| Встроенный дисплей MacBook Pro (Retina, нативное разрешение; ProMotion — целевой fps открытый вопрос: фиксированные 60 или адаптивные 120) | ⏳ не проверялось |
| Clamshell (крышка закрыта, встроенный дисплей недоступен; запись внешнего дисплея) | ⏳ не проверялось |
| Оба дисплея подключены (выбор дисплея для захвата) | ⏳ не проверялось |
| Основной дисплей 4K (3840×2160), нативное разрешение, целевой fps 60 | ✅ проверяется |
| Дисплей 1080p (1920×1080), целевой fps 60 | ⏳ не проверялось |

### 2.3 Микрофоны

| Устройство | Статус поддержки |
|---|---|
| Встроенный микрофон MacBook Pro (моно) | ✅ закрыто #105, регресс-canary в логе |
| Logitech MX Brio (стерео USB) | ✅ закрыто #105, регресс-canary в логе |
| Произвольный системный USB-микрофон (моно/стерео) | ✅ закрыто #105 |

## 3. Измеримые критерии

Условия проведения измерений: тихая машина без активной IDE/agent-сессии на захватываемом
экране, дневное освещение + движение в кадре (для проверки mpdecimate), режим High Power
(`powermode 2`), Release-сборка. Подробнее — в §4.

### 3.1 Камера (текущий стенд: MX Brio 1080p ~20 fps)

Критерии применяются к каждому поддерживаемому режиму из §2.1. Данные ниже — замеры 2026-06-07 в режиме 1080p (реально ~20 fps из-за AE-droop UVC — платформенное ограничение, не дефект пайплайна) при дневном свете, пользователь в кадре (контент-валидно; активная agent-сессия на экране — фон умерено загрязнён, но порядок величин однозначен; детали → [#112](https://github.com/kirich1409/Onset/issues/112)).

| Критерий | Порог | Метод | Статус |
|---|---|---|---|
| Выживаемость enc_real | ≥ 95% поданных кадров | телеметрия `enc_real / capture` | ❌ ~84% (enc_real 20.0 / capture 23.8 при тихом прогоне, `cfr-clock-acceptance.md`) |
| Fresh-content rate (mpdecimate) | ≥ 95% номинала (≥ 28.5 fps при 30) | `verify-cfr.sh` ассерт C + mpdecimate | ❌ **пайплайн чист** — CFR-сетка идеальна (ассерт B PASS, gap_count=0), ассерты A/B/D PASS в поле (2026-06-07). Ограничение — доставка самой камеры ~19–23 fps при комнатном освещении: AE поверх пиннинга frame duration снижает фактический fps устройства (платформенное ограничение AVFoundation на macOS; см. [`macos-avfoundation-camera-limits.md`](macos-avfoundation-camera-limits.md)). mpdecimate поле: 16.73 fps (утром: 12.4–13.5). Порог ≥ 28.5 fps не достигается при текущем освещении — hardware-constraint самой камеры (отслеживается в [#178](https://github.com/kirich1409/Onset/issues/178); не лимит AVFoundation, не фиксится сменой стека захвата). Ранее: ~43% номинала до фикса B-frames |
| Capture overflow | ≈ 0/с | телеметрия `capture_overflow` | ✅ полевой прогон 2026-06-07 (владелец в кадре, реальный воркфлоу): encoder overflow 0, gate_drop 0, writer 30.14/с — полоса записи чиста. «12–15/с» из #112 переатрибуированы preview-CameraSource с непотребляемым стримом (телеметрия без тега роли; → [#119](https://github.com/kirich1409/Onset/issues/119)). Оговорка: метрика валидна только после тега роли (#119). |
| tick_lag (camera-актор) | медиана ≤ 10 мс, max ≤ 50 мс | телеметрия `tick_lag_ms` | ✅ avg ≈ 2.3 мс, max ≈ 9 мс (стенд 2026-06-07 после #112). Под 10×CPU load: avg 2.0 / max 6.7 мс — критерий PASS и под нагрузкой. Исторические значения 33–40 мс avg / до 133 мс max — артефакт измерения: старая семантика `tick_lag` фиксировала ~slot-период (33 мс) на здоровом пайплайне; новая (wake-latency) — реальную задержку пробуждения актора |
| Серии дублей — мода | ≤ 2 кадра | `verify-cfr.sh` ассерт D: `MAX_RUN_MODE=2` | ✅ закрыто #102 (до: ~13, после: ≤2) |
| Серии дублей — нет длинных | ни одна серия длиной ≥ 5 не повторяется ≥ 10 раз | `verify-cfr.sh` `LONG_RUN_LEN=5, LONG_RUN_MAX=10` | ✅ закрыто #102 |
| Пакетный rate (файл pkt/s) | отклонение ≤ 2% от номинала | `verify-cfr.sh` ассерт A: `RATE_TOL_PCT=2` | ✅ 30.00 pkt/s (`verify-cfr` ассерт A PASS; стенд 2026-06-07 после #112: B-frames → структурные gate-дропы устранены, gate_drop=0.00/с, pending_max=2.0–2.5). Ранее: 25–27 pkt/s до фикса. Sustained 240s (2026-06-07, инструментированный L5-стенд, MX Brio 1080p30): camera 30.00 / screen 60.00 pkt/s, verify-cfr A PASS обе полосы. Поле 2026-06-07: 30.00/60.00 PASS |
| Равномерность PTS-дельт | ≤ 10 гэпов/мин > 1.5 слота | `verify-cfr.sh` ассерт B | ✅ закрыто #102 (B-frame sorting fix); подтверждено #112: gap_count=0 после отключения B-frames. 240s: gap_count=0 обе полосы (B PASS) |
| Пиксельный формат | 420v (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`) | `ffprobe -show_streams` `pix_fmt` | ✅ `RecordingConfiguration.mvpDefault`: pixelFormat=[.biPlanar420v, .biPlanar420f]; 420v — первый/приоритетный |
| Кодек видео | HEVC / hvc1 | `ffprobe -show_streams` `codec_name`, `codec_tag_string` | ✅ `mvpDefault`: codec=HEVC, sampleEntry=hvc1 (h264 в спеках не заявлен) |

### 3.2 Экран (4K60, основной дисплей)

| Критерий | Порог | Метод | Статус |
|---|---|---|---|
| Пакетный rate в файле | ≥ 95% от 60 fps (≥ 57 pkt/s) **или** честный downgrade конфига resolver'ом | `verify-cfr.sh` ассерт A | ❌ ~66% (~39.5 pkt/s тихий прогон, до 35→6 при экстремальном контенте) — VT-потолок #104; downgrade конфига не применяется, потеря не silent (gate_drop виден в телеметрии) |
| Равномерность PTS-дельт | ≤ 10 гэпов/мин > 1.5 слота | `verify-cfr.sh` ассерт B | ⏳ не измерено изолированно от #104 |
| Отсутствие прогрессирующей деградации | файл pkt/s стабилен на 20+ мин записи | ручной прогон + `verify-cfr.sh` | ❌ при экстремальном контенте: 35→6 pkt/s за 5 мин (#104, testsrc2-видео fullscreen) |
| Эмиссия CFR-сетки | ровно номинал слотов/с, 0 пропусков | телеметрия `grid emissions` | ✅ закрыто #102 (60.0 слотов/с, 0 пропусков, tick_lag 5.9мс) |

### 3.3 Аудио

| Критерий | Порог | Метод | Статус |
|---|---|---|---|
| Валидные файлы с любым системным миком (mono/stereo/USB) | 0 writer faults, hevc+aac, moov на месте | `ffprobe` оба файла | ✅ закрыто #105, canary-подтверждено |
| Выходной формат | AAC 48 kHz / mono / 128 kbps (текущий MVP; стерео — post-MVP, [#92](https://github.com/kirich1409/Onset/issues/92)) | `ffprobe -show_streams` `codec_name`, `sample_rate`, `channels`, `bit_rate` | ✅ `RecordingConfiguration.mvpDefault` + `CameraSourceAudioSettings` |
| Стабильность аудио-формата | canary-лог `DualFileOutputStage` молчит | `log show --predicate 'category == "recording"'` | ✅ закрыто #105 (0 FMT CHANGE в прогонах acceptance) |
| Нет append rejected / writer faulted | 0 в логах за всю запись | `log show` | ✅ закрыто #105 |
| A/V-дрейф | ≤ 50 мс на полной длине записи | PTS-сверка первых/последних пакетов обеих дорожек: `ffprobe -show_packets -select_streams a:0 -read_intervals "%+#5" <file>` + аналогично `v:0`; Δ между первыми PTS audio/video и между последними | ⏳ не измерялся; screen и camera разделяют одну аудио-дорожку с общего T0 — дрейф ожидается низким, требует верификации |

### 3.4 Надёжность и UX

| Критерий | Порог | Метод | Статус |
|---|---|---|---|
| Старт/стоп записи через UI | кнопка Record + Stop работает без зависаний | ручная проверка | ✅ базово работает |
| Глобальный хоткей ⌘⌥⌃R | старт/стоп из фона | ручная проверка | ⏳ не верифицировано системно |
| Сессии ≥ 20 мин без прогрессирующей деградации | pkt/s стабилен на протяжении всей записи | ручной прогон + `verify-cfr.sh` | ❌ при экстремальном контенте: 35→6 pkt/s за 5 мин (#104); стабильность при обычном контенте на ≥20 мин — ⏳ |
| Crash-recovery (fragmented MP4) | файл играбелен после kill; `movieFragmentInterval` = 4 с | `ffprobe` после kill -9; `mvpDefault.movieFragmentInterval` = 4 с | ✅ `mvpDefault` пишет fragmented mp4 (movieFragmentInterval = 4 с) — потеря ≤4 с при crash |
| Fail-fast фатальных фолтов | alert до стопа записи | ручная проверка | ✅ закрыто #105 (покрыто юнит-тестами) |
| Дропы атрибутируются честно | backpressure-дропы vs gate_drop отличимы; `DropCause.dominantCause` несёт доминирующий источник | телеметрия `category=telemetry`; `DropHealthSnapshot.dominantCause` в логах стопа | ✅ `DropCause` + per-source bp-тали реализованы ([#100](https://github.com/kirich1409/Onset/issues/100)); UI per-cause — post-MVP |
| Выбор устройства сохраняется между запусками | камера/микрофон восстанавливаются | ручная проверка | ❌ не имплементировано (#109) |
| Graceful-поведение при отсутствии/отключении внешней камеры | нет краша; UI показывает понятное состояние (нет устройства / выбрать другое); связь с #109/#113 и disconnect-обработкой | ручная проверка (отключить MX Brio во время выбора и во время записи) | ⏳ не верифицировано |

### 3.5 Итоговые файлы

| Критерий | Порог | Метод | Статус |
|---|---|---|---|
| Контейнер | MP4 (`.mp4`); `.mov` в спеках не заявлен | `ffprobe -show_format` `format_name` | ✅ `RecordingConfiguration.mvpDefault`: container=.mp4; `.mov` не используется |
| Схема имён | `Onset-<unix_ts>-screen.mp4` и `Onset-<unix_ts>-camera.mp4` | `ls ~/Movies/Onset/` | ✅ подтверждено в реальных прогонах |
| Оба файла играбельны | moov atom на месте, длительность == записи ±0.5 с, видео-дорожка + аудио-дорожка | `ffprobe -show_streams -show_format` оба файла | ✅ при штатном завершении; crash-recovery — fragmented mp4 (см. §3.4) |
| Целостность после crash | файл открывается в QuickTime / VLC, длительность ≥ записи − 4 с | `ffprobe` после kill -9 | ✅ fragmented mp4, потеря ≤ `movieFragmentInterval` (4 с) |
| Обе дорожки (video + audio) в каждом файле | `nb_streams ≥ 2`, `codec_type` = video + audio | `ffprobe -show_streams` | ✅ закрыто #105 |

### 3.6 Покрытие кода (L2 unit)

| Критерий | Порог | Метод | Статус |
|---|---|---|---|
| Line coverage таргета `Onset` | информационно (жёсткого порога пока нет) | `Onset.xctestplan` (coverage scoped на `Onset`) → `scripts/coverage-summary.sh` по `.xcresult`; сводка в `$GITHUB_STEP_SUMMARY` каждого PR | ⏳ измеряется per-PR; базовая линия копится, порог `ONSET_COVERAGE_MIN` пока выключен |

Покрытие отражает только L2 (чистая логика на фейках); L5 (железо) в CI не гоняется, его
пути в эту метрику не попадают. Калибровка порога — после накопления данных (см. Open
Questions в [`onset-devops-ci`](../specs/2026-06-02-onset-devops-ci.md)).

## 4. Методология измерения

### 4.1 Обязательные условия

- **Тихая машина:** никаких активных agent/IDE-сессий, браузеров, терминалов на записываемом
  экране во время замеров. Активная Claude-сессия вносит 10–30 «fresh» кадров/с даже на
  «статичном» экране — это загрязняет mpdecimate-метрику.
- **Режим:** High Power (`powermode 2`), AC power, Release-сборка.
- **Движение в кадре** для ассерта C (fresh-content): дневной свет, движение объекта. Статичная
  тёмная комната → HEVC давит сенсорный шум → `fresh_fps ≈ 0.01` даже при корректной работе
  энкодера. Ассерт C нельзя использовать в тёмной/статичной сцене. Аналогично ассерт D
  (кластеры дублей) на длинных статичных записях контент-зависим: длинные dup-серии возникают
  из самого контента — 240s статичной сцены дали `long_fail=1` при идеальной CFR-сетке
  (gap_count=0); ассерт D валиден только при свете + движении в кадре, как и C.

### 4.2 Инструменты

| Инструмент | Что проверяет |
|---|---|
| `scripts/verify-cfr.sh <screen> <camera> <screen_fps> <camera_fps>` | Ассерты A–D по фактическим PTS пакетов (не метаданным); exit 0 = PASS |
| `log show --predicate 'subsystem == "dev.onset"' --style json` | Per-stage телеметрия: capture, enc_real, writer, gate_drop, tick_lag |
| `ffprobe -show_streams` | Валидность файла: codec, moov, duration |
| Instruments (Time Profiler / CPU Counters) | Перф-вердикты (#104 диагностика): VT-латентность, contention |
| Ручной прогон ≥ 20 мин | Деградация во времени (fullscreen видео = worst-case нагрузка) |

**Инвариант телеметрии:** `capture ≈ enc_real ≈ writer` (±стат. шум). Расхождение стадий =
stage-specific drop; подробнее — [docs/architecture/drop-accounting.md](../architecture/drop-accounting.md).

### 4.3 Запуск L5 из не-Xcode шелла

Начиная с PR #55 для L5 есть выделенный тест-план. Основной путь:

```bash
xcodebuild test -scheme Onset -testPlan Onset-L5 \
  -destination 'platform=macOS' -configuration Debug ONLY_ACTIVE_ARCH=YES
```

Тест-план `Onset-L5.xctestplan` автоматически выставляет `ONSET_RUN_L5_ENCODE=1` и
`ONSET_RUN_L5_CAPTURE=1`. Запуск конкретного suite:

```bash
xcodebuild test -scheme Onset -testPlan Onset-L5 \
  -destination 'platform=macOS' -configuration Debug ONLY_ACTIVE_ARCH=YES \
  -only-testing:'OnsetTests/VideoEncoderLiveTests'
```

**L5 требует подписанной сборки.** `CODE_SIGNING_ALLOWED=NO` ломает TCC-грант захвата экрана:
test host получает sticky deny до `tccutil reset ScreenCapture` + повторного явного гранта.
Флаг `-only-testing` работает на уровне suite, не отдельной функции.

**Резервный путь (PlistBuddy)** — если тест-план недоступен или нужна ручная инъекция:

1. `xcodebuild build-for-testing` (без `CODE_SIGNING_ALLOWED=NO`).
2. Найти `.xctestrun` в DerivedData, скопировать рядом.
3. `PlistBuddy -c "Set :TestConfigurations:0:TestTargets:0:EnvironmentVariables:<VAR> <VALUE>" copy.xctestrun`.
4. `xcodebuild test-without-building -xctestrun copy.xctestrun`.

### 4.4 Негативный контроль

Baseline записи с багом (до #102): camera 2.88 fps fresh, screen 42.3/60 pkt/s. Файлы:
`~/Movies/Onset/Onset-1780682249/250`. `verify-cfr.sh` обязан FAIL на C и D этого baseline.

## 5. Известные разрывы → issues

| Разрыв | Issue | Приоритет | Суть |
|---|---|---|---|
| Потери кадров камеры — 43% номинала | [#112](https://github.com/kirich1409/Onset/issues/112) | ✅ пайплайн-часть закрыта (PR #118, стенд+поле); device-input (~20 fps доставка камеры при комнатном свете) — платформенное ограничение AVFoundation; preview-телеметрия/чёрный старт → [#119](https://github.com/kirich1409/Onset/issues/119) | Корень — B-frames (`AllowFrameReordering=true`): reorder window держал `NumberOfPendingFrames` ≥ 4, структурно достигая backpressure gate. Фикс: `allowFrameReordering=false` в `mvpDefault`. Полевой прогон (владелец в кадре): encoder overflow 0, gate_drop 0, writer 30.14/с, verify-cfr A/B/D PASS. «12–15/с» overflow переатрибуированы preview-CameraSource (#119). Остаточный fresh-дефицит: AE-ограничение камеры (~19–23 fps при комнатном свете) — платформенное ограничение, не дефект пайплайна |
| Камера 4K30 | [#177](https://github.com/kirich1409/Onset/issues/177) | ✅ закрыт (superseded #265) | Record path пишет native 4K (`allowAboveFullHD: true`); L5 2026-07-02 — ноль потерь под worst-case нагрузкой |
| Камера 60fps | [#178](https://github.com/kirich1409/Onset/issues/178) | 🟡 отслеживается | Hardware-constraint Brio (~24–25 fps на любом конфиге) — не лимит AVFoundation/macOS, не фиксится сменой стека |
| VT-потолок / кросс-полосная конкуренция | [#104](https://github.com/kirich1409/Onset/issues/104) | 🔴 блокер | Screen encoder ~20–42 fps (4K); camera страдает косвенно; #112 закрыт отдельно |
| Конфляция источников дропов | [#100](https://github.com/kirich1409/Onset/issues/100) | ✅ закрыт | `DropCause` per-source тали + `sessionEverDegraded` latch реализованы; UI per-cause — post-MVP |
| EngineBudgetCap требует калибровки | [#97](https://github.com/kirich1409/Onset/issues/97) / [#98](https://github.com/kirich1409/Onset/issues/98) | 🟡 | `EngineBudgetCap` (995M px/s) — плейсхолдер; `CapabilityResolver` молча применяет downscale без user-visible сигнала |
| Персистенция выбора устройств | [#109](https://github.com/kirich1409/Onset/issues/109) | 🟡 | Камера и микрофон сбрасываются на значения по умолчанию при каждом перезапуске |

## 6. Матрица верификации форматов

Прогоняется при приёмке каждого релиза и каждого перф-фикса. Для каждой строки матрицы — отдельный прогон `verify-cfr.sh` + `ffprobe` + телеметрия.

**Baseline-набор** — только встроенное железо MacBook (камера FaceTime HD, встроенный микрофон, встроенный дисплей). Выполняется при **каждой приёмке**, независимо от подключённых внешних устройств.

**Extended-набор** — конфигурации с внешними устройствами (MX Brio). Выполняется при наличии устройства; **обязателен для релизов, затрагивающих capture**. Record path пишет native 4K с Brio ([#177](https://github.com/kirich1409/Onset/issues/177) — superseded #265; L5 2026-07-02, ноль потерь). 1080p60 остаётся недостижим — hardware-constraint Brio (отслеживается в [#178](https://github.com/kirich1409/Onset/issues/178)).

### 6.1 Конфигурации

#### Baseline-набор (выполняется всегда)

| Камера | Микрофон | Экран | Ожидаемый номинал камеры | Ожидаемый номинал экрана |
|---|---|---|---|---|
| Встроенная камера MacBook Pro (FaceTime HD, нативный режим) | встроенный MacBook | встроенный дисплей MacBook | нативный (≥30 fps) | нативный (60 или 120, см. §2.2) |
| Встроенная камера MacBook Pro (FaceTime HD, нативный режим) | встроенный MacBook | 4K60 (внешний) | нативный (≥30 fps) | 60 fps |

#### Extended-набор (при наличии внешних устройств; обязателен для release, затрагивающих capture)

| Камера | Микрофон | Экран | Ожидаемый номинал камеры | Ожидаемый номинал экрана |
|---|---|---|---|---|
| MX Brio 4K30 | Brio USB | 4K60 | 30 fps | 60 fps |
| MX Brio 4K30 | встроенный MacBook | 4K60 | 30 fps | 60 fps |
| MX Brio 1080p60 | Brio USB | 4K60 | 60 fps | 60 fps |
| MX Brio 1080p60 | встроенный MacBook | 4K60 | 60 fps | 60 fps |

### 6.2 Чеклист для каждой конфигурации

Для каждой строки §6.1 все пункты должны быть PASS:

| Проверка | Инструмент / команда | Порог |
|---|---|---|
| ffprobe-валидность screen.mp4 | `ffprobe -show_streams -show_format Onset-*-screen.mp4` | moov, 2 потока (video hevc/hvc1 + audio aac), duration ≠ N/A, pix_fmt = yuv420p (420v) |
| ffprobe-валидность camera.mp4 | `ffprobe -show_streams -show_format Onset-*-camera.mp4` | те же требования |
| verify-cfr экран | `scripts/verify-cfr.sh <screen.mp4> <camera.mp4> 60 <cam_fps>` — ассерт A | rate ≤ 2% отклонения от номинала |
| verify-cfr камера (ассерт A) | то же — ассерт A | rate ≤ 2% от номинала |
| verify-cfr ассерт B (PTS-равномерность) | то же | ≤ 10 гэпов/мин > 1.5 слота для каждого потока |
| verify-cfr ассерт C (fresh-content) | то же — ассерт C | ≥ 95% номинала по mpdecimate (тихая машина, дневной свет, движение) |
| verify-cfr ассерт D (dup-run мода) | то же | мода ≤ 2 |
| A/V-дрейф | `ffprobe -show_packets -select_streams a:0 -read_intervals "%+#5"` + `v:0` → разница первых PTS и последних PTS | ≤ 50 мс |
| Телеметрия: capture overflow | `log show --predicate 'subsystem == "dev.onset"' --style json \| jq '.[] \| select(.eventMessage \| contains("overflow"))'` | ≈ 0/с |
| Телеметрия: writer faults | `log show --predicate 'subsystem == "dev.onset" and category == "recording"'` | 0 faults, canary молчит |
| Телеметрия: tick_lag | то же | avg ≤ 10 мс, max ≤ 50 мс |

## 7. История изменений

| Дата | Версия | Что изменилось |
|---|---|---|
| 2026-07-02 | v0.5 | §2.1/§5/§6: снят кэп «4K недостижимо через AVFoundation / требует CMIO/IOKit» — [#177](https://github.com/kirich1409/Onset/issues/177) закрыт как superseded [#265](https://github.com/kirich1409/Onset/issues/265) (hold-lock через `startRunning()`); record path теперь пишет native 4K с MX Brio, L5 2026-07-02 подтвердил ноль потерь под worst-case полноэкранным движением. 60fps остаётся недостижим — [#178](https://github.com/kirich1409/Onset/issues/178) закрыт как hardware-constraint Brio, не связано со снятием 4K-кэпа |
| 2026-06-08 | v0.4 | Добавлен §3.6 «Покрытие кода»: L2-покрытие таргета `Onset` измеряется per-PR (job-summary + `.xcresult`-артефакт), report-only, порог `ONSET_COVERAGE_MIN` выключен |
| 2026-06-07 | v0.3 | По ревью PR #114: §2.1 — ярусная матрица камер (Tier 0 baseline: встроенная FaceTime HD; Tier 1 extended: MX Brio), примечание об опциональности внешних устройств; §2.2 — добавлены строки встроенного дисплея MacBook (ProMotion fps — открытый вопрос), clamshell, оба дисплея; §3.4 — graceful-поведение при отсутствии/отключении внешней камеры; §6 — матрица верификации разделена на Baseline-набор (только встроенное железо, каждая приёмка) и Extended-набор (внешние устройства, при наличии / обязателен для capture-релизов) |
| 2026-06-07 | v0.2 | Расширен до пяти осей: матрица режимов камеры (#113), обновлены метрики камеры данными #112 (43% номинала, замеры 2026-06-07), добавлены §3.3 аудио-формат + A/V-дрейф, §3.4 UX+hotkey+crash-recovery, §3.5 итоговые файлы, §6 матрица верификации форматов; §5 дополнен приоритетами |
| 2026-06-07 | v0.1 | Первая публикация — черновик на основе acceptance-отчётов #102/#105 и issues #100/#104/#109 |
