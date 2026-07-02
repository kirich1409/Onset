# verify-stabilization — инструменты приёмки стабилизации камеры (#297/#298)

Два офлайн-измерителя из spike #295 (эпик #294) для верификации AC-1/AC-2 спеки
`docs/specs/2026-07-02-camera-stabilization.md` на реальных записях. Не продуктовый код —
исследовательские CLI-пробы: собираются standalone, в таргеты Xcode не входят, SwiftLint их
не проверяет (каталог вне `included`).

| Инструмент | Что меряет | Роль в приёмке |
|---|---|---|
| `measure-shake.swift` | Целочисленный (1×) Vision-транслейшн по соседним парам: per-frame сдвиги, cumulative-траектория, **lock-to-ref deviation (2 s rolling mean)**, частота осцилляций, доля движущихся пар | AC-1: «0 движущихся пар» на размеченном статичном сегменте typing-записи; гейт валидности стимула |
| `translational2x.swift` | Субпиксельный измеритель `translational@2×`: тот же Vision-транслейшн на 2× апскейле (гранулярность 0.5 px в координатах 1080p) + латентность Vision | AC-1: lock-to-ref (2 s rolling) max ≤ 1 px по CSV-выходу |

## Сборка

```bash
cd tools/verify-stabilization
swiftc -O measure-shake.swift -o measure-shake
swiftc -O translational2x.swift -o translational2x
```

Никаких зависимостей кроме системных фреймворков (AVFoundation, Vision, CoreImage).

## Запуск — ОБЯЗАТЕЛЬНО unsandboxed

`AVAssetReader` из sandboxed-процесса падает с ошибками `-11800`/`-17913` (spike red flag #6).
Запускать бинарники из обычного терминала (не из sandbox-обёрток, не из Xcode-схемы с
включённым App Sandbox):

```bash
./measure-shake  "~/Movies/Onset/Onset <ts>/… камера.mp4" /tmp/shake.csv
./translational2x "~/Movies/Onset/Onset <ts>/… камера.mp4" /tmp/t2x.csv
```

Оба пишут CSV (по-кадровые ряды) и печатают сводку (перцентили, lock-to-ref, латентность).

## Методика замера (AC-1, спека)

1. **Исключение warm-up-сегмента.** Первые ~60 кадров записи (≈3 s на каденции Brio)
   нестабилизированы by design — этап меряет каденцию и рендерит с correction = 0. Метрика
   считается **с кадра 61**; точный момент завершения warm-up берётся из лога выбора
   `estScale` (`log show --predicate 'subsystem == "dev.androidbroadcast.Onset"' | grep
   "stabilization warm-up complete"`). Практически: отрезать первые ≥5 s записи
   (`ffmpeg -ss 5 -i in.mp4 -c copy trimmed.mp4`) или отбрасывать строки CSV с
   `pts < t_warmup`.
2. **Гейт валидности стимула (OFF > 2 px).** OFF-запись той же typing-сцены (back-to-back с
   ON, неизменные условия) обязана показывать lock-to-ref max > 2 px по `measure-shake` /
   `translational2x` — иначе вибрация не дошла до камеры, прогон невалиден и повторяется.
   Без этого гейта идеальная метрика ON доказывается вакуумно.
3. **Целочисленная часть AC-1** («0 движущихся пар» у `measure-shake`) считается на
   **размеченном статичном сегменте той же typing-записи** (сегмент под активным набором
   текста), не на отдельной статичной записи.
4. Порог AC-1: lock-to-ref deviation (2 s rolling mean) **max ≤ 1 px** по `translational@2×`.

## Связанные проверки

- Свежесть кадров (AC-2): `scripts/verify-cfr.sh` — для приёмочных пар ON/OFF абсолютный
  гейт C отключается (`MIN_FRESH_FPS=0`), сравнивается относительная дельта медиан
  `fresh_fps` по машинной строке `FRESH_FPS=…`.
- Методика целиком: `docs/quality/production-quality-bar.md` §4.3 и спека
  `docs/specs/2026-07-02-camera-stabilization.md` (AC-1/AC-2, Prerequisites).
