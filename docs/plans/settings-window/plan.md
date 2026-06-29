---
type: plan
slug: settings-window
date: 2026-06-28
status: approved
spec: none
risk_areas: [perf-critical]
review_verdict: pass
review_blockers: []
---

# Plan: окно «Настройки» (⌘,) — v1

## Context & Decision

Onset нужно окно настроек, чтобы общеприложенческие и записывающие defaults можно было
настраивать и **сохранять между запусками** — сегодня это compile-time константы. Изменение
решено и согласовано с владельцем по scope (дизайн-заметки: `swarm-report/settings-window-design.md`).
Макет Claude Design (`screens-prefs.jsx`) — **только визуальный референс**, не 1:1 спецификация:
реальные разделы выводятся из возможностей приложения. Этот план — про КАК: нативная
SwiftUI-сцена `Settings`, persisted-хранилище настроек, **два реальных контрола (тоггл таймера
в menu bar, зеркалирование камеры)**, перспективные read-only строки-отображения для
пока-фиксированных параметров и модель apply-policy для настроек.

> **Scope note:** селектор профиля качества рассматривался и **выкинут из v1** владельцем после
> ревью — он конфликтогенный (множитель битрейта складывается в пик ×2.8, нужна аппаратная
> калибровка, нестандартный выбор enum→значение). Отложен в следующую задачу, когда калибровка
> войдёт в scope. Вкладка Видео в v1 — read-only-заглушки. Это полностью убирает perf-critical
> риск битрейта; единственная оставшаяся забота по capture-pipeline — zero-copy путь
> зеркалирования камеры (ниже).

## Technical Approach

**Сцена и обнаружимость.** Добавить SwiftUI-сцену `Settings { … }` (бесплатный ⌘,) в `body`
`Onset/OnsetApp.swift`, аддитивно к двум сценам `Window` + `MenuBarExtra`. Поскольку Onset —
приложение, центрированное на menu bar, ⌘, срабатывает только при сфокусированном окне — поэтому
меню `MenuBarExtra` (`MenuBarMenu`) **обязано** получить пункт `SettingsLink { Text("Настройки…") }`,
чтобы окно было достижимо, когда никакое другое окно не открыто. Вкладки-toolbar (Apple HIG через
`TabView` + `.tabItem` с SF Symbol на каждую вкладку). Окно открывается на содержательной вкладке
(**Индикация**) и запоминает последнюю выбранную вкладку. UI строится **только из стандартных
компонентов SwiftUI/AppKit** (`Settings`, `Form`, `Toggle`, `LabeledContent`, `TabView`) — без
кастомных контролов в погоне за пиксель-в-пиксель макетом.

**Персистентность (first-class).** Следовать существующему паттерну хранилища: persisting-протокол
+ реализация на `UserDefaults` + double `InMemory` — для двух `Bool` использовать прямой
`set(_:forKey:)`/`object(forKey:)` (presence-check, чтобы отличить unset → default; прецедент
`OutputFolderStore` хранит значения напрямую, не JSON), guard на `.standard` под тестом —
прецедент `Onset/Storage/OutputFolderStore.swift`, `DeviceSelectionStore.swift`,
`BackendSelectionStore.swift`. Константы ключей в `Onset/Configuration/` (прецедент
`OutputFolderKeys.swift`). Хранить две настройки **по-ключно** (`showMenuBarTimer: Bool`,
`cameraMirror: Bool`), чтобы повреждение одного ключа само-восстанавливалось к собственному
default без сброса другого.

**Общая observable-модель (единственный неочевидный риск).** Наблюдение SwiftUI распространяется
через общую `@Observable`-ссылку, а не через записи в `UserDefaults`. Обе настройки потребляются
**живыми** поверхностями (таймер → `MenuBarLabel`; зеркало → живое превью камеры), поэтому нужна
одна `@Observable`-модель настроек, владеемая в корне композиции (`@State` в `OnsetApp`, рядом с
`coordinator` в `OnsetApp.swift:49/57`), инъектируемая в сцену Settings, `MenuBarLabel` и
поверхность превью. Она загружается из хранилища на старте и **пишет насквозь синхронно через
`didSet`** на каждом stored-свойстве (работает под `@Observable`; мутация и персистит в
`SettingsStore`, и триггерит наблюдение). **Единый источник чтения:** потребители читают значение
из `AppSettings`, не из хранилища напрямую — `AppSettings` — это in-memory источник истины
(исключает два пути чтения для `cameraMirror`). **Инъекция (явная, не `@Environment`):**
`MainViewModel` получает `let appSettings: AppSettings` в своём `init` (обновлены все места
создания VM — см. `MainViewModel.swift`); `MenuBarLabel` и `SettingsView` получают её как параметр
`init` из `OnsetApp`, где владеется единственный экземпляр. Сцена `Settings` конструирует
`SettingsView(appSettings:coordinator:)` — `coordinator` нужен для гейтинга по `isRecordingActive`.

**Модель apply-policy.** Чистая таксономия `SettingApplyPolicy` в `Onset/Configuration/`:
`.immediate` (применяется сразу, редактируема во время записи — таймер), `.nextRecordingStart`
(редактируема, на записанный выход влияет только со следующей сессии; **заблокирована во время
записи** — зеркало), `.requiresRelaunch` (сохраняется, нужен рестарт; **не используется в v1**,
определена для forward-compat). Чистый классификатор `(policy, isRecordingActive) ->
ControlAvailability` живёт в `UI/Settings/`, зеркаля `MenuBarLabelMapper`; view рендерит
`.disabled(…)` **и** поясняющую подпись («Недоступно во время записи») + `accessibilityHint` из
его результата — серый контрол всегда сообщает, почему.

**`isRecordingActive` обязан быть observable.** `isStarting`/`isStopping` — `@ObservationIgnored`,
а `phase` становится `.recording` только в конце `start()` (`RecordingCoordinator.swift:289-296,552`).
*Вычисляемый* `isRecordingActive` поверх этих флагов НЕ триггерил бы инвалидацию SwiftUI в течение
(возможно, секундных) окон старта/остановки. Экспонировать `isRecordingActive` как **observable
stored-свойство** ровно с двумя точками записи: **установить `true` на входе `start()` (~:445)** —
покрывая всё окно запуска — и **установить `false` по завершении `stop()`** (после установки
терминальной фазы). `defer` для `isStarting` на :449 сбрасывает `isStarting` — *другую*
переменную — и **не должен** трогать `isRecordingActive`. Этот двухточечный протокол (не «одно
место») держит гейт в true на протяжении секундного окна старта и всей записи, false — только
после полной остановки; подаётся в классификатор, чтобы контролы серели во время переходов.

**Зеркалирование камеры.** Добавить `cameraMirror: Bool` в `RecordingConfiguration` (capture-side
настройка, согласованно с `minCameraFps`), с **default `= false`** на stored-поле и параметре
`makeMVPDefault`, чтобы `static let mvpDefault` (:244) и остальные вызыватели (`CameraFormatSelector`,
`RecordingCoordinator.stop`) компилировались без изменений. И превью-`CameraSource`
(`MainViewModel.swift:593`), и `CameraSource` пути записи (`RecordingComponentFactories.swift:284-288`)
строятся из `config`.
- **Путь записи:** установить `AVCaptureConnection.isVideoMirrored` на VDO-connection в
  `CameraSource+SessionSetup.swift` после `session.addOutput(videoOutput)` (~L300) — guard
  `isVideoMirroringSupported`, установить `automaticallyAdjustsVideoMirroring = false`, затем
  `isVideoMirrored`, внутри `begin/commitConfiguration`. T1-проверено (заголовок macOS SDK 26.5):
  не deprecated, физически переворачивает VDO-буферы → влияет на запись. **Инвариант (regression
  guard):** устанавливать **только при setup сессии до первого кадра**, никогда на работающей
  сессии (one-shot lifecycle; зеркало читается заново при старте записи). **Открытый риск:**
  физический переворот буфера на горячем пути камеры может сломать IOSurface zero-copy путь в
  `VTCompressionSession` (spec «Zero-copy путь»). Поломка НЕ обязательно роняет кадры (per-frame
  memcpy ~0.1–0.5 мс укладывается в бюджет 33 мс) — она проявляется как регрессия
  CPU/энергии/температуры, топ-приоритет для длинных сессий. Поэтому L5 проверяет zero-copy
  **напрямую** (CVPixelBuffer остаётся IOSurface-backed и/или дельта CPU/энергии на кадр-энкод
  через `powermetrics`/Instruments), с «нет новых дропов» как вторичным сигналом — не
  доказательством.
- **Путь живого превью:** превью — это *отдельная* `AVCaptureSession`, рендеримая через
  `AVCaptureVideoPreviewLayer` (`CameraPreviewView.swift`); её `connection.isVideoMirrored` — это
  дешёвый **трансформ слоя**, не переворот буфера. Управлять им **реактивно из наблюдения
  `AppSettings.cameraMirror`**: `CameraPreviewRepresentable` (в `MainView.swift`, строки 334–348)
  принимает `cameraMirror` и применяет его в своём сейчас-no-op `updateNSView` —
  `nsView.previewLayer?.connection?.isVideoMirrored = cameraMirror` (с
  `automaticallyAdjustsVideoMirroring = false`, выставляемым один раз при подключении preview-слоя
  в `CameraPreviewView`). БЕЗ `begin/commitConfiguration` сессии, без пересборки `CameraSource`,
  поэтому тоггл даёт живой WYSIWYG без мерцания/залипания. `CameraPreviewRepresentable.updateNSView`
  — **единственный писатель** mirror-состояния preview-connection. Поскольку превью отражает
  изменение мгновенно, а *запись* учитывает его со следующего старта, подпись контрола зеркала
  гласит «Превью обновляется сразу, в запись — со следующего старта» (а не общее «применится к
  следующей записи»).

**Контролы-отображения/заглушки.** Пока-фиксированные параметры рендерятся как **read-only строки
`LabeledContent`** (лейбл + статичное значение, без шеврона, неинтерактивные) — НЕ одно-опционные
`Picker` (которые читаются как сломанные), без «скоро». Пункты: кодек HEVC, контейнер MP4,
разрешение «Исходное», частота кадров «авто/исходный» (НЕ фиксированное число — камера отдаёт
переменный/меньший fps; одно число подразумевало бы ложную гарантию); разрешение камеры 1080p;
шумоподавление аудио выкл, системное аудио выкл; язык «Русский». Интерактивные контролы появятся
позже, только когда существует реальный выбор.

**Категории (от владельца):** Общие (read-only строка языка; опционально версия/About) · Индикация
(тоггл таймера, read-only заглушка иконки Dock) · Видео (read-only строки формата —
codec/container/resolution/fps) · Камера (реальное зеркало + read-only строка разрешения) · Аудио
(read-only строки). Только Индикация и Камера несут реальные контролы в v1; остальные — честные
read-only-дома для будущих настроек. Вкладка по умолчанию — Индикация; L3-проход подтверждает, что
вкладки-только-заглушки читаются как «информационные», не «сломанные».

## Affected Modules & Files

| Path | Change | Note |
|---|---|---|
| `Onset/Configuration/SettingsKeys.swift` | New | константы UserDefaults по-ключно (прецедент `OutputFolderKeys`). |
| `Onset/Configuration/SettingApplyPolicy.swift` | New | таксономия apply-policy; чистая. |
| `Onset/Configuration/RecordingConfiguration.swift` | Modified | добавить поле `cameraMirror`; расширить `makeMVPDefault(baseDirectory:cameraMirror:)`; **обновить рукописный `==` (:308-341)**. |
| `Onset/Storage/SettingsStore.swift` | New | persisting-протокол по-ключно + реализация на `UserDefaults` + `InMemory`. |
| `Onset/UI/AppSettings.swift` | New | общая `@Observable`-модель настроек (in-memory источник истины). |
| `Onset/OnsetApp.swift` | Modified | добавить сцену `Settings`; владеть + инъектировать `AppSettings`. |
| `Onset/UI/MenuBar/MenuBarMenu.swift` | Modified | добавить пункт `SettingsLink` («Настройки…»). |
| `Onset/UI/Settings/*` | New | `SettingsView` + панели вкладок (нативные компоненты); чистый классификатор `ControlAvailability`. |
| `Onset/UI/MenuBar/MenuBarLabelMapper.swift` | Modified | добавить параметр `showTimer:` → опускать elapsed при false. |
| `Onset/UI/MenuBar/MenuBarLabel*.swift` | Modified | читать общий `AppSettings.showMenuBarTimer`. |
| `Onset/UI/RecordingCoordinator.swift` | Modified | экспонировать **observable stored** `isRecordingActive`, единый путь обновления. |
| `Onset/UI/Main/MainViewModel.swift` | Modified | добавить `let appSettings: AppSettings` в `init` (+ обновить все места создания VM). |
| `Onset/UI/Main/MainViewModel+Record.swift` | Modified | читать `cameraMirror` из `self.appSettings`; пробросить в `makeMVPDefault` (:108). |
| `Onset/UI/Main/MainView.swift` | Modified | `CameraPreviewRepresentable` (строки 334–348): передать `appSettings.cameraMirror` и выставить его в `updateNSView` (сейчас no-op) на `nsView.previewLayer?.connection?.isVideoMirrored`. |
| `Onset/Recording/Capture/CameraSource+SessionSetup.swift` | Modified | установить `isVideoMirrored` на VDO-connection при setup; `attachOutputs` НЕ внутри существующего `begin/commitConfiguration` (тот оборачивает `setInputAndFormat` :164/169) — обернуть установку зеркала в СОБСТВЕННЫЙ `session.beginConfiguration()/commitConfiguration()` после `addOutput` (:300). |
| `Onset/UI/Main/CameraPreviewView.swift` | Modified | тот `NSView`, что экспонирует `previewLayer`; `automaticallyAdjustsVideoMirroring = false` на preview-connection, чтобы реактивная установка вступала в силу. |
| `OnsetTests/*` | New | L2-тесты: store по-ключно, mapper, классификатор, равенство config. |
| `docs/architecture.md` | Modified | сцена Settings + новые типы. |
| `CLAUDE.md` | Modified | (a) правило «UI из стандартных компонентов SwiftUI/AppKit»; (b) переформулировать «sole @Observable owner» → «sole session-lifecycle owner» (через revise-claude-md; ≤200 строк). |

## Decisions Made

| Decision | Rationale | Alternatives rejected |
|---|---|---|
| Выкинуть профиль качества из v1 | Конфликтогенный (компаундинг пика ×2.8, нужна аппаратная калибровка, нестандартный выбор enum); убирает perf-critical риск | Выпустить сейчас (ревью вскрыло critical + несколько major) |
| Одна общая `@Observable` `AppSettings`; потребители читают из неё (не из хранилища) | Инвалидации SwiftUI нужна общая ссылка; единый in-memory источник исключает два пути чтения | Приватное хранилище на каждую VM (не распространится); чтение хранилища на seam записи + AppSettings в превью (два источника) |
| `cameraMirror` `.nextRecordingStart`; превью живое, запись — со следующего старта | One-shot pipeline не может переконфигурироваться по ходу записи; превью — дешёвый трансформ слоя | Зеркалить работающую сессию записи (переворот посреди файла) |
| `isRecordingActive` = observable **stored**, единый путь обновления | Флаги `@ObservationIgnored` не инвалидируют; дублирование по 6 местам рискует дрейфом | Computed getter поверх `@ObservationIgnored`; рукописно в 6 местах |
| Заглушки = read-only `LabeledContent`, не одно-опционный `Picker` | Picker с одной опцией читается как сломанный контрол (HIG) | Отключённый picker / бейдж «скоро» |
| `CameraPreviewView` — единственный писатель зеркала превью; auto-adjust выключен на обоих connection | Избегает двойного применения/гонки; некоторые камеры авто-зеркалят превью по умолчанию | Запись зеркала и из +Preview, и из CameraPreviewView |
| `SettingsLink` в `MenuBarExtra` | ⌘, работает только при сфокусированном окне; menu-bar-приложению нужен явный пункт | Полагаться только на ⌘, (недостижимо без окна) |
| `SettingApplyPolicy`/`SettingsKeys` в `Configuration/` | Сохраняет направление зависимостей внутрь | Размещение в `UI/` инвертирует зависимости |
| Настройки никогда не текут через/в `RecordingCoordinator` | Координатор — единственный владелец **session-lifecycle**; настройки — односторонние чтения на seam'ах | Координатор владеет настройками |

## Risks & Mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| Физический переворот `isVideoMirrored` может сломать IOSurface zero-copy → регрессия CPU/энергии/температуры (не дропы) | major | L5 проверяет zero-copy **напрямую** (IOSurface-backed / дельта CPU-энергии на кадр), зеркало-ON vs OFF на default; дропы вторичны (T-7/T-10) |
| Рукописный `RecordingConfiguration ==` (:308-341) молча опускает `cameraMirror` → сломанное обнаружение изменений | major | T-4 обновляет `==` в той же правке; L2-тест ассертит неравенство для нового поля |
| `.immediate` таймер / зеркало живого превью не перерисовываются (неправильная модель наблюдения) | major | Общая `@Observable` `AppSettings` в корне композиции; зеркало превью привязано к наблюдению, единственный писатель (T-3/T-5/T-7) |
| `isRecordingActive` не реактивен в окнах старта/остановки | major | Observable **stored**-свойство, единый путь обновления (T-8) |
| Заглушки/вкладки-только-заглушки читаются как сломанные/недоделанные | major | Read-only строки `LabeledContent`; по умолчанию открыта Индикация; L3 подтверждает «информационность» (T-9) |
| L5 для зеркала камеры требует signed-build + MX Brio, на **тихой** машине | major | Entitlements камеры/превью провижинятся под Personal Team (память: camera L5 выполним); зеркало/энергия меряются без параллельной UI/screenshot-нагрузки (правило проекта perf-verify-quiet-machine) |
| Пробел доступности на нестандартных состояниях (заблокированные/read-only строки) | major | `accessibilityHint` на заблокированных контролах; read-only строки озвучиваются как **статичный текст** (не кнопка), корректный порядок фокуса (T-9) |

## Verification & Sources

Как верифицируется готовое изменение (контракт `/acceptance`):

| Source of truth | Type | Status | Sufficient for verification? |
|---|---|---|---|
| `swarm-report/settings-window-design.md` | требования / дизайн | есть | да — определяет контролы v1 (таймер, зеркало), категории, apply-policy, принцип read-only-заглушек |
| `docs/specs/2026-06-02-onset-recording-mvp.md` (AC-4 codec/container) | spec | есть | да — ограничивает заглушки (HEVC/MP4 фиксированы) |
| Поведенческий baseline: текущая запись, зеркало-OFF | before-state baseline | захватить до импла (L5: ffprobe + `verify-cfr` одной записи камеры на default, на тихой машине) | да — доказывает, что зеркало-ON отличается (перевёрнуто) без регрессии zero-copy/энергии, и существующее поведение записи не изменилось |

**Стратегия тестирования (уровни пирамиды):** L0 build всегда + L1 lint (warnings-as-errors,
SwiftFormat/SwiftLint) + L2 unit (`RecordingConfiguration ==` для `cameraMirror`; mapper `showTimer`;
store настроек по-ключно с `InMemory`; матрица классификатора `ControlAvailability`) + L5 вручную
на MX Brio (signed-build, **тихая машина**): (a) зеркало переворачивает `camera.mp4` и живое
превью; изолированное зеркало-ON vs OFF на default показывает сохранённый zero-copy (IOSurface-backed
/ нет регрессии CPU-энергии на кадр), дропы вторичны; (b) таймер в menu bar скрывается/показывается
вживую; (c) и ⌘,, и `SettingsLink` открывают окно; (d) влияющий на запись контрол (зеркало) сереет
с пояснением во время активной записи. L5 **обязателен** — изменение трогает capture pipeline
(infra-слой) и записанный выход; build+unit сами по себе его не закрывают. L3 UI (прохождение
Settings, вкладки-только-заглушки, заблокированные состояния) через manual-tester.

## Out of Scope

- **Профиль качества / выбор битрейта** — выкинут из v1 (см. Scope note); будущая задача с аппаратной калибровкой.
- Запуск при логине (autostart), проверка обновлений, выбор языка — будущее; дом = категория «Общие».
- Устройства по умолчанию внутри Settings — остаются в главном окне для v1.
- Расхождения макета и реальности — НЕ реализованы, задокументированы: контейнер MOV (code/spec = MP4, AC-4),
  60 fps (камера отдаёт меньше; заглушка fps показана как «авто/исходный»).
- Выбор формата (codec/container/fps как реальные селекторы), поведение иконки Dock во время записи,
  шумоподавление, системное аудио — в v1 только read-only строки.
- Редизайн главного pre-record окна (сворачиваемые источники, `screens-settings.jsx`).

## Open Questions

- [non-blocking] Показывать ли в «Общие» также версию приложения/About в v1 (сделало бы вкладку нетривиальной).
- [non-blocking] Этот PR трогает `CLAUDE.md` (+ это UI-изменение, требующее L5): по политике
  meta-merge проекта он **не авто-мержабелен** — нужно ревью владельца. Опционально вынести
  переформулировку CLAUDE.md в отдельный meta-PR, чтобы этот мержился по собственным gate'ам.
