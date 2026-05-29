---
type: test-plan
slug: macos-screen-camera-recorder
platform: [desktop]
date: 2026-05-29
source_spec: docs/specs/2026-05-29-macos-screen-camera-recorder.md
status: draft
---

# Test Plan: Onset — нативный macOS-рекордер экрана + камеры + микрофона (MVP v1)

> ℹ️ **Консолидированный план (полный список TC + Appendix A/B).** Срезы по фичам — `docs/<feature>/test-plan.md`; TC-ids стабильны между этим файлом и срезами. Этот файл остаётся источником полного перечня TC, команд верификации и log-маппинга.

| Поле | Значение |
|---|---|
| Продукт | Onset (macOS App, Swift, Apple Silicon, macOS 26+) |
| Источник | `docs/specs/2026-05-29-macos-screen-camera-recorder.md` (status: approved) |
| Acceptance-железо | MacBook Pro 14" M3 Max + внешний дисплей 4K60 + Logitech MX Brio |
| Покрытие | AC-1 … AC-21 |
| Формат | Standard (есть UI-поверхность) |

## Findings

- Спека чётко разделяет **unit/L2-тестируемое без железа** (Validator, SampleRouter, atomic start, gap-fill, CMSync) и **hardware-acceptance L5** (AC-14 no-drops, AC-10 реальные дисплей/fps, AC-3/AC-4 реальная MX Brio, AC-19/AC-20 hotkey/Dock/unplug). План следует этому разделению.
- AC-12 имеет **машинно-проверяемую** часть (SHA-256 идентичность mic-дорожек) — это объективный unit/integration-критерий, не операторо-зависимый.
- AC-14 требует прогона **≥10 мин без срабатывания DegradationLadder**; деградация проверяется отдельным сценарием (AC-15) — два разных TC, не смешивать.
- Три AC (AC-19 hotkey, AC-15/AC-21 деградация-пороги, timecode-трек) содержат implementation-stage калибровку/верификацию против SDK macOS 26 — отмечено в соответствующих TC как зависимость.
- Часть поведения проверяется анализом выходных файлов (`AVAsset`/`ffprobe`: PTS-непрерывность, старт-PTS, длительность дорожек) — это объективные пост-проверки, привязаны к TC синхронизации/дропов.

## Risk Areas

| Область | Риск | Приоритет покрытия |
|---|---|---|
| Синхронизация (host clock, warm-up→T, mic bit-identity) | A/V-дрейф, рассинхрон файлов — рушит главную ценность продукта | P0 |
| Hot path / дропы (bounded queue, capture-layer + consumer-layer, lossless audio) | Потеря кадров, блокировка callback, рассинхрон аудио | P0 |
| Атомарный старт/стоп N writer'ов | Дыра в начале файла, частичные/битые файлы | P0 |
| Отказ источника/writer'а mid-recording (AC-17/AC-20) | Полная потеря записи из-за одного сбоя | P0 |
| Capability-валидация и деградация | Молчаливые дропы, невыполнимая конфигурация | P1 |
| Остановка записи (3 способа, AC-19) | «Потерянная» запись, которую не остановить | P1 |
| Разрешения TCC (включая Notifications) | Источник/уведомления молча недоступны | P1 |
| Камера MX Brio (форматы, MJPEG-decode) | UI предлагает невозможное; лишняя decode-нагрузка | P1 |

## Test Cases

### Smoke (живо ли оно)

#### TC-1 — Запуск приложения открывает окно настроек
| | |
|---|---|
| Priority | P0 |
| Type | ui-instrumentation |
| Type rationale | Один экран, видимое состояние при старте |
| Tier | Smoke |
| Preconditions | Onset установлен, первый/обычный запуск |
| Steps | 1. Запустить Onset |
| Expected Result | Открыто окно настроек с секциями Экран / Камера / Микрофон / Вывод и кнопкой Record |
| Source | Spec §AC-1 |

#### TC-2 — Полный happy-path записи (экран + камера + микрофон)
| | |
|---|---|
| Priority | P0 |
| Type | ui-scenario |
| Type rationale | Многоэкранный путь launch→configure→record→stop→файлы на запущенном приложении |
| Tier | Smoke |
| Preconditions | M3 Max + внешний 4K60 + MX Brio + микрофон; разрешения выданы |
| Steps | 1. Выбрать камеру MX Brio, микрофон, включить экран (внешний дисплей). 2. Выбрать папку. 3. Record. 4. Подождать ~15 c. 5. Stop через menu bar |
| Expected Result | Окно свернулось при Record; в menu bar шёл индикатор+таймер; после Stop открылась папка `Recording <timestamp>/` с `screen.mov` и `camera.mov`, оба воспроизводятся |
| Source | Spec §AC-1,7,8,11 |

#### TC-3 — Запись только экрана (без камеры, без звука)
| | |
|---|---|
| Priority | P0 |
| Type | ui-scenario |
| Type rationale | Базовый путь с одним источником |
| Tier | Smoke |
| Preconditions | Внешний 4K60 |
| Steps | 1. «Без камеры», «Без звука», экран вкл. 2. Record → 10 c → Stop |
| Expected Result | Папка содержит только `screen.mov`; файл валиден |
| Source | Spec §AC-6,11 |

### Feature (корректно ли работает)

#### TC-4 — Validator: валидная конфигурация → RecordingConfiguration
| | |
|---|---|
| Priority | P0 |
| Type | unit |
| Type rationale | Чистая функция (Capabilities + Selections) → Result |
| Tier | Feature |
| Preconditions | Синтетический CapabilitySnapshot (2-движковый чип), валидные Selections |
| Steps | 1. Вызвать `Validator.resolve` |
| Expected Result | `.success(RecordingConfiguration)`; конфиг конструируется только Validator'ом (parse-don't-validate) |
| Source | Spec §Technical Approach, §AC-15 |

#### TC-5 — Validator: fps выше refresh дисплея авто-корректируется
| | |
|---|---|
| Priority | P1 |
| Type | unit |
| Type rationale | Чистая логика cross-setting clamp |
| Tier | Feature |
| Preconditions | Снимок с дисплеем maxRefresh=60, Selection fps=120 |
| Steps | 1. `Validator.resolve` |
| Expected Result | fps скламплен до 60; возвращён `ValidationIssue(.autoCorrected)` с причиной |
| Source | Spec §AC-15 |

#### TC-6 — Validator: невозможная комбинация кодек×разрешение отклоняется/корректируется
| | |
|---|---|
| Priority | P1 |
| Type | unit |
| Type rationale | Чистая логика проверки лимитов кодека |
| Tier | Feature |
| Preconditions | H.264 + 5K (>4096 по ширине) |
| Steps | 1. `Validator.resolve` |
| Expected Result | Комбинация помечена как отклонённая/недоступная с причиной; не приводит к старту записи |
| Source | Spec §AC-5,16 |

#### TC-7 — CapabilityMatrix: неизвестный чип → консервативный fallback
| | |
|---|---|
| Priority | P2 |
| Type | unit |
| Type rationale | Чистый lookup + fallback по P-ядрам |
| Tier | Feature |
| Preconditions | `ChipTier.unknown(coreHint:)` |
| Steps | 1. Запросить бюджет для неизвестного чипа |
| Expected Result | Возвращён консервативный бюджет по числу P-ядер; single-stream потолки берутся из probe (реальные) |
| Source | Spec §Technical Approach, §AC-15 |

#### TC-8 — Кодек по умолчанию = аппаратный HEVC, не software
| | |
|---|---|
| Priority | P0 |
| Type | integration |
| Type rationale | Взаимодействие с VideoToolbox probe (реальный API, без записи) |
| Tier | Feature |
| Preconditions | Acceptance-железо |
| Steps | 1. Запросить дефолтный кодек через `VTCopyVideoEncoderList`/probe |
| Expected Result | Выбран HW HEVC (`IsHardwareAccelerated == true`); приложение не выбирает SW-энкодер по умолчанию |
| Source | Spec §AC-16 |

#### TC-9 — SampleRouter: микрофон fan-out в оба файла идентичными буферами
| | |
|---|---|
| Priority | P0 |
| Type | unit |
| Type rationale | Топология маршрутизации на синтетических CMSampleBuffer |
| Tier | Feature |
| Preconditions | Fake EncodingWriter ×2 (screen, camera), источник микрофона |
| Steps | 1. Прогнать набор mic-буферов через SampleRouter |
| Expected Result | Оба writer'а получили идентичные mic-буферы (один и тот же объект/содержимое); видеобуферы — только в свой writer |
| Source | Spec §AC-9 |

#### TC-10 — SampleRouter: один видеоисточник → микрофон в его единственный файл
| | |
|---|---|
| Priority | P1 |
| Type | unit |
| Type rationale | Вариант топологии |
| Tier | Feature |
| Preconditions | Один fake writer (только экран) + микрофон |
| Steps | 1. Прогнать mic-буферы |
| Expected Result | Mic попадает в единственный присутствующий writer |
| Source | Spec §AC-9 |

#### TC-11 — Атомарный старт: сэмплы с PTS < T отбрасываются
| | |
|---|---|
| Priority | P0 |
| Type | unit |
| Type rationale | Логика admit/drop относительно T на fake writer |
| Tier | Feature |
| Preconditions | Fake writer; поток буферов с PTS до и после T |
| Steps | 1. Установить T. 2. Подать буферы PTS<T и PTS≥T |
| Expected Result | Записаны только PTS≥T; PTS<T отброшены |
| Source | Spec §AC-7 |

#### TC-12 — Warm-up: T выбирается после first-sample от всех источников
| | |
|---|---|
| Priority | P0 |
| Type | unit |
| Type rationale | Контракт стартовой последовательности на fake-источниках |
| Tier | Feature |
| Preconditions | Fake-источники с разной стартовой задержкой |
| Steps | 1. Старт; источник A эмитит сразу, B — с задержкой |
| Expected Result | T выбран только после первого буфера от обоих; в начале файлов нет «дыры» |
| Source | Spec §Technical Approach (warm-up→T), §AC-7,12 |

#### TC-13 — gap-fill тишиной выполняется ДО fan-out (идентичность сохранена)
| | |
|---|---|
| Priority | P0 |
| Type | unit |
| Type rationale | Логика заполнения разрыва PTS до разветвления |
| Tier | Feature |
| Preconditions | Аудиопоток с искусственным разрывом PTS, два fake writer'а |
| Steps | 1. Подать поток с gap через AudioCaptureSource→SampleRouter |
| Expected Result | Тишина вставлена один раз до fan-out; оба writer'а получают идентичный заполненный поток (AC-9 не нарушен) |
| Source | Spec §AC-13, §Technical Approach |

#### TC-14 — CMSyncConvertTime: PTS микрофона приводятся к host clock
| | |
|---|---|
| Priority | P1 |
| Type | unit |
| Type rationale | Чистая конвертация времени |
| Tier | Feature |
| Preconditions | Mic-буферы на «аудио-часах», смещённых от host |
| Steps | 1. Прогнать конвертацию перед append |
| Expected Result | PTS приведены к host-шкале; монотонность сохранена |
| Source | Spec §AC-9, §Technical Approach |

#### TC-15 — Capability discovery: камера отдаёт только реально поддерживаемые форматы
| | |
|---|---|
| Priority | P1 |
| Type | integration |
| Type rationale | Реальное перечисление AVCaptureDevice.Format (без записи) |
| Tier | Feature |
| Preconditions | MX Brio подключена |
| Steps | 1. Перечислить `device.formats` → построить combos |
| Expected Result | Инвариант: UI-список содержит только комбинации из `device.formats`, ни одной сверх. Baseline для Logitech MX Brio (зафиксирован на дату плана): {4K@30, 1080p@60, 720p@90}, 4K@60 отсутствует. При смене железа baseline обновить по фактическому `device.formats` |
| Source | Spec §AC-3 |

#### TC-16 — UI: пикеры разрешения/fps камеры показывают только поддерживаемое
| | |
|---|---|
| Priority | P1 |
| Type | ui-instrumentation |
| Type rationale | Один экран, привязка пикеров к capability |
| Tier | Feature |
| Preconditions | MX Brio выбрана |
| Steps | 1. Открыть пикеры разрешения и fps |
| Expected Result | Только {4K@30, 1080p@60, 720p@90}; невозможные комбинации отсутствуют |
| Source | Spec §AC-3 |

#### TC-17 — UI: превью камеры показывается/переключается/скрывается
| | |
|---|---|
| Priority | P1 |
| Type | ui-instrumentation |
| Type rationale | Видимое состояние одного экрана при смене источника |
| Tier | Feature |
| Preconditions | ≥1 камера + «Без камеры» |
| Steps | 1. Выбрать камеру → 2. Сменить камеру → 3. Выбрать «Без камеры» |
| Expected Result | Превью появилось; переключилось на новую камеру; при «Без камеры» скрыто/плейсхолдер |
| Source | Spec §AC-4 |

#### TC-18 — UI: недоступные кодек/контейнер задизейблены с причиной
| | |
|---|---|
| Priority | P2 |
| Type | ui-instrumentation |
| Type rationale | Состояние контролов вывода |
| Tier | Feature |
| Preconditions | Конфигурация, где комбинация не поддерживается железом |
| Steps | 1. Открыть пикеры кодека/контейнера |
| Expected Result | Недоступная опция серая + поясняющая причина (tooltip/инлайн), не скрыта |
| Source | Spec §AC-5 |

#### TC-19 — UI: Record активна только при ≥1 видеоисточнике
| | |
|---|---|
| Priority | P0 |
| Type | ui-instrumentation |
| Type rationale | Гейтинг кнопки от валидности |
| Tier | Feature |
| Preconditions | Окно настроек |
| Steps | 1. «Без камеры» + экран выкл → 2. Включить экран |
| Expected Result | При нуле видеоисточников Record неактивна с подсказкой; после включения экрана — активна |
| Source | Spec §AC-6 |

#### TC-20 — UI: menu bar показывает таймер, счётчик дропов, Stop + hotkey
| | |
|---|---|
| Priority | P0 |
| Type | ui-instrumentation |
| Type rationale | Состояние NSStatusItem во время записи |
| Tier | Feature |
| Preconditions | Идёт запись |
| Steps | 1. Открыть dropdown статус-айтема |
| Expected Result | Показаны прошедшее время, счётчик дропов (с причиной), пункт Stop с key-equivalent глобального hotkey; при дропах индикатор сигнализирует деградацию |
| Source | Spec §AC-8 |

#### TC-21 — Остановка записи тремя способами при свёрнутом окне
| | |
|---|---|
| Priority | P0 |
| Type | ui-scenario |
| Type rationale | Журналируемый путь по нескольким поверхностям на запущенном приложении |
| Tier | Feature |
| Preconditions | Идёт запись, окно свёрнуто; activation policy .regular |
| Steps | 1. Остановить через menu bar (новый прогон). 2. Через глобальный hotkey. 3. Через клик по Dock-иконке (возврат окна) → Stop |
| Expected Result | Все три способа останавливают запись и финализируют файлы; индикатор записи всегда виден; запись не «теряется» |
| Source | Spec §AC-19 |

#### TC-22 — Восстановленное во время записи окно: контролы задизейблены
| | |
|---|---|
| Priority | P2 |
| Type | ui-instrumentation |
| Type rationale | Состояние окна в режиме записи |
| Tier | Feature |
| Preconditions | Идёт запись, окно восстановлено из Dock |
| Steps | 1. Осмотреть окно |
| Expected Result | Видны таймер + Stop + счётчик дропов; конфигурационные контролы задизейблены с пояснением «недоступно во время записи» |
| Source | Spec §Technical Constraints (minimize-not-hide), §AC-19 |

#### TC-23 — Разрешения TCC запрашиваются; denied-состояния понятны
| | |
|---|---|
| Priority | P1 |
| Type | ui-scenario |
| Type rationale | Системные диалоги + состояние приложения, запущенное приложение |
| Tier | Feature |
| Preconditions | Чистый TCC-стейт: `tccutil reset ScreenCapture <bundle-id>` + `tccutil reset Camera <bundle-id>` + `tccutil reset Microphone <bundle-id>` (app-specific, без sudo). Альтернатива для полного сброса — отдельный тестовый аккаунт macOS |
| Steps | 1. Первый запуск → запросы Screen Recording, Camera, Microphone, Notifications. 2. Отклонить камеру |
| Expected Result | Запросы показаны; при отказе камеры источник недоступен с подсказкой «Открыть Системные настройки»; при отказе Notifications ошибки всё равно видны в NSStatusItem (fallback) |
| Source | Spec §AC-18 |

#### TC-38 — Accessibility: клавиатурная навигация и VoiceOver
| | |
|---|---|
| Priority | P2 |
| Type | ui-instrumentation |
| Type rationale | Проверка a11y-свойств контролов одного экрана + menu bar |
| Tier | Feature |
| Preconditions | VoiceOver вкл; Full Keyboard Access вкл |
| Steps | 1. Tab-навигация по окну настроек (секции Экран/Камера/Микрофон/Вывод → Record). 2. Активировать Record с клавиатуры. 3. VoiceOver: озвучить контролы, disabled-состояние во время записи, индикатор записи и пункт Stop в NSStatusItem. 4. Проверить, что признак деградации (AC-8/21) озвучивается/не только цветом |
| Expected Result | Все interactive-элементы достижимы с клавиатуры с видимым focus ring и корректным tab order; Record активируется без мыши; VoiceOver читает метки контролов, disabled-состояние и статус записи; деградация сообщается не только цветом (текст/символ + VoiceOver) |
| Source | Spec §non_functional.a11y, §AC-1,8,19,21 |

### Regression / отказоустойчивость

#### TC-24 — Отказ writer'а mid-recording: isolateAndContinue
| | |
|---|---|
| Priority | P0 |
| Type | integration |
| Type rationale | Несколько компонентов (writer + coordinator + health), инъекция ошибки записи |
| Tier | Regression |
| Preconditions | Два writer'а; у одного инъецируется фатальная ошибка записи |
| Steps | 1. Старт. 2. Спровоцировать отказ writer'а экрана |
| Expected Result | `screen.*` финализирован как частичный; `camera.*` продолжает; пользователь уведомлён; запись не потеряна целиком |
| Source | Spec §AC-17 |

#### TC-25 — SampleRouter прекращает fan-out в мёртвый writer (lock-free)
| | |
|---|---|
| Priority | P0 |
| Type | unit |
| Type rationale | Чтение atomic isAlive на hot path, fake writer'ы |
| Tier | Regression |
| Preconditions | Два fake writer'а; у одного `isAlive=false` |
| Steps | 1. Подать буферы после флипа флага |
| Expected Result | Router перестал слать в мёртвый writer, продолжает в живой; без блокировки/actor-хопа |
| Source | Spec §AC-17,20, §Technical Approach |

#### TC-26a — Unplug камеры при записи экран+камера: камера частична, экран продолжает
| | |
|---|---|
| Priority | P0 |
| Type | ui-scenario |
| Type rationale | Реальный аппаратный сбой на запущенном приложении |
| Tier | Regression |
| Preconditions | Идёт запись экран+камера; MX Brio по USB |
| Steps | 1. Отключить USB-камеру на ~30-й секунде. 2. Подождать. 3. Stop |
| Expected Result | `camera.*` финализирован как частичный (читается в QuickTime); `screen.*` продолжил без прерывания; пользователь уведомлён системным уведомлением (или fallback по AC-18); лог `source.failure` с типом camera-unplug |
| Source | Spec §AC-20 |

#### TC-26b — Unplug единственного видеоисточника: финализация в error
| | |
|---|---|
| Priority | P0 |
| Type | ui-scenario |
| Type rationale | Терминальная ветка при падении последнего источника |
| Tier | Regression |
| Preconditions | Идёт запись ТОЛЬКО камеры (экран выкл); MX Brio по USB |
| Steps | 1. Отключить USB-камеру на ~30-й секунде |
| Expected Result | `camera.*` финализирован как частичный и сохранён (не потерян); состояние → `error`; пользователь уведомлён |
| Source | Spec §AC-20 |

#### TC-27 — TOCTOU: устройство исчезло между настройкой и Record
| | |
|---|---|
| Priority | P1 |
| Type | integration |
| Type rationale | Coordinator + CapabilityService generation re-check |
| Tier | Regression |
| Preconditions | Конфиг построен на снимке с камерой; камера отключена до нажатия Record |
| Steps | 1. Настроить с камерой. 2. Отключить камеру. 3. Нажать Record |
| Expected Result | Re-validate против текущего generation; вместо старта — сообщение о пропаже устройства; не стартует с битым конфигом |
| Source | Spec §Technical Approach (re-validate), §AC-2 |

#### TC-28 — DroppedFrameStats учитывает capture-layer и consumer-layer дропы
| | |
|---|---|
| Priority | P1 |
| Type | integration |
| Type rationale | Подписки на didDrop/SCFrameStatus + очередь, проверка счётчиков |
| Tier | Regression |
| Preconditions | Инъекция: poolExhausted (камера), переполнение очереди (encoderBound) |
| Steps | 1. Спровоцировать оба класса дропов |
| Expected Result | Оба класса учтены в `DroppedFrameStats` с корректными причинами (`captureBound`/`poolExhausted`/`encoderBound`/`diskBound`); ничего не теряется молча |
| Source | Spec §AC-21 |

#### TC-29 — Аудио-путь лосслесс: backpressure видео не «обкусывает» mic
| | |
|---|---|
| Priority | P0 |
| Type | unit |
| Type rationale | Политика очередей: drop-oldest только для видео |
| Tier | Regression |
| Preconditions | Переполнение видео-очереди одного writer'а при идущем mic-потоке |
| Steps | 1. Спровоцировать backpressure видео-writer'а |
| Expected Result | Видео drop-oldest сработал; mic-буферы НЕ дропнуты ни в одном файле; bit-identity сохранена |
| Source | Spec §AC-21,9,12 |

### Hardware-acceptance (L5, только на acceptance-железе)

#### TC-30 — AC-14: dual-stream 4K60+4K30 HEVC ≥10 мин без дропов
| | |
|---|---|
| Priority | P0 |
| Type | e2e |
| Type rationale | Release-critical перф-гарантия на реальном железе, не делится на меньший scope |
| Tier | Acceptance (L5) |
| Preconditions | MacBook Pro 14" M3 Max + внешний 4K60 + MX Brio; без срабатывания DegradationLadder в окне измерения |
| Steps | 1. Запись экран 4K60 + камера 4K30 (HEVC) ≥10 мин. 2. Извлечь per-frame PTS-дельты (Appendix-команда `ffprobe -show_entries frame=pkt_pts_time`). 3. Прочитать `DroppedFrameStats` из лога `recording.stop`. 4. Снять os_signpost-интервалы времени удержания буфера в capture-callback |
| Expected Result | Steady-state окно = [warm-up 2 c … T_end]. Pass = ВСЕ: (1) `DroppedFrameStats`==0 (capture-layer + consumer-layer); (2) ни одной PTS-дельты > 1.5× номинального интервала (1/60 c) → нет пропущенных кадров; (3) деградация не срабатывала в окне; (4) max время удержания в capture-callback < `minimumFrameInterval × (queueDepth−1)` (для экрана ≈ 4–5 интервалов) — подтверждает «callback не блокируется» |
| Source | Spec §AC-14, §Technical Constraints (hot path) |

#### TC-31 — AC-12: синхронизация файлов ≤1 кадр (объективно по audio-хешу)
| | |
|---|---|
| Priority | P0 |
| Type | integration |
| Type rationale | Пост-анализ выходных файлов (извлечение PCM, SHA-256) |
| Tier | Acceptance (L5) |
| Preconditions | Запись экран+камера+микрофон |
| Steps | 1. Извлечь mic-дорожки обоих файлов. 2. Сравнить SHA-256. 3. Сверить старт-PTS |
| Expected Result | Mic-дорожки бит-в-бит идентичны (хеши совпадают); старт-PTS на общей host-шкале; выравнивание ≤1 кадр |
| Source | Spec §AC-12,9 |

#### TC-32 — AC-10: экран пишется в оригинальном разрешении/fps дисплея, SDR
| | |
|---|---|
| Priority | P1 |
| Type | e2e |
| Type rationale | Реальный дисплей, проверка свойств выходного файла |
| Tier | Acceptance (L5) |
| Preconditions | Внешний 4K60 |
| Steps | 1. Запись экрана. 2. Проверить разрешение/fps/цвет файла |
| Expected Result | `screen.*` = 3840×2160 @ 60fps, 8-bit SDR (без HDR-метаданных) |
| Source | Spec §AC-10 |

#### TC-33 — AC-13: единый sample rate 48 кГц, аудио не короче видео
| | |
|---|---|
| Priority | P1 |
| Type | integration |
| Type rationale | Пост-анализ длительностей дорожек выходного файла |
| Tier | Acceptance (L5) |
| Preconditions | Запись с микрофоном ≥5 мин |
| Steps | 1. Проверить sample rate и длительность аудио vs видео |
| Expected Result | Аудио 48 кГц; длительность аудио ≈ видео (нет накопленного укорачивания); разрывы заполнены тишиной |
| Source | Spec §AC-13 |

#### TC-39 — Memory footprint в пределах бюджета на длинной записи
| | |
|---|---|
| Priority | P1 |
| Type | e2e |
| Type rationale | Перф-свойство (memory budget) на реальном железе, длинный прогон |
| Tier | Acceptance (L5) |
| Preconditions | M3 Max + внешний 4K60 + MX Brio |
| Steps | 1. Dual-stream запись 10 мин. 2. Снять peak memory footprint (Instruments Allocations / `task_vm_info` / `os_proc_available_memory`) |
| Expected Result | Peak footprint ≤ заданный потолок (вывести из глубины bounded-очередей × ~33 МБ × 2 источника + база); нет линейного роста памяти со временем (ограниченные очереди работают) |
| Source | Spec §Technical Constraints (bounded queue / memory budget), §AC-21 |

#### TC-40 — 1-движковый чип: dual-stream → деградация/видимые дропы (вторая половина SLA)
| | |
|---|---|
| Priority | P1 |
| Type | e2e |
| Type rationale | Перф-негатив к TC-30 на железе с одним encode-движком |
| Tier | Acceptance (L5) |
| Preconditions | Mac на base/Pro M-чипе (1 encode engine), при наличии; внешний 4K60 + MX Brio |
| Steps | 1. Dual-stream 4K60 экран + 4K30 камера (HEVC) |
| Expected Result | Срабатывает DegradationLadder ИЛИ ненулевой `DroppedFrameStats` с причиной `encoderBound`, видимый в NSStatusItem (не молча); mic-дорожки остаются бит-в-бит идентичны (lossless audio не нарушен) |
| Source | Spec §non_functional.sla (1-движковая ветка), §AC-15,21 |

### Edge Cases & Negative Scenarios

#### TC-34 — Нет подключённых камер/микрофонов
| | |
|---|---|
| Priority | P2 |
| Type | ui-instrumentation |
| Type rationale | Empty-state одного экрана |
| Tier | Feature |
| Preconditions | Камеры/микрофоны отключены |
| Steps | 1. Открыть окно настроек |
| Expected Result | Камера показывает только «Без камеры» + плейсхолдер превью; микрофон — «Без звука»; запись экрана всё ещё возможна |
| Source | Spec §AC-1,6 |

#### TC-35 — Папка вывода стала недоступной для записи
| | |
|---|---|
| Priority | P2 |
| Type | integration |
| Type rationale | Проверка пути перед стартом |
| Tier | Regression |
| Preconditions | Выбрана папка, затем сделана read-only/недоступной |
| Steps | 1. Нажать Record |
| Expected Result | Понятная ошибка до старта (не молчаливый сбой); запись не стартует с битым путём |
| Source | Spec §AC-11,17 |

#### TC-36 — Hotplug устройства во время нахождения в окне настроек
| | |
|---|---|
| Priority | P2 |
| Type | integration |
| Type rationale | CapabilityService hotplug-инвалидация → обновление списков |
| Tier | Regression |
| Preconditions | Окно настроек открыто |
| Steps | 1. Подключить/отключить камеру |
| Expected Result | Список устройств обновился (generation bump); выбор реконсилится |
| Source | Spec §AC-2 |

#### TC-37 — AC-15: адаптивная деградация под нагрузкой (отдельно от AC-14)
| | |
|---|---|
| Priority | P1 |
| Type | e2e |
| Type rationale | Динамическое поведение на реальном железе под термал/перегрузкой |
| Tier | Acceptance (L5) |
| Preconditions | Чип/условия, провоцирующие throttle (или 1-движковый чип на dual-stream) |
| Steps | 1. Запустить нагрузочную запись до срабатывания ladder |
| Expected Result | DegradationLadder срабатывает по измеримым триггерам (порядок: камера fps→экран fps→битрейт→отключение камеры); дропы вскрыты в UI; нет осцилляции (ratchet/cooldown работают) |
| Source | Spec §AC-15 |

#### TC-41 — Принудительное завершение приложения во время записи: файлы читаемы
| | |
|---|---|
| Priority | P1 |
| Type | ui-scenario |
| Type rationale | Краш-устойчивость выходных файлов на запущенном приложении |
| Tier | Regression |
| Preconditions | Идёт запись ≥30 c |
| Steps | 1. Force Quit (Opt+Cmd+Esc → Force Quit) или `kill -9`. 2. Открыть папку записи |
| Expected Result | Файлы существуют и открываются в QuickTime/VLC (могут быть обрезаны, но не corrupted). Если не читаются — поднять вопрос об `movieFragmentInterval` в спеке как явной настройке writer'а |
| Source | [inferred from code] / индустриальный failure-path; уточнить AC при необходимости |

#### TC-42 — Сон/пробуждение системы во время записи
| | |
|---|---|
| Priority | P2 |
| Type | ui-scenario |
| Type rationale | Системное прерывание capture-таймлайна на запущенном приложении |
| Tier | Regression |
| Preconditions | Идёт запись |
| Steps | 1. Принудить display/system sleep. 2. Разбудить через ~30 c. 3. Stop |
| Expected Result | Запись либо продолжается корректно (gap-fill/таймлайн консистентен), либо gracefully завершается с уведомлением — без молчаливой потери/порчи данных |
| Source | [inferred from code] / edge вне MVP-спеки |

#### TC-43 — Конфликт регистрации глобального hotkey (негатив AC-19)
| | |
|---|---|
| Priority | P2 |
| Type | ui-instrumentation |
| Type rationale | Деградированный путь одного из трёх способов остановки |
| Tier | Regression |
| Preconditions | Сочетание hotkey занято другим приложением/системой |
| Steps | 1. Запустить с конфликтующим hotkey. 2. Начать запись |
| Expected Result | Факт недоступности hotkey виден в окне настроек; остановка по-прежнему доступна через menu bar и Dock-иконку (запись не «теряется») |
| Source | Spec §Technical Constraints (hotkey), §AC-19 |

## Coverage Matrix

| AC | TC(s) |
|---|---|
| AC-1 | TC-1, TC-2, TC-34 |
| AC-2 | TC-2, TC-27, TC-36 |
| AC-3 | TC-15, TC-16 |
| AC-4 | TC-17 |
| AC-5 | TC-6, TC-18 |
| AC-6 | TC-3, TC-19, TC-34 |
| AC-7 | TC-2, TC-11, TC-12 |
| AC-8 | TC-20 |
| AC-9 | TC-9, TC-10, TC-13, TC-29, TC-31 |
| AC-10 | TC-32 |
| AC-11 | TC-2, TC-3, TC-35 |
| AC-12 | TC-12, TC-31, TC-29 |
| AC-13 | TC-13, TC-33 |
| AC-14 | TC-30 |
| AC-15 | TC-4, TC-5, TC-37, TC-40 |
| AC-16 | TC-6, TC-8 |
| AC-17 | TC-24, TC-25, TC-35 |
| AC-18 | TC-23 |
| AC-19 | TC-21, TC-22, TC-38, TC-43 |
| AC-20 | TC-25, TC-26a, TC-26b |
| AC-21 | TC-20, TC-28, TC-29, TC-39, TC-40 |
| non_functional.sla (AC-14) | TC-30, TC-39 |
| non_functional.a11y | TC-38 |
| Краш/прерывание (inferred) | TC-41, TC-42 |

## Suggested Automation Candidates

- **Высокий ROI (unit, без железа):** TC-4–TC-14, TC-25, TC-29 — Validator, SampleRouter, atomic start, warm-up, gap-fill, CMSync, lossless-audio. Чистые функции/синтетические буферы → стабильные быстрые тесты (XCTest).
- **Integration (in-memory/реальные API без длинной записи):** TC-8, TC-15, TC-24, TC-27, TC-28, TC-31, TC-33, TC-36. Часть требует подключённой MX Brio.
- **Пост-анализ файлов скриптом:** TC-30, TC-31, TC-32, TC-33 — разбор PTS/длительности/хешей через `ffprobe`/`AVAsset` автоматизируется как проверочный скрипт поверх записанных файлов.
- **Ручные/MCP-сценарии (manual-tester):** TC-2, TC-3, TC-21, TC-23, TC-26, TC-37 — журналируемые пути и аппаратные сбои.
- **screenshot (additive, опц.):** визуальная регрессия окна настроек в Light/Dark — добавить, когда стабилизируется дизайн (по design-brief), не как единственное покрытие.

## Non-functional / Instrumentation

Локальное desktop-приложение без бэкенда: телеметрия не уходит наружу, но диагностические события записи обязательны для разбора инцидентов (дропы, сбои источников). Логгер — по `~/.claude/rules/logging.md` (единая система логирования, без `print`); конкретная подсистема (`os.Logger`/`OSLog`) — выбор на этапе реализации (проектного конвеншна пока нет; зафиксировать при создании проекта).

### Log events
- `recording.start` — источники, кодек, контейнер, разрешение/fps на источник, выбранный T (host time), чип/tier.
- `recording.stop` — длительность, итоговые `DroppedFrameStats` на источник с разбивкой по причинам, путь файлов.
- `frame.dropped` (агрегированно/throttled) — источник, причина (`captureBound`/`poolExhausted`/`encoderBound`/`diskBound`), счётчик за окно.
- `source.failure` — тип (camera-unplug / permission-revoke), источник, частичная финализация файла.
- `writer.failure` — выход, ошибка, isolate-решение.
- `degradation.step` — сработавший шаг ladder, триггер (drops/thermal/memory), значения метрик-триггеров.
- `capability.probe` — обнаруженный чип/движки, HW-кодеки, бюджет CapabilityMatrix (на launch).
- `permission` — статус Screen Recording / Camera / Microphone / Notifications.

### Metrics
N/A: локальное приложение без сервера/сбора метрик. Эквивалент — `DroppedFrameStats` и thermalState, доступные в UI и логах во время записи (не внешняя метрик-система).

### Traces
N/A: нет распределённой системы.

### Alerts
N/A: нет серверной инфраструктуры. Пользовательский аналог — системные уведомления (AC-17/20/21) + индикатор деградации в NSStatusItem (AC-8/21).

### Dashboards
N/A: локальное приложение.

## Appendix A — Команды верификации (для L5-TC)

Конкретные команды для пост-анализа выходных файлов (TC-30/31/32/33/39):

```bash
# Разрешение / fps / цвет (SDR) — TC-32
ffprobe -v quiet -print_format json -show_streams screen.mov \
  | jq '.streams[] | select(.codec_type=="video") | {width,height,r_frame_rate,pix_fmt,color_transfer}'

# Per-frame PTS-дельты для детекции пропусков (TC-30): дельта > 1.5×(1/60)=0.025с = пропуск
ffprobe -v quiet -select_streams v -show_entries frame=pkt_pts_time -of csv screen.mov

# Sample rate аудио (TC-33)
ffprobe -v quiet -show_entries stream=sample_rate -select_streams a screen.mov

# Длительность аудио vs видео (TC-33)
ffprobe -v quiet -show_entries stream=codec_type,duration -of csv screen.mov

# SHA-256 mic-дорожек обоих файлов — должны совпасть (TC-31)
ffmpeg -i screen.mov -map 0:a:0 -f s24le - 2>/dev/null | shasum -a 256
ffmpeg -i camera.mov -map 0:a:0 -f s24le - 2>/dev/null | shasum -a 256

# start_time обоих файлов на host-шкале — при записи без микрофона (TC-31 без mic)
ffprobe -v quiet -show_entries format=start_time -of csv screen.mov camera.mov
```

## Appendix B — Верификация через логи

Привязка диагностических событий (см. Non-functional / Instrumentation) к TC — объективный способ проверки рантайм-поведения:

| TC | Событие лога | Что проверять |
|---|---|---|
| TC-24 | `writer.failure` | выход, ошибка, isolate-решение |
| TC-26a/26b | `source.failure` | тип (camera-unplug), частичная финализация |
| TC-28 | `frame.dropped` | причины `captureBound`/`poolExhausted`/`encoderBound`/`diskBound` |
| TC-30 | `recording.stop` | поле `DroppedFrameStats` == 0 |
| TC-37/TC-40 | `degradation.step` | сработавший шаг + триггер; cooldown между шагами; ratchet |
| TC-8/TC-23 | `permission` | статусы Screen Recording/Camera/Microphone/Notifications |

Механизмы инъекции (для unit/integration TC-24/25/28/29): fake `EncodingWriter`, реализующий протокол и выбрасывающий ошибку на N-м буфере (TC-24/25); ограничение глубины bounded-очереди до 1 + подача буферов быстрее write-rate (TC-28 `encoderBound`); `alwaysDiscardsLateVideoFrames=true` + перегрузка fake capture-источника (TC-28 `poolExhausted`). DegradationLadder выносится в чистый decider-автомат (вход: серия метрик → выход: серия шагов) для unit-теста гистерезиса без железа и без флака (см. TC-37).
