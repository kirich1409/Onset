# OnsetTests — test conventions

Swift Testing (`@Suite`/`@Test`/`#expect`), flat file layout, zero XCTest. L2 (no
hardware, fakes) and L5 (real hardware) coexist in the same files; L5 suites carry
`.enabled(if:)` / explicit `ProcessInfo` gates on `ONSET_RUN_L5_*` env vars and
`.timeLimit` of 1–2 minutes. Running L5 safely (stale hosts, one run at a time) is
covered in the root `CLAUDE.md` § Testing.

- Each `@Test` in a `@Suite` struct gets a fresh instance — per-test isolation comes
  free; don't add manual shared setup/teardown state.
- Naming: prose statements — `start_transitionsToRecording`,
  `elapsedAfterStop_isFrozen`, `frameBefore_T0_isDropped`.
- Doubles: `Fake*` types (`FakePermissionsService`, `FakeEncoder`, `FakeWriter`,
  `FakeRecordingControlling`) driven by `AsyncStream.makeStream` hooks for
  deterministic async; `LiveCaptureSetup` is the L5 harness with a real
  `AVCaptureSession`.
- Cross-isolation mutable state in tests: `FlagBox` (`OSAllocatedUnfairLock`) and
  `Counter` (`@unchecked Sendable`) — never raw vars shared across actors.
- Polling assertions: `eventuallyMain` helper (deadline timeout) in
  `RecordingCoordinatorTests.swift`.
- App windows and the global hotkey are suppressed when running under tests
  (see `OnsetApp.swift`) — the suite must not pop onboarding windows; keep new
  app-level surfaces behind the same guard.
- Persistence: never call `UserDefaults(suiteName:)` directly in a test. Use
  `withScopedDefaults { defaults in … }` (`ScopedDefaults.swift`) — it vends an
  `InMemoryUserDefaults` instance backed by a plain dictionary; cfprefsd is never
  involved so no `.plist` file is written to `~/Library/Preferences/` (issue #110).
  Violating this leaves one plist per test invocation on the developer's machine.
  For a fresh isolated instance without a closure, construct `InMemoryUserDefaults()`
  directly (parameterless — no force-unwrap needed).
- `MainViewModel` makeSUT pattern (issue #227): one per-SUT `InMemoryUserDefaults`
  feeds BOTH stores — `makeStore:` (device selection) AND `makeOutputFolderStore:`
  (output folder). `MainViewModel.init` constructs the output-folder store EAGERLY,
  so every SUT must inject it. A `defaults: InMemoryUserDefaults = InMemoryUserDefaults()`
  makeSUT param gives fresh isolation by default; callers needing a persistence
  round-trip pass an explicit instance. Both stores share that one instance.
- Fail-fast guard: `UserDefaultsDeviceSelectionStore`/`UserDefaultsOutputFolderStore`
  bound to `UserDefaults.standard` under a test run now trap via `assertionFailure`
  (`isRunningUnderXCTest` in `TestRunDetection.swift`). A test that forgets to inject
  an isolated store crashes instead of silently polluting `.standard` — inject an
  `InMemoryUserDefaults` to fix.
- SwiftLint: test files commonly carry `no_magic_numbers` / `file_length` exemptions
  for fixtures and synthetic data (CMSampleBuffer factories) — keep exemptions
  file-scoped, don't relax global config.
