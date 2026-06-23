# Progress: camera-4k-lock-lifecycle

Issue #265. Status: review CONDITIONAL (cycle 2) → improvements applied → red-team pass.

## Tasks
- [ ] T-1 — Поднять resolve+lock устройства в buildAndStartSession
- [ ] T-2 — Убрать lock/unlock из activateFormat
- [ ] T-3 — Удержать device-lock до stop() (только record); teardown снимает; preview моментальный unlock
- [ ] T-4 — Cap-lift через параметр allowAboveFullHD (opt-in record)
- [ ] T-5 — Подтвердить preview/devices не уходят в 4K
- [ ] T-6 — CapabilityResolver budget cross-effect (4K-камера vs экран)
- [ ] T-7 — Encode: bitrate под 4K
- [ ] T-8 — L5 (БЛОКЕР): создать тест доставки 4K + проверить на Brio

## Learnings
(append one line per completed task)
