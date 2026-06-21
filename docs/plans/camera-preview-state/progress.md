# Progress: Превью камеры — модель состояния, таймаут, VoiceOver

> Plan: ./plan.md · Tasks: ./tasks.md

## Status
- [x] T-1 — CameraPreviewState enum + computed-мосты (#254) ✅ commit 8f82ead; L0+L2 green (55 MainViewModel tests pass, 1:1)
- [x] T-2 — Мягкий таймаут `.connectingSlow` (#255) ✅ L0+L2 green (10 deterministic timeout tests + camera suites)
- [ ] T-3 — VoiceOver-анонс на переходах (#256)
- [ ] T-4 — Гейты и PR

## Learnings
- T-1: план ошибочно считал `:36` reset «поглощённым» `stopCurrentPreview→.idle` — но тот early-return'ит при `previewSource==nil`, sticky `.failed` пережил бы. Восстановлено 1:1 явным `.idle` после stopCurrentPreview + дискриминатор-тест `managePreviewNil_afterFailure_clearsFailed`.
- T-1: `.failed ⟹ previewSource==nil` (failed ставится только после нилинга source) → teardown/Record:118 `.idle` не теряет живой handle. Get-only мосты не бэкают SwiftUI Binding (нет `$preview*`).
- T-2: добавлен 2-й DI-seam `startPreviewSource` (помимо `connectSleep`) — `connectSleep` контролирует только watchdog-половину гонки, для детерминированных `.live`-путей нужно управлять приходом хендла. Паттерн проекта (closure seams). 10 тестов.
- T-2: в nonisolated `@Sendable`-замыкании `source.sessionHandle()` (actor-sync) НЕ требует `await` (region-based isolation) — в отличие от `@MainActor`-метода buildAndStartPreview, где `await` нужен. Компилятор — ground truth.
