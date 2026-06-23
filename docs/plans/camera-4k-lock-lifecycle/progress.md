# Progress: camera-4k-lock-lifecycle

Issue #265. Status: review CONDITIONAL (cycle 2) → improvements applied → red-team pass.

## Tasks
- [x] T-1 — Поднять resolve+lock устройства в buildAndStartSession
- [x] T-2 — Убрать lock/unlock из activateFormat
- [x] T-3 — Удержать device-lock до stop() (только record); teardown снимает; preview моментальный unlock
- [x] T-4 — Cap-lift через параметр allowAboveFullHD (opt-in record)
- [x] T-5 — Подтвердить preview/devices не уходят в 4K (verify, 0 правок)
- [x] T-6 — CapabilityResolver budget cross-effect (4K-камера vs экран)
- [x] T-7 — Encode: bitrate под 4K (verify, уже есть 4K-ключи)
- [~] T-8 — L5: тест доставки 4K СОЗДАН (capability-based выбор 4K-камеры, env-gated, skip без неё);
      ФАКТИЧЕСКИЙ ПРОГОН на Brio — PENDING (камера отключена пользователем; запустить при возврате,
      прямой USB3, `ONSET_RUN_L5_CAPTURE=1 -only-testing:OnsetTests/CameraSource4KDeliveryL5Tests`).
      Эмпирическое доказательство фикса уже есть: repro-спайк capture_repro.swift — 108/108 4K-буферов.

## Learnings
- T-1..T-3: device в `CameraCaptureShims` (не 3-й tuple-член → large_tuple); struct сделан `nonisolated`
  (иначе non-Sendable lockedDevice не читается из actor `CameraSource` в releaseRunning). Единый флаг
  `locked`, releaseRunning() в 3 teardown. BUILD SUCCEEDED (commit a40c06c).
