# Progress: Превью камеры — модель состояния, таймаут, VoiceOver

> Plan: ./plan.md · Tasks: ./tasks.md

## Status
- [ ] T-1 — CameraPreviewState enum + computed-мосты (#254)
- [ ] T-2 — Мягкий таймаут `.connectingSlow` (#255)
- [ ] T-3 — VoiceOver-анонс на переходах (#256)
- [ ] T-4 — Гейты и PR

## Learnings
- T-1: план ошибочно считал `:36` reset «поглощённым» `stopCurrentPreview→.idle` — но тот early-return'ит при `previewSource==nil`, sticky `.failed` пережил бы. Восстановлено 1:1 явным `.idle` после stopCurrentPreview + дискриминатор-тест `managePreviewNil_afterFailure_clearsFailed`.
- T-1: `.failed ⟹ previewSource==nil` (failed ставится только после нилинга source) → teardown/Record:118 `.idle` не теряет живой handle. Get-only мосты не бэкают SwiftUI Binding (нет `$preview*`).
