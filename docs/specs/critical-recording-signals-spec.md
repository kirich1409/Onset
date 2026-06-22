# Спецификация: активный сигнал о критических проблемах записи

Статус: черновик v2 (после multi-expert review: business-analyst + architecture-expert + ux-expert + performance-expert)
Связано: #246 (UI-показ дропов → disk-отчёт), #242 (menu-bar-first запись), AC-12 (graceful camera revocation)

## Контекст

После #246 на каждую завершённую сессию пишется технический отчёт на диске
(`Onset … — Техническая информация.txt`). Из UI убраны: живой счётчик-пилюля
дропов и UI-показ пост-стоп предупреждения о деградации. При этом константа
`postStopDropWarningThreshold` (=5) и путь `degradedWarning` в коде **остались**
живыми (`RecordingCoordinator.swift:172,694`, `RecordingSession.swift:869`) —
#246 убрал именно UI-поверхность, не всю логику. Реализующий агент обязан
проверить текущее фактическое поведение этого пути перед переиспользованием.

Активного сигнала о **серьёзных** проблемах сейчас нет:

- Индикатор деградации menu bar (жёлтая точка + треугольник) завязан только на
  `encoderBackpressureDrops` через скользящее окно и **авто-восстанавливается** —
  транзиентная просадка, не «пожар».
- Потеря камеры обрабатывается (AC-12: `sourceRevocationStream` → координатор →
  `sourceLiveness.camera=false`, чек-лист в окне красным), но в menu-bar-first
  режиме окна нет → пользователь ничего не видит; menu bar потерю не отражает.
- Коллапс fps не детектируется: `StageRateAggregator` считает delivered fps
  (`fresh=`) раз в секунду, но только пишет строку в лог — числового readout нет.

Итог: при реальной аварии пользователь узнаёт о ней, только если сам откроет
файл-отчёт.

## Цель

Явные, фальсифицируемые критерии «критической» проблемы записи + активный
сигнал пользователю (индикатор menu bar + системное уведомление + пост-стоп
уведомление), при сохранении disk-only поведения для минорных дропов.

## Не-цели

- Экран настроек порогов (пороги — фикс-константы в конфиг-слое, выносимы позже).
- Восстановление потерянного контента.
- Изменение формата/содержимого дискового отчёта (#246).
- **fpsCollapse на экране** — невозможен корректно: SCK-источник event-driven,
  `CFRNormalizer` штатно заполняет слоты синтетическими холдами на статичной
  картинке (`docs/architecture/drop-accounting.md` §2), поэтому «низкий delivered
  fps экрана» = норма (пользователь читает документ), а не авария. Детектим
  коллапс fps только для камеры (непрерывный источник).
- `UNNotificationInterruptionLevel.critical` (bypass mute switch) — требует
  Apple-grant critical-alerts entitlement; вне скоупа.

## Prerequisites

| # | Предпосылка | Статус | Owner | Exit-criterion |
|---|---|---|---|---|
| P1 | Числовой fps-readout из `StageRateAggregator` | не существует | Agent | координатор читает delivered fps per-lane числом, без сброса окна и без второго захвата `rateLock` (см. «Архитектура») |
| P2 | Монотонный источник времени для новых окон | частично (есть host-clock в DropMonitor/ScreenSource) | Agent | окна `criticalSustainSeconds`/`fpsCollapseWindowSeconds`/baseline считаются на host-clock, НЕ на `Date()` |
| P3 | Capability «Time Sensitive Notifications» | не подключён | Agent | entitlement `com.apple.developer.usernotifications.time-sensitive` добавлен; `scripts/check-entitlements.sh` обновлён и зелёный (стандартный entitlement, Apple-grant не нужен) |
| P4 | Проверка живого пути `degradedWarning`/`postStopDropWarningThreshold` | не сделана | Agent | задокументировано фактическое текущее поведение пост-стоп пути после #246 |

## Критерии «пожара»

Три независимых критических инцидента, тип несёт enum `CriticalIncident`
(`cameraLost(scope)`, `sustainedDrops`, `cameraFpsCollapse`).

### 1. Потеря камеры во время записи (`cameraLost`)

Детект уже есть (AC-12): координатор получает `.sourceRevoked(.camera)` и
`.allVideoSourcesLost`. **Два подслучая с разной severity** (по проверенному
поведению кода):

- `cameraLost(scope: .cameraAndScreen)` — камера+экран: камера-файл финализируется
  корректно (кадры до обрыва на месте), **экран продолжает писаться штатно**,
  сессия `.completed`. Основной контент не теряется → **мягкий сигнал**:
  однократное информирующее уведомление + временный (не латч до stop) индикатор;
  пост-стоп нота, но не «пожар».
- `cameraLost(scope: .cameraOnly)` — только камера: `.allVideoSourcesLost` →
  сессия останавливается, `.completed(.cameraOnly)`, файл валиден до обрыва.
  Запись встала → **полный критический сигнал** (латч до stop + уведомление +
  пост-стоп).

### 2. Устойчивая деградация / чрезмерные дропы (`sustainedDrops`)

Эскалация существующего `degraded` (не новый счётчик):

- **Live критический:** состояние `degraded` держится непрерывно ≥
  `criticalSustainSeconds`. Транзиент (< порога) остаётся жёлтым/disk-only.
- **Пост-стоп критический:** **нормированная** интенсивность дропов за сессию
  ≥ `criticalDropRatePerMin` (drops/min), НЕ абсолютный session-total — 300
  дропов за 30-секундный клип это авария, а за 2 часа норма. Порог заметно выше
  существующего `postStopDropWarningThreshold` (=5), который остаётся нижней
  границей disk-only отчёта.

### 3. Коллапс частоты кадров камеры (`cameraFpsCollapse`, «резкая скорость»)

Камера — непрерывный источник, её delivered fps не зависит от движения в кадре
(в отличие от экрана). Критерий — **резкое падение относительно собственного
адаптивного baseline, подтверждённое сигналом проблемы в пайплайне**:

- baseline = скользящее среднее delivered fps (адаптивный, не зафиксированный за
  N секунд — иначе ловит cold-start ramp и не адаптируется к легитимному
  изменению), с отбросом первых `cameraBaselineSkipSeconds` (ramp на старте).
- срабатывание: delivered_fps < `fpsCollapseRatio` × baseline, устойчиво ≥
  `fpsCollapseWindowSeconds`, **И** одновременно присутствует подтверждающий
  сигнал проблемы — ненулевой drop/overflow rate ИЛИ `gap_ms_max` выше
  `fpsCollapseGapMsThreshold`. Подтверждение отсекает **легитимный low-light
  throttle авто-экспозиции** (Brio в темноте честно падает с 30 до ~15fps без
  дропов и без gap-всплесков — это НЕ авария).
- база — измеренный baseline, НЕ `ResolvedCameraPlan.fps` (= `CameraFormat.maxFps`,
  завышен: Brio план 60, реально ~20 устойчиво).

Источник delivered fps / drop / gap: числовой снимок `StageRateAggregator` (P1).

## Механизм сигнала

Каналы дополняют друг друга (fallback, не дублирование): в menu-bar-first режиме
окна нет → уведомление основной канал; индикатор menu bar — вторичный И запасной,
когда уведомления запрещены или подавлены Focus.

### Индикатор menu bar
Критическое состояние **категориально отличимым глифом**, не перекраской
degraded-треугольника: degraded = жёлтый `circle.fill` + `exclamationmark.triangle.fill`;
critical = `exclamationmark.octagon.fill` (форма-октагон, различается без цвета).
Distinguishability проверяется в grayscale (дальтонизм, ~8% мужчин; элемент menu
bar крошечный). Для critical из-за пассивности канала — лёгкая пульсация.

A11y-label критики — отдельный, явно сигнализирующий аварию, per-инцидент
(не наследует degraded «запись деградирована»):
- `cameraOnly`: «Onset, критическая ошибка: камера отключена, запись остановлена»
- `cameraAndScreen`: «Onset, камера отключена, запись экрана продолжается, <time>»
- `sustainedDrops`/`fpsCollapse`: «Onset, критические потери кадров, <time>»

Lifecycle индикатора: `cameraOnly`/`sustainedDrops`/`fpsCollapse` — латч до stop
(не «мигать аварией»); `cameraAndScreen` — временный (запись продолжается штатно).

### Системное уведомление (live)
Переиспользовать инфраструктуру `RecordingStartNotifier` — **расширив протокол**
`RecordingStartNotifying` новым методом (отдельный identifier/контент; обновить
`FakeRecordingStartNotifier`). Уровень критических — `timeSensitive` (пробивает
Focus — доминирующий сценарий записи: презентации/демо/фокус-сессии). Постить:
- при `cameraLost` (live);
- при наступлении устойчивого критического (`sustainedDrops`/`fpsCollapse`),
  однократно на сессию.
Дедупликация одновременных инцидентов: первое критическое уведомление за сессию
подавляет последующие критические в окне `criticalNotificationDedupeSeconds`
(камера часто отваливается → всплеск дропов; не два баннера в стрессовый момент).

### Пост-стоп уведомление
На stop, если сессия видела хоть один критический инцидент — уведомление
«Запись сохранена, но были серьёзные проблемы. Подробности — в технической
информации рядом с записью.» **Actionable**: клик → reveal отчёта в Finder
(macOS-конвенция; средний путь между тишиной и принудительным открытием окна —
поведение #246 «не форсировать окно» сохранено). Минорные дропы — пост-стоп
тишина (disk-only).

## Архитектура

- **Детекторы — чистые nonisolated типы** (паттерн `CFRNormalizer`/`CapabilityResolver`):
  `FpsCollapseDetector` (вход: delivered fps + drop/gap rate + baseline-состояние
  + пороги → вердикт + обновлённый baseline) и `SustainedDropDetector` (вход:
  degraded-длительность/drop-rate + пороги → вердикт). Вся ветвящаяся логика и
  латч тестируются на L2 без железа.
- **Латч на координаторе**: `criticalIncident: CriticalIncident?` (+ session-латч
  «видела критику» для пост-стопа). `MenuBarLabelMapper` принимает его вторым
  входом. **НЕ** расширять `RecordingState` новым case — обоснование: degraded
  авто-восстанавливается (sliding window), critical латчится до stop; это разные
  жизненные циклы, держать их в одном enum семантически неверно. (Прежнее
  обоснование «off-actor DropMonitor требует nonisolated ==» снято как неточное —
  `DropMonitor` это actor; manual witnesses у enum'ов проекта рутинны.)
- **P1 live-seam без per-frame стоимости**: расширить существующий 1 Hz `flush`
  каждого источника так, чтобы в рамках **того же** `rateLock.withLock` он отдавал
  числовой снимок (struct с fresh/drop/gap rate) рядом со строкой — нулевая
  дополнительная per-frame работа и contention. Снимок доставляется на координатор
  через существующий pull-паттерн `currentDrops()` (tick-loop, 1 Hz,
  `RecordingCoordinator:629`) — **без нового AsyncStream**, сохраняя инвариант
  единственного подписчика. Отдельный read-путь к аккумулятору запрещён (stability #1).
- **P2 часы**: все окна — host-clock.

## Конфигурация

Константы в `RecordingConfiguration` (рядом с `degradedBackpressureThreshold`,
`postStopDropWarningThreshold`), с комментарием
`// calibrate post-MVP via L5 (MX Brio); future: expose in Settings`.
Стартовые значения — гипотезы для L5-калибровки, не истина:

| Константа | Дефолт | Смысл |
|---|---|---|
| `criticalSustainSeconds` | 10.0 | непроходящая деградация → live критика |
| `criticalDropRatePerMin` | 600 | нормированная интенсивность дропов → пост-стоп критика |
| `fpsCollapseRatio` | 0.5 | доля от baseline, ниже которой — коллапс |
| `fpsCollapseWindowSeconds` | 5.0 | устойчивость коллапса |
| `fpsCollapseGapMsThreshold` | 250 | gap_ms_max, подтверждающий проблему |
| `cameraBaselineSkipSeconds` | 2.0 | отброс cold-start ramp перед baseline |
| `criticalNotificationDedupeSeconds` | 10.0 | дедуп одновременных критических уведомлений |

## Affected modules

| Файл | Тип | Суть |
|---|---|---|
| `Onset/Configuration/RecordingConfiguration.swift` | modify | +7 констант |
| `Onset/Recording/Pipeline/PipelineTypes.swift` | modify | enum `CriticalIncident` + nonisolated witnesses |
| `Onset/Recording/Pipeline/FpsCollapseDetector.swift` | new | pure-детектор fps + baseline |
| `Onset/Recording/Pipeline/SustainedDropDetector.swift` | new | pure-детектор устойчивых дропов |
| `Onset/Recording/Pipeline/StageRateAggregator.swift` | modify | числовой снимок (struct) из flush в том же lock |
| `Onset/Recording/Pipeline/RecordingSession.swift` | modify | проброс fps/drop/gap снимка в snapshot/readout |
| `Onset/Encode/VideoEncoder.swift` | modify | call-site flush (контракт) |
| `Onset/Recording/Capture/CameraSource.swift` | modify | call-site flush |
| `Onset/Recording/Capture/ScreenSource.swift` | modify | call-site flush |
| `Onset/Storage/FileWriter.swift` | modify | call-site flush |
| `Onset/UI/RecordingCoordinator.swift` | modify | латч `criticalIncident`, детекторы в tick-loop, пост-стоп ветка |
| `Onset/UI/MenuBar/MenuBarLabelMapper.swift` | modify | критический вид + a11y, второй вход |
| `Onset/UI/MenuBar/MenuBarLabel.swift` | modify | глиф `exclamationmark.octagon.fill` + пульсация |
| `Onset/Permissions/RecordingStartNotifier.swift` | modify | протокол + critical/post-stop методы, timeSensitive, actionable |
| `Onset.entitlements` (+ `scripts/check-entitlements.sh`) | modify | Time Sensitive Notifications capability |
| `OnsetTests/*` | modify/new | L2 детекторов/латча/маппера + Fake notifier |
| `docs/architecture.md`, `docs/quality/production-quality-bar.md` | modify | описать критерии и сигналы |

## Decisions Made

| Решение | Rationale |
|---|---|
| fpsCollapse только для камеры, не для экрана | экран event-driven + CFR-холды → статика штатно даёт ~0 реальных кадров (ложная тревога) |
| Камерный коллапс = падение от baseline **И** drop/gap-подтверждение | отсекает легитимный low-light throttle (падение fps без дропов = норма) |
| Адаптивный (скользящий) baseline, не фикс за 3с | фикс ловит cold-start ramp и не адаптируется к легитимной вариативности |
| `criticalDropRatePerMin` вместо абсолютного session-total | абсолют ложно срабатывает на коротких и пропускает на длинных |
| `cameraLost` разнесён по severity (scope) | камера+экран = запись продолжается (не пожар); камера-only = запись встала |
| `timeSensitive`, не `critical` и не `active` | `active` глохнет в Focus (доминирующий сценарий); `critical` требует Apple-grant |
| Отдельный латч, не case в `RecordingState` | degraded авто-восстанавливается, critical латчится — разные lifecycle |
| Детекторы — pure-типы, питаются 1 Hz pull-снимком | L2-тестируемость + readout вне per-frame пути (stability #1) |
| Глиф-октагон, не перекраска треугольника | различимость для дальтоников в крошечном menu bar |

## Acceptance criteria

Каждый AC помечен уровнем пирамиды.

- AC-1 [L5]: камера+экран, камера отвал → ≤2 c информирующее уведомление; индикатор
  временный (не латч); экран продолжает писаться; оба файла валидны.
- AC-2 [L5]: камера-only, камера отвал → ≤2 c критическое уведомление «запись
  остановлена»; индикатор-латч до stop; файл валиден до обрыва.
- AC-3 [L2]: при degraded непрерывно ≥ `criticalSustainSeconds` (инжектированные
  события) детектор даёт критический вердикт; при < порога — нет; live-уведомление
  однократно (латч).
- AC-4 [L2]: нормированная drop-rate ≥ `criticalDropRatePerMin` → пост-стоп
  критический вердикт; ниже — нет (disk-only).
- AC-5 [L2]: `FpsCollapseDetector` на инжектированном ряду (delivered < ratio×baseline
  устойчиво ≥ window + ненулевой drop/gap) → коллапс; тот же ряд без drop/gap
  (плавный спад, low-light) → НЕ коллапс.
- AC-6 [L5]: реальная камера Brio: затемнение сцены (плавный спад fps без дропов)
  НЕ срабатывает; искусственный stall/перегрузка (спад + дропы/gap) срабатывает.
- AC-7 [L2]: минорные дропы → ни критики-индикатора, ни уведомлений; только
  disk-отчёт (поведение #246).
- AC-8 [L5]: уведомления denied → индикатор menu bar всё равно отражает критику
  (запасной канал); запись не ломается.
- AC-9 [L2]: один инцидент → одно уведомление; одновременные инциденты в окне
  `criticalNotificationDedupeSeconds` → одно агрегированное уведомление.
- AC-10 [L1/grayscale]: critical-глиф визуально отличим от degraded и normal в
  grayscale; a11y-label критики отличается от degraded-label.
- AC-11 [L5]: пост-стоп уведомление actionable — клик открывает отчёт в Finder.

Латентность: ≤2 c только для `cameraLost` (срочно — мгновенное событие).
`sustainedDrops`/`fpsCollapse` оконные по природе (`criticalSustainSeconds` /
`fpsCollapseWindowSeconds` + 1 Hz tick) — их латентность = размер окна, это
ожидаемо и не требует отдельного bound.

## Открытые вопросы

- [non-blocking] Финальные тексты уведомлений и a11y-labels — после согласования
  (UI агентами не делается → бриф для дизайн-сервиса).
- [blocking AC-6] Эмпирическая устойчивость адаптивного baseline + drop/gap-
  подтверждения против ВСЕЙ легитимной вариативности камеры (cold-start ramp +
  low-light throttle). Решается L5-калибровкой на Brio; до подтверждения пороги
  `fpsCollapseRatio`/`fpsCollapseGapMsThreshold` — гипотезы.
- [non-blocking] Нужна ли пульсация critical-глифа или достаточно статичной формы —
  на UX-бриф.
