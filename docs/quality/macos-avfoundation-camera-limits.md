# Ограничения захвата камеры через AVFoundation на macOS

**Статус:** 4K-вердикт обновлён 2026-07-02 (L5 на реальном железе, MX Brio + встроенная FaceTime
MacBook) — см. «История вердикта: 4K» ниже. 60fps-вердикт (verified L5 2026-06-09) остаётся в силе.
**Источник:** #113 (закрыта — полный разбор стека), #265 (закрыта — 4K lock-lifecycle fix),
#177 (закрыта — 4K, superseded #265), #178 (закрыта — 60fps, hardware-constraint Brio).

---

## TL;DR

| Камера | Заявлено / железо | Реально через AVFoundation на macOS |
|---|---|---|
| MX Brio (внешняя UVC) | 4K30 + 1080p60 | **4K30 достижим и удерживается всю запись** (record path, `allowAboveFullHD: true`); 60fps недостижим |
| Встроенная FaceTime (Apple ISP) | 1080p30 | 1080p30 чисто (идеальная каденция) |
| **Итог** | — | **4K достижим через AVFoundation на macOS** — device-lock, удержанный через `startRunning()` (#265); **60fps остаётся недостижим** ни на одной из этих камер (Brio — hardware-constraint устройства, #178) |

---

## История вердикта: 4K

Первоначальный вердикт (2026-06-09, ниже в этом документе до правки 2026-07-02) считал 4K
недостижимым через AVFoundation: `device.activeFormat`, выставленный на 3840×2160, после старта
сессии реверсировался в 1080p (`readBack=1080p`) — и через `setActiveFormat`, и через
`session.sessionPreset = .hd4K3840x2160`.

Расследование #265 (2026-06-23 — 2026-06-29) нашло, что это наблюдение держалось на двух
конфаундах, а не на фундаментальном лимите стека:

1. **USB2-хаб** — исходный замер шёл через USB2-хаб, где Brio анонсирует только 1080p; прямое
   USB3-подключение (`ioreg`: `UsbLinkSpeed=5 Gbps`) снимает это ограничение.
2. **Баг lock-lifecycle в коде Onset** — `unlockForConfiguration()` вызывался ДО `startRunning()`,
   и `activeFormat = 4K` молча реверсировался в 1080p между вызовами. Это баг приложения
   (`CameraSource+SessionSetup.swift`), не ограничение macOS/AVFoundation/CMIO.

Фикс (#265): держать device-lock через весь `startRunning()`. Repro-спайк (метод OBS) дал 108/108
настоящих 4K-буферов; `CameraSource4KDeliveryL5Tests` фиксирует модальную доставку 3840×2160 с
hold-lock как регрессионный тест.

Живой прогон полного приложения (спайк T-8, 2026-07-02, MX Brio) подтвердил эффект не только на
изолированном пробнике, но и на всём стеке записи: `activeFormat` = 3840×2160 и сразу после старта,
и перед остановкой — 4K удержан всю запись. Worst-case повтор (экран 4K60 под полноэкранным
движением, idle=0, худший сценарий encode-нагрузки) дал **ноль реальных потерь кадров на обоих
потоках** (camera + screen), enc_ms_max 1.7 мс (экран) / 4.6 мс (камера) при слоте 16.7 мс. Выходные
файлы: camera 3840×2160 HEVC ~29.8 fps, screen 3840×2160 HEVC ~59.9 fps. Подробности:
`swarm-report/research/research-4k-dual-recording.md`, `swarm-report/4k-spikes-state.md`.

**Итог: 4K достижим через AVFoundation на macOS без смены слоя захвата.** #177 закрыт как
superseded #265. Прежний вывод «4K только через CMIO/IOKit» был артефактом USB2-хаба и
lock-lifecycle-бага выше, не фундаментальным ограничением стека.

Между #265 (2026-06-29) и этим спайком (2026-07-02) record-путь на короткое время кэпился на
1080p (PR #281): наблюдался камера-стуттер под конкурентной 4K60-записью экрана, ошибочно
приписанный «AVFoundation отдаёт только 1080p». Спайк T-8 показал реальную причину — камера-энкодер
строился под 4K-размеры, пока сама камера (до фикса #265 в проверяемой ветке) отдавала 1080p,
т.е. апскейл ×4 впустую нагружал VT-сессию; на актуальном коде (после #265) такого рассогласования
нет — энкодер всегда строится от фактически resolved-формата (`CapabilityResolver` →
`RecordingComponentFactories`).

---

## 60fps недостижим (актуально, не затронуто вердиктом 4K)

Brio анонсирует формат 1080p60 (`420v`), но реальный захват даёт ~20fps — доказано сырым
PTS-замером (`CMSampleBufferGetPresentationTimeStamp`): дельты между кадрами ~50 мс,
std < 1 мс (стабильный тротл, не случайные дропы).

`activeVideoMinFrameDuration` / `activeVideoMaxFrameDuration` lock (и на 30, и на 60) каденцию
**не контролирует** на macOS-UVC.

Две гипотезы исключены:

1. **Low-light auto-exposure** — яркая сцена с движением дала те же ~20fps.
2. **USB 2** — подтверждён USB 3 (см. выше).

Встроенная FaceTime аппаратно ограничена 30fps: все 7 форматов `420v` ≤ 30fps; 60fps в
железе отсутствует. 30fps отдаётся идеально (`ptsFps=29.985`, `std=0.001 мс`,
`verify-cfr` `packet-rate=30`, без дублирования).

**#178 закрыт как hardware-constraint** (2026-06-23): официальный cap Logitech для Brio — 4K только
30fps (60 доступно лишь на 1080p/720p); но и 1080p60 на практике Brio отдаёт ~24–25fps на любом
конфиге, инвариантно к настройкам и Logitech-софту — недодача самого железа, не лимит
AVFoundation/macOS и не фиксится сменой стека захвата (CMIO/IOKit не помогут здесь, в отличие от
4K-кейса выше).

---

## Корневая причина (актуально)

**4K:** не было ограничением стека — баг приложения (lock-lifecycle) + тестовый USB2-хаб. Исправлено
#265; см. «История вердикта» выше.

**60fps:** hardware-constraint конкретно Brio (см. #178 выше); встроенная FaceTime физически не
поддерживает 60fps ни на каком слое захвата.

---

## Что доставимо на текущем стеке

- Встроенная FaceTime: 1080p30 с идеальной каденцией.
- Brio: **native 4K на record-пути** (`allowAboveFullHD: true`, hold-lock через `startRunning()`,
  #265), ~26–30fps фактической каденции (CFR-нормализатор дозаполняет CFR-60→30 дублированием);
  preview / device-list путь остаётся кэпнут на ≤1080p (`allowAboveFullHD: false`, дефолт) —
  намеренно, не ограничение доставки.
- 60fps не доставим ни на одной из этих камер (см. выше).
- Выбор режима камеры — в пределах реальных лимитов (`AVCaptureDevice.formats`).

---

## Как измерять (методология)

Нельзя верить `nominalFps`, `ffprobe r_frame_rate` / `avg_frame_rate` — `CFRNormalizer` пишет
CFR-30/60 даже поверх более редкого источника. Правильные инструменты:

1. **`scripts/verify-cfr.sh`** — packet-rate (A) по реальным временны́м меткам пакетов +
   fresh-content (C, `mpdecimate`) + run-clusters (D).
2. **Сырой PTS-пробник** по `CMSampleBufferGetPresentationTimeStamp` — замер каденции захвата
   на уровне AVFoundation.

Важный caveat: fresh-content (C) требует движения в кадре. Статичная сцена даёт ложно-низкий C;
в таком случае run-clusters (D) позволяет различить реальную каденцию.

---

## API-гочи macOS (verified через apple-docs MCP)

| Символ | Статус на macOS |
|---|---|
| `AVCaptureSessionPresetInputPriority` | **Не существует на macOS** — iOS/iPadOS/Catalyst/tvOS-only |
| `exposureDuration` / `activeMaxExposureDuration` | **iOS-only** — на macOS отсутствуют; программно ограничить выдержку нельзя |
| `autoVideoFrameRateEnabled` / `isAutoVideoFrameRateEnabled` | **Не существует в AVFoundation** — фантомный символ из обучающих данных |
| `kCMVideoCodecType_JPEG` / `kCMVideoCodecType_JPEG_OpenDML` | FourCC `'jpeg'` / `'dmb1'` — UVC-MJPEG на macOS; константы `'mjpg'` в CoreMedia нет |
| `activeFormat` / `activeVideoMin/MaxFrameDuration` | Доступны, macOS 10.7+ |
| `sessionPreset = .hd4K3840x2160` | Доступен, macOS 10.15+; удерживается корректно при hold-lock через `startRunning()` (#265) |

---

## Доказательная база

- `CameraSource4KDeliveryL5Tests` — 4K-пробник, оба пути (`setActiveFormat` + `sessionPreset`);
  регрессионный тест на hold-lock (#265).
- `CameraSourceBuiltInDeliveryL5Tests` — встроенная: дамп форматов + sustained fps;
- `CameraModeRecordingL5Tests` — full-pipeline запись + `verify-cfr`;
- `DiagFrameCollector` — PTS-коллектор для сырого замера каденции;
- `scripts/verify-cfr.sh` — эталонный инструмент для packet-rate / fresh-content / run-clusters.
- `swarm-report/research/research-4k-dual-recording.md` + `swarm-report/4k-spikes-state.md` —
  спайки S1 (=T-8, live record-path 4K) и S2 (HEVC-тракт потолок) за 2026-07-02.
