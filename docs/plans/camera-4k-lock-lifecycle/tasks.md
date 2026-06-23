# Tasks: camera-4k-lock-lifecycle

Issue #265. Порядок T-1 → T-8. Все правки продукта — на feature-ветке. Дефолт: вариант (b) —
`activeFormat` + lock удержан до `stop()`, **только для `role == .record`** (preview не трогаем).

## T-1 — Поднять resolve+lock устройства в `buildAndStartSession`
Files: `Onset/Recording/Capture/CameraSource+SessionSetup.swift`
Dep: —
Вынести создание/валидацию `AVCaptureDevice` (`AVCaptureDevice(uniqueID:)` + guard `!isSuspended`) из
`addCameraInput` в `buildAndStartSession` (helper `resolveCameraDevice()`). `configureSession`/
`addCameraInput`/`makeCameraInput`/`activateFormat` принимают device параметром.
- **THE SYSTEM SHALL** резолвить/валидировать camera-device в scope `buildAndStartSession` до configure.
- Check: build (L0); grep — единственный `AVCaptureDevice(uniqueID:` для камеры в resolve-точке.

## T-2 — Убрать lock/unlock из `activateFormat`
Files: `Onset/Recording/Capture/CameraSource+SessionSetup.swift`
Dep: after T-1
`activateFormat` работает на УЖЕ залоченном устройстве: только `activeFormat` + `activeVideoMin/MaxFrameDuration`.
Удалить `lockForConfiguration()` (127) и `unlockForConfiguration()` (155).
- Check: build; grep — в `activateFormat` нет lock/unlock.

## T-3 — Удержать device-lock до `stop()` (только record); снять во всех teardown; preview — моментальный unlock
Files: `Onset/Recording/Capture/CameraSource+SessionSetup.swift`, `Onset/Recording/Capture/CameraSource.swift`, `Onset/Recording/Capture/CameraSourceHelpers.swift`
Dep: after T-2
В `buildAndStartSession`: `try device.lockForConfiguration()` ДО `configureSession`; `var locked = true`.
Для `role == .preview` — снять lock сразу после конфигурации И `locked = false` (текущее поведение).
Для `.record` — НЕ снимать: положить `device` в `CameraCaptureShims` полем `AVCaptureDevice?` (nil для
preview; НЕ 3-й associated value `.running` — `large_tuple`, `CameraSourceHelpers.swift:20-23`; обновить
doc-комментарий struct — device не delegate-shim). При переходе в `.running` — `locked = false` (ownership
к teardown). Снятие — единый `releaseRunning()` (`device?.unlockForConfiguration()` + `session.stopRunning()`)
в `stop()`, `handleCameraDisconnect()`, `handleCameraSessionFault()`. Обновить все 4 матча `.running`
(`CameraSource.swift` stop:206 / disconnect:222 / fault:243 / sessionHandle:260) + конструктор
`CameraCaptureShims(...)` в `CameraSourceLogicTests:353`. Error-старт: `defer { if locked { device.unlockForConfiguration() } }`
(единый флаг → нет двойного unlock на preview-throw). Комментарий-инвариант: «между lock и `.running` нет `await`».
ВНИМАНИЕ: build НЕ ловит пропущенный teardown (device в struct, не associated value) — корректность через
`releaseRunning()` + ревью-чеклист + L2.
- **Given** record в 4K, **When** сессия работает, **Then** lock удержан от setActiveFormat через всю
  record-сессию, снят строго в teardown; preview-роль lock не удерживает.
- **THE SYSTEM SHALL** не оставлять устройство залоченным ни на одном пути (error-старт preview И record,
  3 teardown), без двойного unlock (единый флаг `locked`).
- Check: review-чеклист «releaseRunning() во всех 3 teardown + locked=false на preview-unlock и hand-off»;
  L2 (через seam) — preview-error-путь, record-error-путь и каждый teardown НЕ оставляют lock и НЕ двойной unlock; build.

## T-4 — Cap-lift через параметр `allowAboveFullHD` (opt-in только record)
Files: `Onset/Recording/Capture/CameraFormatSelector.swift`, `Onset/UI/Main/MainViewModel+Record.swift`, `OnsetTests/CameraFormatSelectorTests.swift`
Dep: after T-3
Добавить `allowAboveFullHD: Bool = false` в `pickBestFormat`/`bestSixteenByNineFormat`. При true — снять
cap `fullHDMaxHeight` (стр.41,94-102), выбрать макс 16:9 (4K). Default false СОХРАНЯЕТ ≤1080p. record-вызов
(`+Record.swift:91`) передаёт true. Обновить KDoc #145 AC-5 (стр.13-23). Подтвердить: 4K Brio анонсится
`maxFrameRate>=minCameraFps` (спайк: 420v@30 проходит); если <30/29.97 — понизить порог/NTSC-tolerance.
Существующие тесты (`fourKLosesToFullHD`, `realisticMixPicksFullHD`, `allSixteenByNineAboveFullHDPicksSmallest`,
`allAboveFullHDSameResolutionPicksHigherFps`) тестируют default → остаются валидны; ДОБАВИТЬ кейсы true→4K.
- **Given** камера с 3840×2160@30, **When** `pickBestFormat(allowAboveFullHD: true)`, **Then** выбран 4K;
  **When** default (false), **Then** ≤1080p (как раньше).
- Check: L2 — новые true-кейсы зелёные, старые default-кейсы НЕ менялись и зелёные; build+lint.

## T-5 — Подтвердить preview и device-availability не уходят в 4K
Files: `Onset/UI/Main/MainViewModel+Preview.swift`, `Onset/UI/Main/MainViewModel+Devices.swift`
Dep: after T-4
preview (`:86`) и devices (`:259`) зовут `pickBestFormat` без параметра → default false → ≤1080p. Подтвердить,
что изменений не требуют и поведение прежнее (для device-availability ≤1080p достаточно).
- **Given** cap-lift opt-in только record, **When** preview/devices-путь, **Then** формат ≤1080p (прежнее).
- Check: review/grep — `+Preview:86` и `+Devices:259` не передают `allowAboveFullHD: true`; build.

## T-6 — CapabilityResolver: budget cross-effect (4K-камера vs экран)
Files: `Onset/Recording/Pipeline/CapabilityResolver.swift`, `OnsetTests/` (resolver-тест)
Dep: after T-4
Зафиксировать поведение бюджета 995M px/s при 4K-камере (резолвер уже считает по advertised maxFps —
conservative). Не допустить НЕОЖИДАННОГО даунскейла экрана (или принять явно с комментарием).
- **Given** 4K-дисплей + 4K-камера, **When** резолв, **Then** экран не ужат молча (детерминировано, покрыто тестом).
- Check: L2 — resolver-кейс 4K+4K; build.

## T-7 — Encode: ПОДТВЕРДИТЬ bitrate под 4K (verify-only)
Files: `Onset/Configuration/RecordingConfiguration.swift` (bitrate-таблица)
Dep: after T-4
**Уже есть** (подтверждено red-team): `RecordingConfiguration:265-266` содержит 4K-ключи
(`3840×2160,60`=60 Mbps; `3840×2160,30`=36 Mbps), `averageBitrate(forWidth:height:fps:)` (:193-227) делает
exact-match + fps-scaling fallback → Brio 4K@~24-25fps резолвится в адекватный битрейт. T-7 — **verify-only,
НЕ добавлять дубликат**. Если при verify обнаружится gap (например 4K@25 промахивается мимо обоих ключей
без вменяемого fallback) — тогда дописать; иначе no-op.
- **Given** запись 4K@~25, **When** строится encoder-config, **Then** битрейт резолвится в 4K-значение (не ≤1080p).
- Check: подтвердить по коду наличие 4K-ключей + fallback; L2 на `averageBitrate` для (3840,2160,25) если тестируемо.

## T-8 — L5: создать тест доставки 4K + проверить на Brio (БЛОКЕР приёмки)
Files: `OnsetTests/CameraSource4KDeliveryL5Tests.swift` (**создать с нуля**)
Dep: after T-3, T-4, T-6, T-7
Создать L5-тест (env-gated `ONSET_RUN_L5_CAPTURE`): ассерт delivered = 3840×2160. Файл авто-компилируется
(OnsetTests — synchronized group, pbxproj править НЕ нужно). Прогон на Brio, ПРЯМОЙ USB3 (хаб режет до
1080p!), `-testPlan Onset-L5`. Перед: `pgrep -la Onset`→`pkill -9 Onset`; Logi Options+/RightSight не держит
камеру. Подтвердить, что доставляемый pixel format = `420v` (videoSettings уже запрашивает его, :204-205;
при nil AVF отдал бы 2vuy — для HEVC нужен 420v). Замерить: разрешение, реальный fps (`verify-cfr.sh`, ожидаемо ~24-25 — ОК),
**счётчик `captureDrop` за прогон** (порог приемлемости) и **вменяемость битрейта/размера 4K-файла**.
Проверить комбинированный screen+camera (экран не деградировал неожиданно).
- **Given** Brio на прямом USB3, **When** запись 4K, **Then** файл 3840×2160, дропы в пределах порога,
  битрейт вменяем; **And** screen+camera — экран не ужат неожиданно.
- **Контракт «4K реально доставлено» закрывается ТОЛЬКО этим L5 на целевом Mac** — ни L2, ни CI его не
  закрывают; PR не мержится и #265 не в Done до сессии на железе с Brio.
- Check: `CameraSource4KDeliveryL5Tests` зелёный (3840×2160); `verify-cfr.sh` подтверждает. Ревёрт повторился →
  fallback preset-путь (a), Decision 1.
