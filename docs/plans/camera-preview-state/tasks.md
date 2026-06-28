# Tasks: Превью камеры — модель состояния, таймаут, VoiceOver

> Plan: ./plan.md · Источник истины: issue #254/#255/#256 (spec нет). #254 baseline = существующие зелёные тесты (ассерты неизменны).

## T-1 — CameraPreviewState enum + полная миграция write-sites (#254)
- after: none
- files: `Onset/UI/Main/CameraPreviewState.swift` (new), `Onset/UI/Main/MainViewModel.swift`, `Onset/UI/Main/MainViewModel+Preview.swift`, `Onset/UI/Main/MainViewModel+Record.swift`, `OnsetTests/MainViewModelCameraToggleTests.swift`, `OnsetTests/MainViewModelTests.swift`, `docs/architecture.md`
- acceptance:
  - THE SYSTEM SHALL хранить состояние в одном `previewState: CameraPreviewState`; `previewHandle`/`previewFailed` — get-only мосты через `if case`; enum НЕ Equatable.
  - THE SYSTEM SHALL мигрировать ВСЕ 9 write-sites по таблице плана (вкл. `+Record.swift:118`→`.idle`); `.connecting` ставится ПОСЛЕ guard'ов cameraID/camera; hot-unplug(:49)/build-nil(:55)→`.failed`; teardown(:66)/stop(:77)/Record:118→`.idle`; success(:112)→`.live`.
  - GIVEN рефактор завершён WHEN гоняются `MainViewModelCameraConnectingTests` и `cameraPlaceholderPending_trueForBothConnectingAndFailed` THEN их АССЕРТЫ проходят без изменений (proof 1:1); setup трёх тестов (`CameraToggleTests:653,663`, `MainViewModelTests:290`) переписан на `previewState`.
- check: repo-wide `grep -nE '\bpreview(Handle|Failed)\s*=' Onset/ OnsetTests/` (исключая мосты) → 0 присваиваний; сборка warnings-as-errors зелёная; `-only-testing:OnsetTests/MainViewModelCameraConnectingTests` зелёный; новый тест `previewState_bridges` (live→handle, failed→true, idle/connecting→nil/false, connectingSlow→previewIsConnectingSlow).   (закрывает #254)
- note: три get-only моста — `previewHandle`/`previewFailed`/`previewIsConnectingSlow` (третий нужен вью для #255).

## T-2 — Мягкий таймаут `.connectingSlow` + identity-gated structured watchdog (#255)
- after: T-1
- files: `Onset/UI/Main/CameraPreviewState.swift`, `Onset/UI/Main/MainViewModel.swift`, `Onset/UI/Main/MainViewModel+Preview.swift`, `Onset/UI/Main/MainView+Sections.swift`, `OnsetTests/MainViewModelTests.swift`
- acceptance:
  - GIVEN превью в `.connecting` WHEN истекает инъектированный порог и хендла нет THEN `.connectingSlow`; соединение НЕ отменяется; спиннер сохраняется; copy несёт recovery-guidance.
  - THE SYSTEM SHALL ввести `previewAttempt: Int`, бампать ровно раз на входе попытки (после guard'ов, перед `.connecting`); гейтить flip в `.connectingSlow` через `attempt == previewAttempt` + `if case .connecting`; гейтить `.failed`(build-nil) через `attempt == previewAttempt`; гейтить `.live` через `previewSource === source` И `attempt == previewAttempt`. НЕ переиспользовать `previewGeneration`.
  - THE SYSTEM SHALL соблюсти code-инварианты: между `previewAttempt += 1` и захватом `let attempt` — нет `await`; `previewSource = source` присваивается до `await source.start()`; `threshold` вычисляется ДО `withTaskGroup` (не захватывать `camera` в `@Sendable addTask`).
  - THE SYSTEM SHALL объявить `connectSleep: @Sendable (Duration) async throws -> Void` как init-параметр (default `{ try await Task.sleep(for: $0) }`) и `connectTimeout(isContinuity:) -> Duration` (именованные константы); вью различает slow через мост `previewIsConnectingSlow`, `cameraPlaceholderLabel` получает 3-ю ветку.
  - THE SYSTEM SHALL привязать watchdog структурно (`withTaskGroup`, дефолт; `async let` — только если compile-spike не даёт unused-warning под warnings-as-errors).
  - GIVEN watchdog камеры A активен WHEN стартует подключение камеры B (через реальный `.task(id:)` ре-энтри / device-switch) THEN устаревший watchdog A НЕ меняет состояние B.
  - GIVEN suspended `start()` камеры A резюмится ПОСЛЕ установки `previewSource = sourceB` THEN `.live(A)` НЕ перетирает состояние B (identity-гейт).
  - GIVEN `.connectingSlow` WHEN поздний хендл приходит THEN `.live` (late-handle промотируется).
  - THE SYSTEM SHALL держать `cameraPlaceholderPending`/`isCameraConnecting` true в `.connectingSlow`; порог по типу устройства (Continuity > встроенная), именованные константы.
- check (детерминированно, через `sleep`-seam, без реального `Task.sleep`): `connecting_pastThreshold_becomesConnectingSlow`; `buildFast_noSlow`; `failedBeforeThreshold_noSlow`; `liveBeforeThreshold_noSlow`; `connectingSlow_lateHandle_becomesLive`; `staleWatchdog_afterDeviceSwitch_doesNotMutate` (реальный A→B путь, НЕ ручной `previewAttempt++`; seam упорядочен так, что sleep watchdog'а A ЗАВЕРШАЕТСЯ до старта B — иначе тест проходит через структурную отмену, а не attempt-гейт); `suspendedStartA_afterSwitchToB_doesNotClobberLive` (identity+attempt гейт); `connectingSlow_keepsPlaceholderAndConnecting`; сборка зелёная. L5 (живой slow-Continuity) — best-effort на целевом Mac.   (закрывает #255)

## T-3 — VoiceOver: политика постинга + текст + disconnect-анонс + снятие `.updatesFrequently` (#256)
- after: T-1   (учитывает `.connectingSlow` из T-2, если влит)
- files: `Onset/UI/Main/CameraPreviewState.swift`, `Onset/UI/Main/MainViewModel+Preview.swift`, `Onset/UI/Main/MainViewModel+Devices.swift`, `Onset/UI/Main/MainView+Sections.swift`, `OnsetTests/MainViewModelTests.swift`
- acceptance:
  - THE SYSTEM SHALL извлечь логику подписи в общий nonisolated helper (state+isContinuity+disconnectedName→String); `cameraPlaceholderLabel` и `previewAnnouncement` читают его (единый источник, не дубль строк).
  - THE SYSTEM SHALL иметь чистую `previewAnnouncement(from:to:isContinuity:) -> PreviewAnnouncement?`: `→.connecting`→nil; `→.connectingSlow`→статус+guidance (normal); `→.live`→«Камера подключена» (normal); `→.failed`→label (high-priority); `→.idle`→nil.
  - THE SYSTEM SHALL постить анонс disconnect live-камеры (high-priority) явным вызовом в `case .disconnected` (`+Devices.swift:145-148`), НЕ через `didSet`; гейт `hasObservedPresentCamera == true` (session-live, не initial-load); сайты :156/:289/:309 не анонсят.
  - THE SYSTEM SHALL вызывать `AccessibilityNotification.Announcement(text).post()` на call-sites переходов только при non-nil; high-priority → fallback `NSAccessibility.post` если SwiftUI не экспонирует приоритет (API-verify).
  - THE SYSTEM SHALL убрать `.accessibilityAddTraits(.updatesFrequently)` (`MainView+Sections.swift:179`), сохранив `.accessibilityLabel`.
  - THE SYSTEM SHALL НЕ добавлять имя устройства в `os.Logger` (текст анонса = видимый label, user-facing UI).
- check: табличный `previewAnnouncement_policy` (матрица from×to×isContinuity → text/priority/nil, вкл. `connecting→live`→единичный анонс, `connecting`→nil); тесты `disconnect_sessionLive_announces` и `initialLoadWithAbsentSavedCamera_doesNotAnnounce`; сборка зелёная; grep `.updatesFrequently` в MainView+Sections → 0. L5 manual на целевом Mac: живой VoiceOver-анонс + критерий «`.failed`/disconnect прерывает висящий `.connectingSlow`-анонс» (interrupt-семантика).   (закрывает #256)

## T-4 — Гейты и PR
- after: T-1, T-2, T-3
- files: —
- acceptance: THE SYSTEM SHALL пройти `scripts/preflight.sh` (lint+privacy+build+unit); docs/architecture.md обновлён; PR `feature/camera-preview-state` открыт, body «Closes #254, #255, #256» + перечень оставшихся L5-гейтов (живой Continuity slow-timeout, VoiceOver-анонсы/приоритет) и где они гоняются.
- check: `scripts/preflight.sh` exit 0 (целевой Mac); `swiftformat --lint .` и `swiftlint lint --strict` чисто; PR создан; доска: #254/#255/#256 → In review.
