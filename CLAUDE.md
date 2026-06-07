# Onset

macOS screen/camera recording app (menu bar + windows). Swift 6, strict concurrency
`complete`, default actor isolation `MainActor`, warnings-as-errors
(`Config/Strict.xcconfig` + pbxproj) — any warning fails the build.
Deployment target: macOS 26.4. Single scheme: `Onset`.

Critical product requirements, in priority order: **stability**, **performance**,
**scalable architecture**. Weigh every design decision against these three.

## Language

- Issues and documentation (`docs/`) — in Russian.
- Code identifiers, code comments, commit messages — in English.

## Commands

```bash
# Build (CI-equivalent)
xcodebuild build -scheme Onset -destination 'platform=macOS' -configuration Debug \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO | xcpretty

# Unit tests (Swift Testing)
xcodebuild test -scheme Onset -destination 'platform=macOS' -configuration Debug \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO | xcpretty

# Lint — CI "Lint" job runs BOTH; check both before push
swiftformat . --lint --config .swiftformat
swiftlint lint --strict --config .swiftlint.yml   # version pinned 0.63.3 via Mintfile
```

Artifact checks (CI `artifact-checks` job; run against the BUILT .app, not source):

- `scripts/check-entitlements.sh <Onset.app>` — entitlements are injected at signing,
  source-only checks give false results
- `scripts/check-no-network.sh` — "no network client" invariant: binary must not link
  network frameworks
- `scripts/check-privacy-manifest.sh` — PrivacyInfo.xcprivacy lint (fatal in CI;
  official Required-Reason codes for UserDefaults)
- `scripts/verify-cfr.sh screen.mp4 camera.mp4 60 30` — CFR cadence from real packet
  timestamps; ffprobe metadata (r_frame_rate/nb_frames) lies

## Testing

- Swift Testing only, zero XCTest. In xcodebuild output the XCTest banner
  "Executed 0 tests" is FALSE — the verdict is in the Swift Testing summary.
  Never use `-quiet`: it hides that summary.
- Tiers: L2 (no hardware, `Fake*` doubles) and L5 (real hardware) coexist in the
  same test files; L5 suites are opt-in via `ONSET_RUN_L5_*` env vars and
  `.enabled(if:)` traits.
- Reference hardware for L5: Logitech MX Brio
  (see `docs/quality/production-quality-bar.md`).
- Before re-running `xcodebuild test`, kill stale/orphaned test-host processes —
  hardware (camera) tests fight over the device and hang, spawning extra instances.
- Window scenes and the global hotkey are suppressed under test runs
  (see `OnsetApp.swift`) so the suite doesn't pop onboarding windows.
- OnsetUITests target exists but is not wired into the Onset scheme's Test action.

## Project structure

| Dir | Purpose | Key types |
|---|---|---|
| `Onset/OnsetApp.swift` | Entry: two fixed-size `Window` scenes + `MenuBarExtra`, hotkey ⌘⌥⌃R | `OnsetApp` |
| `Onset/Recording/Capture/` | Frame/sample acquisition into AsyncStreams | `VideoFrameSource`/`AudioSampleSource` (protocols), `CameraSource`, `ScreenSource`, `DeviceDiscovery` |
| `Onset/Recording/Pipeline/` | Session orchestration, two-file output, capability preflight | `RecordingSession`, `DualFileOutputStage`, `CapabilityProbe`/`CapabilityResolver`, `DropMonitor`, `PipelineTypes.swift` |
| `Onset/Encode/` | HW HEVC encoding + CFR normalization | `VideoEncoder`, `CFRNormalizer` (pure), `EncoderConfigBuilder`, `LiveCompressionSession` |
| `Onset/Permissions/` | TCC statuses, startup routing, relaunch | `PermissionsService`, `PermissionsProviding`, `EffectivePermissions` (pure), `AppRouter` (pure) |
| `Onset/Configuration/` | Recording policy: codec, bitrate table, budget | `RecordingConfiguration`, `RecordingPolicyTypes.swift` |
| `Onset/Storage/` | MP4 muxing, output paths and POSIX permissions | `FileWriter`, `RecordingOutput`, `FileWriterTypes.swift` |
| `Onset/UI/` | Main / Recording / Onboarding / MenuBar / HotKey surfaces | `RecordingCoordinator` (sole state owner), `MainViewModel`, `OnboardingViewModel`, `MenuBarLabelMapper` (pure), `GlobalHotKeyMonitor` |
| `OnsetTests/` | Flat Swift Testing suite, L2+L5 | `Fake*` doubles, `LiveCaptureSetup` (L5 harness) |

Fast pointers:

- Start recording → `RecordingSession.start(permissions:)`; capability preflight →
  `CapabilityProbe.probe()` → `CapabilityResolver`.
- CFR slots / catch-up → `CFRNormalizer`; host-clock conversion (`CMSyncConvertTime`)
  happens once, at ingest in `CameraSourceShims.swift`.
- Record-button enable logic → `MainViewModel.canRecord`; TCC wrappers →
  `ScreenRecordingPermission`, `CaptureDevicePermission`.

Full type-level map (Russian): `docs/architecture.md`.

## Key approaches

- **Pure logic + impure actor pairing**: branching logic lives in nonisolated pure
  types (`CFRNormalizer`, `CapabilityResolver`, `EffectivePermissions`, `AppRouter`,
  `MenuBarLabelMapper`); framework/C interop stays inside actors. New logic follows
  this split.
- **Default MainActor isolation**: value types declare explicit `nonisolated` static
  operators for `Equatable`/`Hashable` to stay usable off the main actor.
- **Single T0 epoch** (`HostTimeAnchor`) per session; all PTS are host-time offsets
  from T0, converted once at ingest.
- **One-shot lifecycle**: `start()` succeeds once, a throwing `start()` is terminal,
  `stop()` is idempotent — no restarts.
- **Single AsyncStream subscriber**: `RecordingCoordinator` is the only subscriber of
  session streams and the only `@Observable` state owner; views are readers.
- **DI seams**: factory protocols (`EncoderFactory`, `WriterFactory`, `SourceFactory`)
  plus closure seams on view models; tests use `Fake*` types with
  `AsyncStream.makeStream`.
- **Logging**: only `os.Logger(subsystem: "dev.androidbroadcast.Onset")`; never log
  PII (device display names).

## Issues & project board

- Board: <https://github.com/users/kirich1409/projects/6> (Onset Project).
  Issues auto-add via built-in workflow — no manual linkage.
- Issues are written in Russian and detailed: environment / symptoms /
  root cause `file:line` / expected behavior / design questions.
- Status flow — move the card at every stage:
  `Backlog` → `Ready` → `In progress` (work started / draft PR) →
  `In review` (PR ready) → `Done` (merged).
- On creation set: relationships (Parent issue / sub-issues, "blocked by #N"),
  `Priority` (P0–P2), `Size` (XS–XL), `Estimate`. Size + Priority drive the executing
  agent's model: XS/S → sonnet (haiku for mechanical chores), M → sonnet,
  L/XL or architectural work → opus planning + sonnet implementation;
  P0 bumps one tier up.

## Workflow

- Work autonomously: draft→ready promotion and native auto-merge
  (`gh pr merge --auto --squash`) without per-PR confirmation (personal repo).
- Merge-readiness requires verification on reference hardware (MX Brio) whenever the
  change touches recording/devices and it makes sense — build + unit tests do not
  close L5.
- Docs describe `main`: update affected `docs/` in the same PR that changes behavior.
- After completing a task, fold non-obvious learnings into CLAUDE.md
  (`/claude-md-management:revise-claude-md`).
- UI design is not done by agents: write a brief for the Claude Design service and
  hand it to the user.

## Source of truth

- Specs: `docs/specs/` (product overview, recording MVP, permissions/onboarding,
  devops/CI).
- Quality bar: `docs/quality/production-quality-bar.md`.
- Design references: `docs/design-ref/`.

## Code style

- SwiftLint opt-ins to know: `missing_docs` (docs on all declarations),
  `force_unwrapping` banned, `no_magic_numbers` (tests exempt).
- SwiftFormat owns formatting: `--maxwidth 120`, `--trailingcommas always`,
  wrap before-first.

## Documentation links

- ScreenCaptureKit — <https://developer.apple.com/documentation/screencapturekit>
- AVFoundation — <https://developer.apple.com/documentation/avfoundation>
- VideoToolbox — <https://developer.apple.com/documentation/videotoolbox>
- Swift Testing — <https://developer.apple.com/documentation/testing>
- MenuBarExtra — <https://developer.apple.com/documentation/swiftui/menubarextra>
- Privacy manifests — <https://developer.apple.com/documentation/bundleresources/privacy-manifest-files>
- Required-Reason API — <https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api>
- Swift 6 concurrency migration — <https://www.swift.org/migration/>
- SwiftLint rule directory — <https://realm.github.io/SwiftLint/rule-directory.html>
- SwiftFormat rules — <https://github.com/nicklockwood/SwiftFormat/blob/main/Rules.md>

## Gotchas

- `Config/Strict.xcconfig` (Onset target): warnings-as-errors, strict memory safety
  (`unsafe` annotations required for C interop), upcoming features ExistentialAny /
  InternalImportsByDefault / MemberImportVisibility.
- The app must never gain network-client code — spec AC enforced by
  `check-no-network.sh`.
- `swarm-report/` is gitignored orchestration state, not part of the product.
