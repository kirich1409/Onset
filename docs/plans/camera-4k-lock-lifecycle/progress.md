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

## Finalize (fix-проход)
Findings панели (5/6: code-reviewer PASS, perf APPROVE): comment-rot (точка lock-capture),
invariant-doc (exclusive-lock), label-desync (checklist vs запись), test-gap High (lock-ownership не L2).
Закрыты правками комментариев/доков в 4 файлах (CameraSource+SessionSetup, CameraSource,
MainViewModel+Devices, CameraSource4KDeliveryL5Tests).

### ОТКЛОНЕНИЕ от плана: T-3 Check «L2 (через seam)» — признан НЕВЫПОЛНИМЫМ as-built
План T-3 требовал L2-покрытие lock-ownership через seam (preview/record-error-пути + 3 teardown:
нет lock-leak, нет двойного unlock). Реализация этого seam НЕ построила и не может без новой
production-DI: `buildAndStartSession` инстанцирует `AVCaptureSession()` и `AVCaptureDevice(uniqueID:)`
инлайн, `lockForConfiguration`/`unlockForConfiguration` зовутся на конкретном `AVCaptureDevice`
(не протокол), в `CameraSource.init` нет фабрики устройства. Это ТА ЖЕ безсемная поверхность, которую
проект УЖЕ задокументировал как «NOT L2-reachable» в `CameraSourceLogicTests.swift:311-314` (#203):
построение DI-seam — out of scope per minimal-diff policy; покрытие через inspection + L5.
Решение: gap принят, обоснование задокументировано в коде (CameraSource4KDeliveryL5Tests заголовок) +
здесь; lock-ownership проверяется review-чеклистом + L5 4K-delivery. Это осознанное отклонение от
ревьюнутого плана, surfaced (не зарыто в комментарий) — НЕ рутинный «просто не написали тест».

### Lint-долг (вскрыт при resume) — закрывается на ветке
`scripts/preflight.sh:29` зовёт `swiftformat . --lint --config .swiftformat` — флаг `--config` даёт
ложные `wrapAttributes` (известный quirk: CI-истина = `swiftformat --lint .` без `--config`). Preflight
падает на стадии 1/4 на ложных и НЕ доходит до swiftlint → ветка закоммичена lint-dirty. CI-точная
проверка вскрыла РЕАЛЬНЫЕ нарушения (a40c06c/b17c02c): swiftformat 2 (wrapMultilineStatementBraces,
blankLinesBetweenScopes — автоисправлены), swiftlint 3 (function_body_length buildAndStartSession 50>40,
function_parameter_count makeShims 6>5, opening_brace L5-тест). Чинятся отдельным fix-проходом.
ОТДЕЛЬНО (вне #265): preflight.sh `--config` — реальный баг тулинга, маскирует ошибки → чинить
отдельным chore (meta-change, нужен owner-review).
