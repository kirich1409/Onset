# Ограничения захвата камеры через AVFoundation на macOS

**Статус:** Verified L5 на реальном железе 2026-06-09 (MX Brio + встроенная FaceTime MacBook).  
**Источник:** #113 (закрыта — полный разбор стека), задачи на обход — #177 (4K), #178 (60fps).

---

## TL;DR

| Камера | Заявлено / железо | Реально через AVFoundation на macOS |
|---|---|---|
| MX Brio (внешняя UVC) | 4K30 + 1080p60 | макс. 1080p; каденция ~20fps; 4K реверсится в 1080p; 60fps недостижим |
| Встроенная FaceTime (Apple ISP) | 1080p30 | 1080p30 чисто (идеальная каденция) |
| **Итог** | — | **4K и 60fps недостижимы через AVFoundation на macOS ни на одной из этих камер** |

---

## 4K недоступен

`device.activeFormat`, выставленный на 3840×2160, после старта сессии реверсируется в 1080p
(`readBack=1080p`) — и через `setActiveFormat`, и через `session.sessionPreset = .hd4K3840x2160`
(`canSetSessionPreset` возвращает `true`, но формат всё равно опускается до 1080p).

`AVCaptureSession` реконсилит формат вниз на macOS.  
На iOS существует escape: `AVCaptureSessionPresetInputPriority` позволяет зафиксировать формат
устройства и не даёт сессии переопределить его. **На macOS этот пресет отсутствует** —
он iOS/iPadOS/Catalyst/tvOS-only; попытка использовать его на macOS завершается ошибкой.

MJPEG-вариант 4K не появляется в `AVCaptureDevice.formats`: macOS CoreMediaIO (CMIO/DAL)
декомпрессирует UVC-MJPEG ниже уровня AVFoundation и отдаёт наверх только несжатый `420v`.
Прямо задать MJPEG-формат через AVFoundation API невозможно.

**Bandwidth — не причина.** `420v` 4K30 ≈ 3.0 Gbps вписывается в USB 3.2 Gen 1 (~3.2 Gbps
практических). USB 3 у Brio подтверждён через `ioreg` (`UsbLinkSpeed=5 Gbps`). Прежнее
предположение «4K не лезет в USB» опровергнуто.

---

## 60fps недостижим

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

Корень ~20fps у Brio не установлен окончательно, но воспроизводится стабильно и не зависит
от освещения и шины USB.

---

## Корневая причина (стек)

macOS CMIO отдаёт UVC-поток несжатым и реконсилит форматы под активный пресет сессии,
не выставляя сжатые (MJPEG) и высокочастотные / 4K режимы, которые камера умеет
на уровне UVC-дескриптора. На Windows/DirectShow эти режимы выбираются явно как MJPEG.

AVFoundation на macOS — слой, который достичь этих цифр не может. Это ограничение
стека захвата, не железа.

---

## Что доставимо на текущем стеке

- Встроенная FaceTime: 1080p30 с идеальной каденцией.
- Brio: 1080p, каденция ~20fps; `CFRNormalizer` нормализует выход в CFR-60 дублированием.
- Выбор режима камеры — в пределах реальных лимитов (`AVCaptureDevice.formats`).

---

## Путь к заявленным цифрам

Единственный путь — смена слоя захвата на прямой CMIO/IOKit-доступ к UVC:

- `kCMIOStreamPropertyFormatDescriptions` (CMIO/DAL) или IOKit USB — прямой выбор UVC-режимов;
- real-time MJPEG-декод в приложении;
- дополнительные entitlements (USB, camera).

Это отдельный крупный проект. Трекинг: **#177** (4K), **#178** (60fps).

---

## Как измерять (методология)

Нельзя верить `nominalFps`, `ffprobe r_frame_rate` / `avg_frame_rate` — `CFRNormalizer` пишет
CFR-60 даже поверх ~20fps-источника. Правильные инструменты:

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
| `AVCaptureSessionPresetInputPriority` | **Не существует на macOS** — iOS/iPadOS/Catalyst/tvOS-only; из-за этого `setActiveFormat` реверсируется пресетом |
| `exposureDuration` / `activeMaxExposureDuration` | **iOS-only** — на macOS отсутствуют; программно ограничить выдержку нельзя |
| `autoVideoFrameRateEnabled` / `isAutoVideoFrameRateEnabled` | **Не существует в AVFoundation** — фантомный символ из обучающих данных |
| `kCMVideoCodecType_JPEG` / `kCMVideoCodecType_JPEG_OpenDML` | FourCC `'jpeg'` / `'dmb1'` — UVC-MJPEG на macOS; константы `'mjpg'` в CoreMedia нет |
| `activeFormat` / `activeVideoMin/MaxFrameDuration` | Доступны, macOS 10.7+ |
| `sessionPreset = .hd4K3840x2160` | Доступен, macOS 10.15+; `canSetSessionPreset` возвращает `true`, но формат реконсилится вниз (см. выше) |

---

## Доказательная база

L5-suite в ветке `feature/camera-resolution-modes`:

- `CameraSource4KDeliveryL5Tests` — 4K-пробник, оба пути (`setActiveFormat` + `sessionPreset`);
- `CameraSourceBuiltInDeliveryL5Tests` — встроенная: дамп форматов + sustained fps;
- `CameraModeRecordingL5Tests` — full-pipeline запись + `verify-cfr`;
- `DiagFrameCollector` — PTS-коллектор для сырого замера каденции;
- `scripts/verify-cfr.sh` — эталонный инструмент для packet-rate / fresh-content / run-clusters.
