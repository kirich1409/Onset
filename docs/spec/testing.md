---
type: spec-testing
product: Onset
date: 2026-05-29
status: approved
---

# Onset — Testing (общая стратегия + команды верификации)

Общие тестовые конвенции и инструменты. Стратегия (пирамида, автоматизация, coverage-гейт) — в [`non-functional-requirements.md`](non-functional-requirements.md) § NFR-TEST. Тест-кейсы — per-feature в `docs/<feature>/test-plan.md`. **TC-id стабильны across feature-планов** (TC-1…TC-43, без сквозного дубля).

## Уровни (кратко)
L1 статический (build/lint/typecheck) → L2 unit → L3 UI-instrumentation → L4 e2e/ui-scenario → L5 hardware-acceptance (только на референс-железе: MacBook Pro 14" M3 Max + внешний 4K60 + MX Brio). Подробности и гейты — NFR-TEST / NFR-CI.

## Appendix A — Команды верификации (для L5-TC)

Пост-анализ выходных файлов (TC-30/31/32/33/39):

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

Привязка диагностических событий (см. `architecture.md` § Инструментация) к TC:

| TC | Событие лога | Что проверять |
|---|---|---|
| TC-24 | `writer.failure` | выход, ошибка, isolate-решение |
| TC-26a/26b | `source.failure` | тип (camera-unplug), частичная финализация |
| TC-28 | `frame.dropped` | причины `captureBound`/`poolExhausted`/`encoderBound`/`diskBound` |
| TC-30 | `recording.stop` | поле `DroppedFrameStats` == 0 |
| TC-37/TC-40 | `degradation.step` | сработавший шаг + триггер; cooldown между шагами; ratchet |
| TC-8/TC-23 | `permission` | статусы Screen Recording/Camera/Microphone/Notifications |

Механизмы инъекции (для unit/integration TC-24/25/28/29): fake `EncodingWriter`, выбрасывающий ошибку на N-м буфере (TC-24/25); ограничение глубины bounded-очереди до 1 + подача быстрее write-rate (TC-28 `encoderBound`); `alwaysDiscardsLateVideoFrames=true` + перегрузка fake capture-источника (TC-28 `poolExhausted`). `DegradationLadder` выносится в чистый decider-автомат (вход: серия метрик → выход: серия шагов) для unit-теста гистерезиса без железа (TC-37).
