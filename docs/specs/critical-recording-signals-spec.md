# Спецификация: активный сигнал о критических проблемах записи

Статус: черновик v3 (после 2 циклов multi-expert review: business-analyst + architecture-expert + ux-expert + performance-expert)
Связано: #246 (UI-показ дропов → disk-отчёт), #242 (menu-bar-first запись), AC-12 (graceful camera revocation)

## Контекст

После #246 на каждую завершённую сессию пишется технический отчёт на диске
(`Onset … — Техническая информация.txt`). Из UI убраны живой счётчик-пилюля
дропов и UI-показ пост-стоп предупреждения. Константа `postStopDropWarningThreshold`
(=5) и путь `degradedWarning` в коде **остались** живыми
(`RecordingCoordinator.swift:172,694`, `RecordingSession.swift:869`) — #246 убрал
UI-поверхность, не логику (подтверждено код-граундингом).

Активного сигнала о **серьёзных** проблемах сейчас нет:

- Индикатор деградации menu bar (жёлтая точка + треугольник) завязан только на
  `encoderBackpressureDrops`, **авто-восстанавливается** — транзиент, не «пожар».
- Потеря камеры обрабатывается (AC-12: `sourceRevocationStream` → координатор →
  `sourceLiveness.camera=false`, чек-лист в окне красным), но в menu-bar-first
  режиме окна нет → пользователь не видит; menu bar потерю не отражает.
- Коллапс fps не детектируется: `StageRateAggregator` считает delivered fps
  (`fresh=`), но только пишет строку в лог — числового readout нет.

Итог: при реальной аварии пользователь узнаёт о ней, только если сам откроет
файл-отчёт.

## Цель

Явные, фальсифицируемые критерии «критической» проблемы записи + активный,
**пропорциональный** сигнал пользователю (индикатор menu bar + системное
уведомление + пост-стоп уведомление), при сохранении disk-only для минорных дропов.

## Не-цели

- Экран настроек порогов (пороги — фикс-константы в конфиг-слое, выносимы позже).
- Восстановление потерянного контента.
- Изменение формата/содержимого дискового отчёта (#246).
- **fpsCollapse на экране** — невозможен корректно: SCK event-driven, `CFRNormalizer`
  штатно заполняет слоты холдами на статике (`docs/architecture/drop-accounting.md`
  §2). Детектим коллапс fps только для камеры (непрерывный источник).
- `UNNotificationInterruptionLevel.critical` (bypass mute) — требует Apple-grant.
- **Talking-head как primary-контент**: MVP считает экран основным треком. Потеря
  камеры при живом экране = `soft` (запись продолжается). Сценарий, где камера —
  единственный важный трек при включённом экране, обрабатывается soft-сигналом +
  пост-стоп нотой, но не эскалируется до «пожара».

## Severity-модель (несущая конструкция)

Два тира. Все критерии маппятся в один из них; тир определяет ВСЁ поведение
сигнала (индикатор, уровень уведомления, латч, дедуп).

| Тир | Инциденты | Индикатор menu bar | Уведомление | Латч |
|---|---|---|---|---|
| **hard** | `cameraOnly`, `sustainedDrops`, `fpsCollapse` | критический октагон | `timeSensitive` (пробивает Focus) | см. lifecycle |
| **soft** | `cameraAndScreen` | без октагона (экран пишется штатно; камера уже красная в чек-листе окна) | `active` | нет |

Порядок severity: `hard > soft`. Применяется к латчу (хранит **max-severity**
увиденного) и к дедупу (hard всегда пробивает ранее показанный soft).

Lifecycle индикатора (две оси — severity × persistence):

- `cameraOnly` (hard, терминальный — запись встала) → латч октагона до stop.
- `sustainedDrops`/`fpsCollapse` (hard, windowed — могут пройти) → октагон
  **live, де-эскалирует** при восстановлении (вернуть degraded/normal-вид); НО
  session-латч «видела hard» сохраняется для пост-стопа. Не пульсировать «пожаром»
  два часа после прошедшего 10-сек всплеска.
- `cameraAndScreen` (soft) → октагона нет; запись экрана идёт штатно.

## Критерии «пожара»

Тип несёт enum `CriticalIncident` (`cameraLost(scope:)` с
`CriticalIncidentScope.cameraOnly | .cameraAndScreen`, `sustainedDrops`,
`fpsCollapse`).

### 1. Потеря камеры (`cameraLost`)

Детект уже есть (AC-12, подтверждено `RecordingCoordinator:595–614`):

- `cameraOnly` (**hard**): `.allVideoSourcesLost` → сессия останавливается,
  `.completed(.cameraOnly)`, файл валиден до обрыва. Запись встала → полный сигнал.
- `cameraAndScreen` (**soft**): камера-файл финализируется корректно, **экран
  продолжает писаться штатно**, сессия `.completed`. Основной трек не теряется.

### 2. Устойчивая деградация (`sustainedDrops`, **hard**)

Эскалация существующего `degraded` (не новый счётчик; питается из существующего
`DropMonitor`/`currentDrops()`, новых данных не требует):

- **Live:** `degraded` держится непрерывно ≥ `criticalSustainSeconds`.
  Транзиент (< порога) остаётся жёлтым/disk-only.
- **Пост-стоп:** нормированная интенсивность дропов ≥ `criticalDropRatePerMin`
  (drops/min) **И** длительность сессии ≥ `criticalDropRateMinSessionSeconds`
  (floor против ложного срабатывания на 2-сек клипе: 21 дроп ≠ 630/min-авария).

### 3. Коллапс fps камеры (`fpsCollapse`, **hard**, «резкая скорость»)

Камера — непрерывный источник; delivered fps не зависит от движения в кадре.
Критерий: резкое падение от собственного baseline + подтверждение проблемой.

- **baseline** = скользящее среднее delivered fps за окно
  `cameraBaselineWindowSeconds` (явно `>> fpsCollapseWindowSeconds`, чтобы 5-сек
  коллапс почти не сдвигал baseline), с отбросом первых `cameraBaselineSkipSeconds`
  (cold-start ramp).
- **freeze baseline**, как только delivered < `fpsCollapseRatio` × baseline:
  просевшие сэмплы НЕ подмешиваются в среднее, пока кандидат активен — иначе
  baseline утягивается вниз и (а) вердикт неидемпотентен, (б) медленный bleed
  никогда не пересекает порог (само-маскирование).
- **срабатывание**: delivered < `fpsCollapseRatio` × baseline устойчиво ≥
  `fpsCollapseWindowSeconds`, **И** одновременно подтверждающий сигнал —
  ненулевой drop/overflow rate ИЛИ `gap_ms_max` > `fpsCollapseGapMsThreshold`.
  Подтверждение отсекает легитимный low-light throttle (Brio в темноте честно
  падает 30→~15fps **без** дропов/gap — не авария).
- база — измеренный baseline, НЕ `ResolvedCameraPlan.fps` (= `CameraFormat.maxFps`,
  завышен: Brio план 60, реально ~20).
- «резкая скорость» = sharp by design; плавный bleed ловится только при наличии
  drop/gap-подтверждения.

## Механизм сигнала

Каналы дополняют друг друга (fallback): окна нет → уведомление основной канал;
индикатор menu bar — вторичный И запасной, когда уведомления запрещены/подавлены.

### Индикатор menu bar (hard)
Критический вид — `exclamationmark.octagon.fill`. Различитель для дальтоников —
**внутренний глиф + цвет (+ опц. пульсация)**, НЕ контур: на 16–18px силуэт
октагона ≈ круг, полагаться на форму контура нельзя. Grayscale-проверка — в
реальном размере status-item.

A11y-label критики — отдельный, per-инцидент (не наследует degraded «запись
деградирована»):
- `cameraOnly`: «Onset, критическая ошибка: камера отключена, запись остановлена»
- `sustainedDrops`/`fpsCollapse`: «Onset, критические потери кадров, <time>»
- `cameraAndScreen` (без октагона, но label обновляется): «Onset, камера
  отключена, запись экрана продолжается, <time>»

### Системное уведомление (live)
Переиспользовать инфраструктуру `RecordingStartNotifier` — **расширив протокол**
`RecordingStartNotifying` новым методом (отдельный identifier/контент; обновить
`FakeRecordingStartNotifier`). Уровень — **по тиру**: hard → `timeSensitive`
(пробивает Focus — доминирующий сценарий записи); soft `cameraAndScreen` → `active`.

Дедуп (per-window, **suppress + severity-override**): первое критическое
уведомление за окно `criticalNotificationDedupeSeconds` подавляет последующие
**того же или меньшего тира**; уведомление **более высокого тира всегда пробивает**
подавление (soft показан → пришёл hard → hard постится). Полную картину всех
инцидентов несёт пост-стоп (ниже) — в live-моменте не спамим.

### Пост-стоп уведомление
Латч пост-стопа хранит **max-severity** увиденного (не Bool). На stop:
- любой **hard** инцидент за сессию → «Запись сохранена, но были серьёзные
  проблемы. Подробности — в технической информации рядом с записью.»
- только **soft** (`cameraAndScreen`, без hard) → мягкая нота «Камера отключилась
  во время записи; экран записан полностью.»
- минорные дропы → пост-стоп тишина (disk-only).

**Actionable**: клик → reveal отчёта в Finder (macOS-конвенция; поведение #246
«не форсировать окно» сохранено).

## Архитектура

- **Детекторы — чистые nonisolated типы** (паттерн `CFRNormalizer`/`CapabilityResolver`):
  `FpsCollapseDetector` (вход: delivered fps + drop/gap rate + baseline-состояние +
  монотонный elapsed + пороги → вердикт + обновлённый baseline) и
  `SustainedDropDetector` (вход: degraded-длительность/drop-rate + монотонный
  elapsed + пороги → вердикт). Время/часы детекторы получают **аргументом**, сами
  не читают — это и держит честность L2-тегов.
- **Латч на координаторе**: `criticalLatch` хранит max-severity `CriticalIncident?`
  (+ его проекция в пост-стоп). `MenuBarLabelMapper` принимает латч вторым входом.
  **НЕ** расширять `RecordingState` новым case — degraded авто-восстанавливается
  (sliding window), critical латчится: разные lifecycle, в одном enum держать
  семантически неверно.
- **`CriticalIncident` — ручные nonisolated witnesses**: enum с associated value
  (`cameraLost(scope:)`), поэтому нужны и `nonisolated static func ==`, и
  `nonisolated func hash(into:)` (как `RecordingState` в PipelineTypes.swift:548,566),
  и то же лечение для `CriticalIncidentScope`.
- **Live-seam fps-снимка (P1) — точный путь доставки**: `currentDrops()`
  (`RecordingSession.swift:470`) сегодня собирается **только** из `DropMonitor`
  (drop-события) и НЕ видит `StageRateAggregator`. Реально новые данные нужны
  **только** `FpsCollapseDetector` — это camera-capture fps/gap-снимок;
  `SustainedDropDetector` питается уже существующим `DropHealthSnapshot`. Поэтому:
  - добавить параллельный pull-метод `currentRates()` (тот же 1 Hz tick), который
    читает **latest-snapshot** камеры под существующей точкой синхронизации
    источника (`captureRateLock.withLock` для capture — `CameraSourceShims.swift:50`),
    БЕЗ сброса аккумулятора;
  - каждый источник публикует latest-snapshot, который `flush` **обновляет** (reset
    остаётся только для лог-строки) — нулевая дополнительная per-frame работа и
    contention; отдельный read-путь к аккумулятору запрещён (stability #1);
  - encoder/writer flush меняется только как контракт сигнатуры (call-site
    компиляция), их снимок детекторам не нужен — НЕ пробрасывать в `currentRates()`;
  - инвариант staleness: координатор пуллит last-flushed значение (источники флашат
    на своих `ContinuousClock`-таймерах), устаревание ≤1 tick (~1 c) — приемлемо
    для окон 5–10 c.
- **P2 часы**: sustain/collapse-окна и дедуп питаются монотонным `elapsedSeconds`
  (host-time от source-flush / `ContinuousClock`), НЕ `Date()`-tick координатора
  (`RecordingCoordinator:627`, остаётся только для UI-elapsed).

## Конфигурация

Константы в `RecordingConfiguration`, с комментарием
`// calibrate post-MVP via L5 (MX Brio); future: expose in Settings`.
Стартовые значения — гипотезы для L5-калибровки:

| Константа | Дефолт | Смысл |
|---|---|---|
| `criticalSustainSeconds` | 10.0 | непроходящая деградация → live hard |
| `criticalDropRatePerMin` | 600 | нормированная интенсивность дропов → пост-стоп hard |
| `criticalDropRateMinSessionSeconds` | 10.0 | floor длительности для применения rate-критерия |
| `fpsCollapseRatio` | 0.5 | доля от baseline, ниже которой — кандидат коллапса |
| `fpsCollapseWindowSeconds` | 5.0 | устойчивость коллапса |
| `fpsCollapseGapMsThreshold` | 250 | gap_ms_max, подтверждающий проблему |
| `cameraBaselineWindowSeconds` | 30.0 | окно усреднения baseline (>> collapse-window) |
| `cameraBaselineSkipSeconds` | 2.0 | отброс cold-start ramp |
| `criticalNotificationDedupeSeconds` | 10.0 | окно дедупа live-уведомлений |

## Affected modules

| Файл | Тип | Суть |
|---|---|---|
| `Onset/Configuration/RecordingConfiguration.swift` | modify | +9 констант |
| `Onset/Recording/Pipeline/PipelineTypes.swift` | modify | enum `CriticalIncident` + `CriticalIncidentScope` + nonisolated `==`/`hash` |
| `Onset/Recording/Pipeline/FpsCollapseDetector.swift` | new | pure-детектор fps: baseline + freeze + drop/gap-подтверждение |
| `Onset/Recording/Pipeline/SustainedDropDetector.swift` | new | pure-детектор устойчивых дропов (из существующего snapshot) |
| `Onset/Recording/Pipeline/StageRateAggregator.swift` | modify | latest-snapshot камеры (struct) обновляется flush без reset окна |
| `Onset/Recording/Pipeline/RecordingSession.swift` | modify | `currentRates()` — pull camera fps/gap-снимка под существующим lock |
| `Onset/Encode/VideoEncoder.swift` | modify | call-site flush (контракт сигнатуры) |
| `Onset/Recording/Capture/CameraSource.swift` (+`CameraSourceShims.swift`) | modify | публикация latest-snapshot; call-site flush |
| `Onset/Recording/Capture/ScreenSource.swift` | modify | call-site flush |
| `Onset/Storage/FileWriter.swift` | modify | call-site flush |
| `Onset/UI/RecordingCoordinator.swift` | modify | `criticalLatch` (max-severity), детекторы в tick-loop на монотонном времени, пост-стоп ветка |
| `Onset/UI/MenuBar/MenuBarLabelMapper.swift` | modify | hard-вид + per-инцидент a11y, второй вход |
| `Onset/UI/MenuBar/MenuBarLabel.swift` | modify | глиф `exclamationmark.octagon.fill` (+ опц. пульсация — см. OQ) |
| `Onset/Permissions/RecordingStartNotifier.swift` | modify | протокол + методы по тиру (timeSensitive/active), actionable reveal |
| `Onset.entitlements` (+ `scripts/check-entitlements.sh`) | modify | Time Sensitive Notifications capability |
| `OnsetTests/*` | modify/new | L2 детекторов/латча/дедупа/маппера + Fake notifier |
| `docs/architecture.md`, `docs/quality/production-quality-bar.md` | modify | критерии и сигналы |

## Decisions Made

| Решение | Rationale |
|---|---|
| Единая severity-модель hard/soft | один тир определяет индикатор+уровень+латч+дедуп — убирает рассинхрон |
| fpsCollapse только камера | экран event-driven + CFR-холды → статика штатно даёт ~0 кадров (ложь) |
| baseline + freeze при кандидате + окно >> collapse-window | без freeze скользящее среднее само-маскирует медленный коллапс и неидемпотентно |
| коллапс = падение И drop/gap-подтверждение | отсекает легитимный low-light throttle |
| `criticalDropRatePerMin` + floor длительности | абсолют ложит на коротких/длинных; rate без floor ложит на 2-сек клипе |
| `cameraLost` soft/hard по scope | камера+экран = запись идёт (soft); камера-only = встала (hard) |
| дедуп = suppress + severity-override | не спамить в моменте, но hard всегда пробивает; полная картина в пост-стопе |
| пост-стоп латч = max-severity, 2 текста | soft-сессия не должна получать «серьёзные проблемы» |
| уровень уведомления по тиру | soft не должен пробивать Focus как hard |
| de-escalate windowed hard, латч только терминальный | прошедший drop-storm не должен пульсировать «пожаром» до stop |
| `timeSensitive`, не `critical`/`active` для hard | `active` глохнет в Focus; `critical` требует Apple-grant |
| отдельный латч, не case в `RecordingState` | degraded авто-восстанавливается, critical латчится — разные lifecycle |
| детекторы — pure-типы, время аргументом, 1 Hz pull | L2-тестируемость + readout вне per-frame пути (stability #1) |
| `currentRates()` отдельным pull, только camera-снимок | `currentDrops()` = DropMonitor; fps живёт за др. lock; encoder/writer не нужны |
| глиф-октагон, различитель = внутр.глиф+цвет | контур октагона ≈ круг на 16px |

## Acceptance criteria

Каждый AC помечен уровнем пирамиды.

- AC-1 [L5]: камера+экран, камера отвал → ≤2 c `active`-уведомление; **октагона нет**;
  экран продолжает писаться; оба файла валидны; a11y-label обновлён.
- AC-2 [L5]: камера-only, камера отвал → ≤2 c `timeSensitive`-уведомление «запись
  остановлена»; октагон-латч до stop; файл валиден до обрыва.
- AC-3 [L2]: `SustainedDropDetector` — degraded ≥ `criticalSustainSeconds` → hard;
  < порога → нет; live-уведомление однократно; после восстановления вид
  де-эскалирует, session-латч для пост-стопа сохраняется.
- AC-4 [L2]: drop-rate ≥ `criticalDropRatePerMin` И длительность ≥
  `criticalDropRateMinSessionSeconds` → пост-стоп hard; короче floor → disk-only.
- AC-5 [L2]: `FpsCollapseDetector` — инжектированный ряд (delivered < ratio×baseline
  устойчиво ≥ window + drop/gap) → коллапс; тот же спад БЕЗ drop/gap (low-light) →
  НЕ коллапс; baseline заморожен при активном кандидате (детерминированный вердикт).
- AC-6 [L2]: устойчивый коллапс ≥ 2×`fpsCollapseWindowSeconds` → вердикт НЕ
  самовосстанавливается (freeze работает); медленный bleed с дропами → срабатывает.
- AC-7 [L5]: реальная Brio — затемнение сцены (плавный спад fps без дропов) НЕ
  срабатывает; искусственный stall (спад + дропы/gap) срабатывает.
- AC-8 [L2]: минорные дропы → ни октагона, ни уведомлений; только disk (поведение #246).
- AC-9 [L2]: дедуп — два hard в окне `criticalNotificationDedupeSeconds` → одно
  уведомление (suppress); soft показан, затем hard в окне → hard всё равно
  доставлен (severity-override); пост-стоп несёт все инциденты.
- AC-10 [L2]: уведомления denied → октагон всё равно отражает hard-критику
  (запасной канал); запись не ломается. (Среда теста — инъекция denied-состояния.)
- AC-11 [L1/grayscale]: hard-глиф отличим от degraded и normal по внутреннему
  глифу+цвету в grayscale в реальном размере status-item; a11y-label критики
  отличается от degraded.
- AC-12 [L5]: пост-стоп уведомление actionable — клик открывает отчёт в Finder.
- AC-13 [L5]: сессия только с `cameraAndScreen` (без hard) → пост-стоп **мягкая
  нота**, не «серьёзные проблемы».

Латентность: ≤2 c — для `cameraLost` (мгновенное событие). `sustainedDrops`/
`fpsCollapse` оконные — латентность = размер окна + 1 tick, это ожидаемо.

## Открытые вопросы

- [non-blocking] Финальные тексты уведомлений и a11y-labels — бриф для
  дизайн-сервиса (UI агентами не делается).
- [blocking AC-7] Эмпирическая устойчивость baseline+freeze+drop/gap-подтверждения
  против всей легитимной вариативности камеры (cold-start ramp + low-light throttle).
  Решается L5-калибровкой на Brio; пороги — гипотезы до подтверждения.
- [blocking technical-spike] Рендерится ли непрерывная пульсация (`symbolEffect`)
  в label MenuBarExtra status-item — известное ограничение. Если нет — статичная
  форма+цвет должны быть достаточным различителем сами по себе (пульсация — бонус,
  не несущая).
