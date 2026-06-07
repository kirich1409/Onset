---
type: test-plan
slug: onset-recording-mvp
platform: [desktop]
---

# Test Plan: Onset — Recording MVP

| | |
|---|---|
| Feature | Recording MVP Core: dual-file HEVC capture (screen + camera), CFR, NLE alignment, drop monitoring |
| Spec | `docs/specs/2026-06-02-onset-recording-mvp.md` (AC-1…AC-12; AC-2 и AC-11 — amended) |
| Design | `docs/design-ref/main/`, `docs/design-ref/recording/`, `docs/design-ref/menu-bar-recording/` |
| Platform | macOS 26.x, Apple Silicon (M3 Max dev machine) |
| Preconditions (L5) | Onset.app подписан; разрешения Screen/Camera/Microphone выданы (если не указано иное); `~/Movies/Onset/` создаётся автоматически |

## Findings

- **AC-2 amended** — «Записать» активна при ≥1 видеоисточнике (экран обязателен; камера опциональна). Два под-кейса микрофона: (а) микрофон доступен, но не выбран в пикере → кнопка `disabled` + подсказка «Выберите аудио-вход»; (б) микрофон недоступен (нет устройства / нет разрешения) → кнопка активна + индикатор «без звука».
- **AC-11 amended** — Экран ОБЯЗАТЕЛЕН в MVP; нет разрешения → старт блокируется. Нет камеры → пишется только файл экрана. Нет микрофона → файлы без audio-дорожки.
- **HW-энкодер обязателен** (AC-6) — software-fallback запрещён молча; на Apple Silicon (M3 Max) HW HEVC всегда доступен.
- **Degraded-порог и окно** не фиксированы в плане — TС ссылаются на `RecordingConfiguration` (символически), чтобы работать с любым будущим значением.
- **NLE-синхронизация** (AC-7) верифицируется двумя методами: автоматическим прокси через `ffprobe` (доступен на dev-машине) и опциональным ручным NLE-импортом (DaVinci Resolve / FCPX — не установлены, поэтому operator-optional).
- **`kill -9` TС** используют PID процесса Onset (`pgrep Onset`), не UI-quit.
- **L1/L2 — уже покрыто** существующими тестами `OnsetTests/`; план указывает конкретные файлы. L5 — ручные/hardware-сценарии, выносятся в acceptance #42.

## Risk Areas

- **Синхронизация таймлайнов** (AC-7, highest) — общая эпоха `T0`, per-sample `CMClock.convertTime`, mic fan-out; ошибка здесь = дрейф в NLE.
- **Crash-recovery** (AC-10) — `movieFragmentInterval` должен быть выставлен до старта; иначе файл невалиден после `kill -9`.
- **HW-энкодер** (AC-6) — `RequireHardwareAcceleratedVideoEncoder=true`; silent SW-fallback = незаметный брак.
- **Graceful права в рантайме** (AC-12) — отзыв разрешения во время записи не должен роняет второй поток.
- **CFR-нормализация** (AC-5) — джиттер UVC-камеры → hold/drop без дрейфа против экрана; VFR = битый NLE-импорт.
- **Backpressure-счётчики** (AC-8) — смешение CFR-дропов и backpressure даёт ложный Degraded или, наоборот, скрывает реальный.
- **PII** — имена устройств и пути файлов не должны попадать в логи.

---

## Test Cases

### Phase 1 — Pure logic (L1/L2, без устройства)

> Все L2-тесты уже реализованы в `OnsetTests/`. Ниже — трассировка к AC и ссылки на существующие файлы.

#### REC-TC-01 — RecordingConfiguration: дефолтный профиль MVP
| | |
|---|---|
| Priority | P1 |
| Type | unit |
| AC ref | AC-4, AC-5 |
| Preconditions | — |
| Steps | Создать `RecordingConfiguration.mvpDefault`; проверить все поля |
| Expected Result | codec=HEVC, container=.mp4, sampleEntry=hvc1, profileLevel=MainAutoLevel, colorPrimaries=Rec709, bitDepth=8, maxScreenFps=60, minCameraFps=30, pixelFormat=420v, allowFrameReordering=false, movieFragmentInterval=4s, outputDir=…/Movies/Onset |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §AC-4/AC-5; `RecordingConfigurationTests.swift` (mvpDefault_* тесты) |

#### REC-TC-02 — CapabilityProbe: HW HEVC обязателен, SW-fallback запрещён
| | |
|---|---|
| Priority | P0 |
| Type | unit |
| AC ref | AC-6 |
| Preconditions | Seam: `VTCreateCompressionSession` с `RequireHardwareAcceleratedVideoEncoder` |
| Steps | (а) Симулировать успешный VT-создание + `UsingHardwareAcceleratedVideoEncoder=true` → ожидать `.ok`; (б) `Using==false` → `.noHardwareEncoder`; (в) VT-создание бросает ошибку → `.noHardwareEncoder`. Проверить, что SW-ветки отсутствуют в коде |
| Expected Result | Только два исхода: `.ok` или `.noHardwareEncoder`; нет пути к кодированию без HW |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §AC-6; `CapabilityProbeTests.swift` |

#### REC-TC-03 — CapabilityProbe: budget cap / downscale 5K → 4K
| | |
|---|---|
| Priority | P1 |
| Type | unit |
| AC ref | AC-5 |
| Preconditions | — |
| Steps | Σ(w·h·fps) для 5K60 + камера > бюджет движка (995M px/s из `RecordingConfiguration`); запросить стартовый профиль |
| Expected Result | Разрешение экрана downscale до ≤4K60; fps сохранён (downscale-first); результат: `EngineBudgetCap.fits` == true после cap |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §AC-5 (pre-flight budget); `CapabilityProbeTests.swift` (5K→4K cap, over-budget→downscale@60) |

#### REC-TC-04 — CFRNormalizer: snap к сетке, hold и drop
| | |
|---|---|
| Priority | P1 |
| Type | unit |
| AC ref | AC-5, AC-8 |
| Preconditions | — |
| Steps | (а) Кадр точно на слоте сетки → `.encode`; (б) Пропущен слот → `.hold` (повтор последнего буфера); (в) Два кадра в один слот → `.drop` с инкрементом `cfrNormalizationDrops`; (г) Verify `cfrNormalizationDrops++` не инкрементирует `encoderBackpressureDrops` |
| Expected Result | Каждый из трёх исходов корректен; счётчики раздельны |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §CFR; `CFRNormalizerTests.swift` |

#### REC-TC-05 — VideoEncoder: HEVC-свойства применяются, backpressure изолирован
| | |
|---|---|
| Priority | P1 |
| Type | unit |
| AC ref | AC-4, AC-6, AC-8 |
| Preconditions | Mock VTCompressionSession |
| Steps | (а) `configure` → RealTime/AllowFrameReordering/ProfileLevel-Main/AverageBitRate/MaxKeyFrameIntervalDuration установлены; (б) `DataRateLimits` → fallback на AverageBitRate при `kVTPropertyNotSupportedErr`; (в) backpressure: `isReadyForMoreMediaData==false` → drop + `DropEvent` (backpressure counter++, cfr counter==0) |
| Expected Result | Все HEVC-свойства применены; graceful DataRateLimits; счётчик backpressure изолирован |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §Кодирование; `VideoEncoderTests.swift` |

#### REC-TC-06 — FileWriter: movieFragmentInterval и audio-input
| | |
|---|---|
| Priority | P1 |
| Type | unit |
| AC ref | AC-4, AC-10 |
| Preconditions | Temp-директория |
| Steps | (а) `movieFragmentInterval_setBeforeStart` — проверить, что interval выставлен ДО первого вызова `startSession`; (б) `audioInput_hasAACSettings` — проверить наличие audio-input при `includeAudio=true`; (в) `videoInput_nilOutputSettings` — nil (passthrough) для HEVC |
| Expected Result | movieFragmentInterval выставлен (≤5s по умолчанию из `RecordingConfiguration`); audio-input создан; video-passthrough |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §Запись в файл, §AC-10; `FileWriterTests.swift` |

#### REC-TC-07 — DropMonitor: Degraded по backpressure, не по CFR/capture
| | |
|---|---|
| Priority | P0 |
| Type | unit |
| AC ref | AC-8 |
| Preconditions | — |
| Steps | (а) backpressure-дропы ≤ пороговому значению из конфигурации в окне T → `.normal`; (б) превышение порога → `.degraded`; (в) CFR-нормализационные дропы в том же количестве → `.normal` (не триггерит Degraded); (г) после истечения окна T → возврат к `.normal` |
| Expected Result | Degraded триггерится только `encoderBackpressureDrops`; CFR-дропы и capture-дропы не влияют |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §Dropped frames / Degraded; `DropMonitorTests.swift` |

#### REC-TC-08 — DualFileOutputStage: mic fan-out и PTS-привязка
| | |
|---|---|
| Priority | P1 |
| Type | unit |
| AC ref | AC-7 |
| Preconditions | `FakeWriterFactory` |
| Steps | Подать один audio `CMSampleBuffer` в stage → проверить, что (а) оба writer'а (`screenWriter`, `cameraWriter`) получили ОДИНАКОВЫЙ буфер; (б) PTS приведён к host-time якорю T0; (в) видео-кадры ≥T0 принимаются; видео < T0 отбрасываются |
| Expected Result | Mic семплово идентичен в обоих файлах; pre-T0 кадры отброшены |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §Синхронизация (mic fan-out); `DualFileOutputStageTests.swift` (retiming_setsAbsoluteHostTimePTS) |

#### REC-TC-09 — RecordingSession: старт/стоп, параллельная финализация
| | |
|---|---|
| Priority | P1 |
| Type | unit |
| AC ref | AC-9, AC-11 |
| Preconditions | `FakeScreenSource`, `FakeCameraSource`, `FakeEncoder` |
| Steps | (а) `start` → оба encoder.startCalled; (б) `stop` → оба `markAsFinished` + `finishWriting` вызваны параллельно (`async let`); (в) падение финализации одного writer'а не прерывает второго |
| Expected Result | Параллельная финализация; каждый writer завершает независимо |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §Остановка и финализация; `RecordingSessionTests.swift` |

#### REC-TC-10 — RecordingSession: graceful по effectivePermissions (AC-11)
| | |
|---|---|
| Priority | P1 |
| Type | unit |
| AC ref | AC-11 |
| Preconditions | `FakeScreenSource`, `FakeCameraSource` |
| Steps | (а) экран granted, камера denied → стартует только screen-пайплайн; (б) экран granted, камера granted, микрофон denied → оба пайплайна стартуют, audio-input не создаётся; (в) экран denied → старт блокируется (throws / returns error) |
| Expected Result | Screen-only: один файл; no-mic: оба файла без audio-track; no-screen: старт не происходит |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §Graceful; `RecordingSessionTests.swift` |

#### REC-TC-11 — RecordingSession: отзыв одного источника не роняет второй (AC-12)
| | |
|---|---|
| Priority | P1 |
| Type | unit |
| AC ref | AC-12 |
| Preconditions | `FakeScreenSource`, `FakeCameraSource`, `FakeEncoder` |
| Steps | (а) Симулировать `sourceRevoked(.camera)` во время активной записи → camera-encoder получает `stop`, camera-файл финализируется (`finish` вызван); screen-encoder продолжает работу (не вызывает `stop`). (б) Проверить `shouldHandleDisconnect` — camera-disconnect с неверным uniqueID (другого устройства) не останавливает camera-pipeline |
| Expected Result | Только затронутый пайплайн останавливается и финализируется; второй продолжает; нет краша |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §AC-12, §Graceful; `RecordingSessionTests.swift`; `CameraSourceLogicTests.swift` (`shouldHandleDisconnect`) |

#### REC-TC-12 — MainViewModel: кнопка «Записать» — состояния AC-2 [unit]
| | |
|---|---|
| Priority | P1 |
| Type | unit |
| AC ref | AC-2 |
| Preconditions | `FakePermissionsService`, `FakeRecordingControlling` |
| Steps | (а) Экран granted, дисплей выбран, микрофон не выбран (но доступен) → `record_micUnselected_errorSet`; (б) Экран denied → `record_screenDenied_returnsEarly`; (в) Экран granted, микрофон недоступен (нет устройства) → `record_validState_startCalledOnce`; (г) Re-entrancy: два вызова `record()` подряд → только один start |
| Expected Result | (а) старт не произошёл, установлена ошибка; (б) ранний выход; (в) запись стартовала (без аудио); (г) ровно один старт |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §AC-2; `MainViewModelRecordTests.swift` |

#### REC-TC-13 — RecordingCoordinator: стоп по hotkey и финализация результата
| | |
|---|---|
| Priority | P1 |
| Type | unit |
| AC ref | AC-9 |
| Preconditions | `FakeRecordingControlling` |
| Steps | (а) Инициировать стоп через coordinator → `stopCalled==true`; (б) result содержит пути обоих файлов; (в) при backpressure-дропах в result присутствует предупреждение |
| Expected Result | Финализация завершается с результатом; предупреждение о дропах присутствует при ненулевом backpressure-счётчике |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §AC-9; `RecordingCoordinatorTests.swift` |

---

### Phase 2 — Live app (L5, running Onset.app на macOS 26.x, M3 Max)

> L5-тесты требуют подписанного build'а и физической машины. Являются обязательными для acceptance #42.

#### REC-TC-14 — Главный экран: селекторы и превью (AC-1)
| | |
|---|---|
| Priority | P1 |
| Type | ui-scenario |
| AC ref | AC-1 |
| Preconditions | Все разрешения выданы; подключена внешняя камера (или встроенная); ≥2 дисплея (чтобы проверить пикер) |
| Steps | 1. Запустить Onset.app → главный экран. 2. Убедиться: секция ЭКРАН — пикер дисплея активен (≥2 дисплея), дополнительные режимы (Область/Окно) ОТСУТСТВУЮТ; секция КАМЕРА — пикер устройства активен, live-превью отображается; секция МИКРОФОН — пикер устройства активен. 3. Убедиться: кнопка «Записать» активна; секции «Вывод», уровень-meter, настройки кодека ОТСУТСТВУЮТ на экране. 4. Единственный дисплей → пикер скрыт/задизейблен, дисплей выбран по умолчанию |
| Expected Result | Ровно 3 секции (ЭКРАН / КАМЕРА / МИКРОФОН), live-превью работает, кнопка «Записать» активна. Макет: `docs/design-ref/main/` |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §AC-1 |

#### REC-TC-15 — Кнопка «Записать»: микрофон не выбран vs недоступен (AC-2)
| | |
|---|---|
| Priority | P1 |
| Type | ui-scenario |
| AC ref | AC-2 |
| Preconditions | Экран granted, камера опциональна |
| Steps | **Кейс А (микрофон доступен, но не выбран):** 1. Сбросить пикер микрофона в «Не выбрано». 2. Проверить: кнопка «Записать» `disabled`; подсказка «Выберите аудио-вход, чтобы начать запись» видна. **Кейс Б (микрофон недоступен):** 1. Отозвать разрешение микрофона в System Settings → Privacy → Microphone. 2. Вернуться в Onset. 3. Проверить: кнопка «Записать» активна; индикатор «без звука» виден. |
| Expected Result | А: кнопка disabled + подсказка; Б: кнопка активна + «без звука» |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §AC-2 (amended) |

#### REC-TC-16 — Старт записи: окно и menu bar (AC-3)
| | |
|---|---|
| Priority | P1 |
| Type | ui-scenario |
| AC ref | AC-3 |
| Preconditions | Все разрешения выданы; дисплей и камера выбраны |
| Steps | 1. Нажать «Записать». 2. Главное окно скрывается. 3. Открывается окно записи: статус «● ИДЁТ ЗАПИСЬ», таймер тикает, чек-лист источников (Screen / Camera / Microphone), кнопка «Остановить» активна. 4. Menu bar: ● + таймер |
| Expected Result | Окно записи открыто, таймер работает, menu bar в режиме Recording. Макет: `docs/design-ref/recording/`, `docs/design-ref/menu-bar-recording/` |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §AC-3 |

#### REC-TC-17 — Два файла: кодек, контейнер, CFR (AC-4)
| | |
|---|---|
| Priority | P1 |
| Type | e2e |
| AC ref | AC-4 |
| Preconditions | Все разрешения; запись ≥10s |
| Steps | 1. Запустить запись, подождать 10s, остановить. 2. `ffprobe -v quiet -print_format json -show_streams ~/Movies/Onset/<session>-Screen.mp4` → проверить: codec_name=hevc, codec_tag_string=hvc1, r_frame_rate соответствует CFR. 3. То же для `Camera.mp4`. 4. Убедиться, что оба файла в `~/Movies/Onset/` с единым timestamp в имени. |
| Expected Result | Оба файла: HEVC/hvc1, CFR, наличие audio-stream; единый timestamp в именах |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §AC-4 |

#### REC-TC-18 — Pre-flight HW-энкодер: нет SW-fallback (AC-6)
| | |
|---|---|
| Priority | P0 |
| Type | ui-scenario |
| AC ref | AC-6 |
| Preconditions | M3 Max (HW HEVC присутствует) |
| Steps | 1. Запустить запись. 2. Console.app (subsystem `dev.androidbroadcast.Onset`): убедиться, что логируется «HW HEVC OK» / аналог и НЕТ записей «software encoder». 3. (Негативный путь — unit-покрыт TC-02; L5 на машине без HW недостижим, gap задокументирован) |
| Expected Result | Console не содержит признаков SW-кодирования; запись стартует без ошибки |
| Platform | Apple Silicon (M3 Max), macOS 26.x |
| Source | Spec §AC-6; epic3-capability-probe-acceptance.md (live-probe PASS) |

#### REC-TC-19 — NLE-alignment: T0-якорь + семплово-идентичный звук (AC-7) [P0]
| | |
|---|---|
| Priority | P0 |
| Type | e2e |
| AC ref | AC-7 |
| Preconditions | `ffprobe` доступен; запись ≥30s с микрофоном |
| Steps | 1. Записать ≥30s (экран + камера + микрофон). 2. `ffprobe -select_streams v:0 -show_entries packet=pts_time -of csv Screen.mp4 \| head -1` и аналогично Camera.mp4 → first video PTS. 3. `ffprobe -select_streams a:0 -show_entries packet=pts_time -of csv Screen.mp4 \| head -1` → first audio PTS. 4. Вычислить: (a) first audio PTS Screen ≈ first audio PTS Camera (семплово-идентичный mic fan-out); (b) abs(first_video_PTS_Screen - first_video_PTS_Camera) ≤ 1/maxFps секунд (≤1 кадр на макс. fps). **Автоматический прокси (используется в L5-acceptance #42):** проверка (a) и (b) через ffprobe-скрипт подтверждает одну host-time T0 эпоху и mic fan-out. **Operator-optional (NLE-ручной путь):** импортировать оба файла в DaVinci Resolve / Final Cut Pro X → авто-синхронизация по audio waveform → измерить визуальный дрейф ≤1 кадр на макс. fps. (DaVinci/FCPX не установлены на dev-машине — этот шаг является опциональным; ffprobe-прокси является достаточным для приёмочной проверки.) |
| Expected Result | (a) Audio PTS обоих файлов отличаются ≤1 аудио-семпл; (b) Video PTS отличаются ≤1/maxFps секунд; NLE-авто-sync работает по waveform |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §AC-7 |

#### REC-TC-20 — Dropped frames: раздельные счётчики и Degraded UI (AC-8)
| | |
|---|---|
| Priority | P0 |
| Type | ui-scenario |
| AC ref | AC-8 |
| Preconditions | Запись активна; значения порога и окна из `RecordingConfiguration` |
| Steps | 1. Запустить запись. 2. Наблюдать dropped-frames счётчик в окне записи (начальное: 0). 3. Имитировать backpressure-дроп (искусственно перегрузить pipeline) до превышения порога `RecordingConfiguration.degradedThreshold` в окне `RecordingConfiguration.degradedWindowSeconds`. 4. Проверить: UI переходит в Degraded (🟡⚠ + таймер в menu bar); окно записи показывает предупреждение. 5. Дождаться истечения окна без новых дропов → UI возвращается к нормальному. 6. Убедиться: CFR-нормализационные дропы и camera-capture-дропы НЕ триггерят Degraded (unit-верификация в TC-07). |
| Expected Result | Degraded активируется/деактивируется по backpressure-счётчику; счётчик в UI отображает раздельные категории |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §AC-8; `DropMonitorTests.swift` |

#### REC-TC-21 — Три пути остановки: кнопка, hotkey, menu bar (AC-9)
| | |
|---|---|
| Priority | P1 |
| Type | ui-scenario |
| AC ref | AC-9 |
| Preconditions | Активная запись |
| Steps | **Путь А:** кнопка «Остановить» в окне записи → окно закрывается, Finder reveal обоих файлов. **Путь Б:** ⌘⌥⌃R (global hotkey) во время записи → та же финализация. **Путь В:** menu bar → «Остановить» → та же финализация. **Путь Г:** красная кнопка title bar окна записи → тот же эффект (=«Остановить», не новый поток). 4. После каждого пути: оба файла открываются в QuickTime, проигрываются без артефактов. |
| Expected Result | Все 4 точки остановки финализируют оба файла; Finder reveal; menu bar возвращается в Idle |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §AC-9 |

#### REC-TC-22 — Crash recovery: `kill -9` → оба файла валидны (AC-10) [P0]
| | |
|---|---|
| Priority | P0 |
| Type | e2e |
| AC ref | AC-10 |
| Preconditions | `movieFragmentInterval` задан (проверено TC-06); запись ≥20s активна |
| Steps | 1. Запустить запись, подождать ≥20s. 2. `kill -9 $(pgrep Onset)` — аварийное завершение. 3. Проверить `~/Movies/Onset/`: оба файла присутствуют (`Screen.mp4` и `Camera.mp4`). 4. `ffprobe -v error Screen.mp4` → нет ошибок контейнера; файл открывается и проигрывается. То же для `Camera.mp4`. 5. Измерить потерянный хвост: `ffprobe -v quiet -show_entries format=duration Screen.mp4` → duration ≥ (20s - movieFragmentInterval) |
| Expected Result | Оба файла валидны и проигрываемы; потеря хвоста ≤ одного `movieFragmentInterval`-окна |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §AC-10 |

#### REC-TC-23 — Graceful: нет камеры → только файл экрана (AC-11) [P3-edge]
| | |
|---|---|
| Priority | P3 |
| Type | ui-scenario |
| AC ref | AC-11 |
| Preconditions | Screen granted; Camera denied или устройство отсутствует |
| Steps | 1. Запустить Onset.app — камера недоступна. 2. Убедиться: кнопка «Записать» активна (экран есть). 3. Начать запись, остановить через 10s. 4. Проверить `~/Movies/Onset/`: присутствует ТОЛЬКО `Screen.mp4`; `Camera.mp4` отсутствует (или не создан). |
| Expected Result | Один файл экрана; приложение не крашится; старт не заблокирован |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §AC-11 (amended) |

#### REC-TC-24 — Graceful: нет микрофона → запись без audio-дорожки (AC-11) [P3-edge]
| | |
|---|---|
| Priority | P3 |
| Type | ui-scenario |
| AC ref | AC-2, AC-11 |
| Preconditions | Screen + Camera granted; Microphone denied или устройство отсутствует |
| Steps | 1. Индикатор «без звука» виден на главном экране. 2. Нажать «Записать» (кнопка активна). 3. Записать 10s, остановить. 4. `ffprobe -show_streams Screen.mp4` → нет audio stream; `ffprobe -show_streams Camera.mp4` → нет audio stream |
| Expected Result | Оба файла созданы, видео-дорожки присутствуют, audio-дорожки отсутствуют; нет крашей |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §AC-11 (amended) |

#### REC-TC-25 — Graceful: нет разрешения экрана → старт заблокирован (AC-11) [P0]
| | |
|---|---|
| Priority | P0 |
| Type | ui-scenario |
| AC ref | AC-11 |
| Preconditions | Screen permission NOT granted; Camera может быть granted |
| Steps | 1. `tccutil reset ScreenCapture dev.androidbroadcast.Onset` 2. Запустить Onset.app → главный экран. 3. Убедиться: секция ЭКРАН задизейблена + «Доступ к экрану не выдан» + ссылка в онбординг. 4. Кнопка «Записать» недоступна. |
| Expected Result | Запись не стартует; пользователь видит объяснение и путь к онбордингу |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §AC-11 (amended); `docs/design-ref/main/` |

#### REC-TC-26 — Permission revoke mid-recording: затронутый поток финализируется, второй продолжает (AC-12)
| | |
|---|---|
| Priority | P0 |
| Type | ui-scenario |
| AC ref | AC-12 |
| Preconditions | Экран + Камера + Микрофон granted; активная запись ≥15s |
| Steps | 1. Начать запись (оба потока: экран + камера, звук). 2. В System Settings → Privacy → Camera → отозвать разрешение Onset. 3. Вернуться в Onset немедленно. 4. Наблюдать: камера-поток останавливается, `Camera.mp4` финализируется (проверить ffprobe). 5. Экран-поток ПРОДОЛЖАЕТ запись ещё ≥10s. 6. Остановить штатно. 7. Проверить оба файла через ffprobe: оба валидны. |
| Expected Result | Camera.mp4 валиден и проигрываем (финализирован с `movieFragmentInterval`); Screen.mp4 продолжил и завершён нормально; нет краша |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §AC-12 |

#### REC-TC-27 — Hotkey ⌘⌥⌃R: старт и стоп (AC-9)
| | |
|---|---|
| Priority | P2 |
| Type | ui-scenario |
| AC ref | AC-9 |
| Preconditions | Onset на главном экране, источники валидны |
| Steps | 1. Нажать ⌘⌥⌃R на главном экране → запись стартует. 2. Нажать ⌘⌥⌃R снова → запись останавливается, файлы финализируются. |
| Expected Result | Hotkey работает как кнопка «Записать»/«Остановить»; файлы валидны |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §AC-9, §Prerequisites |

#### REC-TC-28 — Menu bar: Idle / Recording / Degraded состояния (AC-3, AC-8)
| | |
|---|---|
| Priority | P2 |
| Type | ui-scenario |
| AC ref | AC-3, AC-8 |
| Preconditions | Onset запущен |
| Steps | 1. До записи: menu bar Idle (○); клик → меню «Открыть Onset» / «Начать запись» / «Выход». 2. Во время записи: ● + таймер; клик → «Остановить» / «Открыть окно записи». 3. При Degraded: 🟡⚠ + таймер (текстовый лейбл, не только цвет). Макет: `docs/design-ref/menu-bar-recording/` |
| Expected Result | Все три состояния корректны; VoiceOver видит текст состояния |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §Окна и menu bar |

#### REC-TC-29 — Единственный дисплей: пикер скрыт (AC-1) [P3-edge]
| | |
|---|---|
| Priority | P3 |
| Type | ui-scenario |
| AC ref | AC-1 |
| Preconditions | Только один дисплей подключён |
| Steps | 1. Запустить Onset.app. 2. Проверить главный экран: пикер дисплея скрыт или задизейблен; дисплей выбран по умолчанию; запись доступна сразу. |
| Expected Result | Один дисплей — пикер не показывается; запись стартует без выбора дисплея |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §AC-1 |

#### REC-TC-30 — `kill -9` во время записи → оба файла остаются открытыми (не corrupted) [P3-edge]
| | |
|---|---|
| Priority | P3 |
| Type | e2e |
| AC ref | AC-10 |
| Preconditions | `movieFragmentInterval` выставлен; активная запись |
| Steps | 1. Начать запись, подождать ≥10s (≥2 movieFragmentInterval). 2. `kill -9 $(pgrep Onset)`. 3. `ffprobe -v error ~/Movies/Onset/<session>-Screen.mp4` → нет ошибок. 4. `ffprobe -v error ~/Movies/Onset/<session>-Camera.mp4` → нет ошибок. 5. Открыть оба файла в QuickTime — проигрываются без артефактов. |
| Expected Result | Оба файла open (не corrupted); доступны для монтажа без repair |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §AC-10 |

#### REC-TC-31 — Остановка с backpressure-предупреждением (AC-9)
| | |
|---|---|
| Priority | P2 |
| Type | ui-scenario |
| AC ref | AC-9 |
| Preconditions | Записи предшествовали существенные backpressure-дропы (TC-19) |
| Steps | 1. После записи с Degraded-эпизодом остановить штатно. 2. Наблюдать результат: Finder reveal + уведомление содержит предупреждение «запись завершена, пропущено N кадров — возможны рывки». |
| Expected Result | Предупреждение о дропах присутствует в результирующем уведомлении |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §AC-9 |

#### REC-TC-32 — `~/Movies/Onset/` создаётся при первом запуске записи
| | |
|---|---|
| Priority | P2 |
| Type | ui-scenario |
| AC ref | AC-4 |
| Preconditions | Удалить `~/Movies/Onset/` если существует |
| Steps | 1. Удалить директорию `rm -rf ~/Movies/Onset`. 2. Запустить Onset.app, нажать «Записать», записать 5s, остановить. 3. Проверить наличие `~/Movies/Onset/` и файлов в ней. |
| Expected Result | Директория создана; файлы присутствуют; нет ошибки об отсутствующей директории |
| Platform | Apple Silicon, macOS 26.x |
| Source | Spec §Prerequisites |

---

## Coverage Matrix

| AC | TCs | Кол-во TCs |
|---|---|---|
| AC-1 | REC-TC-14, REC-TC-29 | 2 |
| AC-2 | REC-TC-12, REC-TC-15 | 2 |
| AC-3 | REC-TC-16, REC-TC-28 | 2 |
| AC-4 | REC-TC-01, REC-TC-05, REC-TC-06, REC-TC-17, REC-TC-32 | 5 |
| AC-5 | REC-TC-01, REC-TC-03, REC-TC-04, REC-TC-17 | 4 |
| AC-6 | REC-TC-02, REC-TC-05, REC-TC-18 | 3 |
| AC-7 | REC-TC-08, REC-TC-19 | 2 |
| AC-8 | REC-TC-04, REC-TC-05, REC-TC-07, REC-TC-20, REC-TC-28 | 5 |
| AC-9 | REC-TC-09, REC-TC-13, REC-TC-21, REC-TC-27, REC-TC-31 | 5 |
| AC-10 | REC-TC-06, REC-TC-22, REC-TC-30 | 3 |
| AC-11 | REC-TC-10, REC-TC-23, REC-TC-24, REC-TC-25 | 4 |
| AC-12 | REC-TC-11, REC-TC-26 | 2 |

---

## Edge Cases & Negative Scenarios

- **Нет камеры → только Screen.mp4** (REC-TC-23) — файл Camera не создаётся; нет краша.
- **Нет микрофона → записи без audio-дорожки** (REC-TC-24) — оба файла валидны; индикатор «без звука» виден.
- **Единственный дисплей → пикер дисплея скрыт** (REC-TC-29).
- **`kill -9` во время записи → оба файла остаются открытыми (не corrupted)** (REC-TC-30) — movieFragmentInterval гарантирует recoverable частичную запись.
- **Revocation mid-recording** (REC-TC-26) — затронутый поток финализируется, второй продолжает.
- **Re-entrancy (двойной tap «Записать»)** — только один старт (unit: REC-TC-11 reentrancy guard).
- **Кадры с PTS < T0** — отбрасываются (unit: REC-TC-08); не попадают в файл.
- **`DataRateLimits` не поддерживается энкодером** — graceful fallback к AverageBitRate (unit: REC-TC-05).
- **5K/6K дисплей → downscale до ≤4K60** — pre-flight cap (unit: REC-TC-03); не рантайм-деградация.

---

## Automation / Уровни покрытия

| TC-ID | Уровень | Статус | Примечание |
|---|---|---|---|
| REC-TC-01 | L2 unit | ✅ реализован | `RecordingConfigurationTests.swift` |
| REC-TC-02 | L2 unit | ✅ реализован | `CapabilityProbeTests.swift` |
| REC-TC-03 | L2 unit | ✅ реализован | `CapabilityProbeTests.swift` |
| REC-TC-04 | L2 unit | ✅ реализован | `CFRNormalizerTests.swift` |
| REC-TC-05 | L2 unit | ✅ реализован | `VideoEncoderTests.swift` |
| REC-TC-06 | L2 unit | ✅ реализован | `FileWriterTests.swift` |
| REC-TC-07 | L2 unit | ✅ реализован | `DropMonitorTests.swift` |
| REC-TC-08 | L2 unit | ✅ реализован | `DualFileOutputStageTests.swift` |
| REC-TC-09 | L2 unit | ✅ реализован | `RecordingSessionTests.swift` |
| REC-TC-10 | L2 unit | ✅ реализован | `RecordingSessionTests.swift` |
| REC-TC-11 | L2 unit | ✅ реализован | `RecordingSessionTests.swift`, `CameraSourceLogicTests.swift` |
| REC-TC-12 | L2 unit | ✅ реализован | `MainViewModelRecordTests.swift` |
| REC-TC-13 | L2 unit | ✅ реализован | `RecordingCoordinatorTests.swift` |
| REC-TC-14 | L5 manual | ⬜ acceptance #42 | Requires signed build |
| REC-TC-15 | L5 manual | ⬜ acceptance #42 | TCC revoke |
| REC-TC-16 | L5 manual | ⬜ acceptance #42 | — |
| REC-TC-17 | L5 e2e | ⬜ acceptance #42 | ffprobe |
| REC-TC-18 | L5 manual | ⬜ acceptance #42 | Console.app |
| REC-TC-19 | L5 e2e | ⬜ acceptance #42 | ffprobe; NLE optional |
| REC-TC-20 | L5 manual | ⬜ acceptance #42 | — |
| REC-TC-21 | L5 manual | ⬜ acceptance #42 | — |
| REC-TC-22 | L5 e2e | ⬜ acceptance #42 | kill -9 |
| REC-TC-23 | L5 manual | ⬜ acceptance #42 | TCC revoke Camera |
| REC-TC-24 | L5 manual | ⬜ acceptance #42 | TCC revoke Mic |
| REC-TC-25 | L5 manual | ⬜ acceptance #42 | tccutil reset |
| REC-TC-26 | L5 manual | ⬜ acceptance #42 | TCC revoke mid-recording |
| REC-TC-27 | L5 manual | ⬜ acceptance #42 | — |
| REC-TC-28 | L5 manual | ⬜ acceptance #42 | — |
| REC-TC-29 | L5 manual | ⬜ acceptance #42 | Один дисплей |
| REC-TC-30 | L5 e2e | ⬜ acceptance #42 | kill -9 |
| REC-TC-31 | L5 manual | ⬜ acceptance #42 | После TC-19 |
| REC-TC-32 | L5 manual | ⬜ acceptance #42 | rm ~/Movies/Onset |

---

## Non-functional / Instrumentation

- **Логирование** (`os.Logger`, subsystem `dev.androidbroadcast.Onset`): drop-события, backpressure-сигналы, HW-статус энкодера, старт/стоп сессии. Верифицировать при L5 через Console.app.
- **PII:** никакое имя устройства (`defaultCameraName`, `defaultMicrophoneName`, display description) и путь файла не должны интерполироваться в log-сообщения. Проверить Console.app при L5 (особенно при revoke REC-TC-26 и graceful REC-TC-23/REC-TC-24).
- **Нет сетевого исхода:** `scripts/check-entitlements.sh` подтверждает отсутствие `network.client`/`network.server`; нет `URLSession`/telemetry; проверяется как CI-артефакт.
- **Права файлов:** `~/Movies/Onset/` и файлы создаются с владельцем-пользователем, без group/other-доступа; не использовать `/tmp` или world-readable локации.
- **Main thread:** `AVAssetWriterInput.append` строго сериализован на actor, не блокирует main thread; UI не подвисает во время записи.
- **Деградация MVP:** runtime авто-деградация (изменение параметров) — out of scope; только наблюдение + pre-flight cap. Калибровка битрейтов и авто-тиры — Phase 3.
