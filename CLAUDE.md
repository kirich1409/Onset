# Onset

macOS screen/camera recording app (menu bar + windows). Swift 6, strict concurrency
`complete`, default actor isolation `MainActor`, warnings-as-errors
(`Config/Strict.xcconfig` + pbxproj) — any warning fails the build.
macOS 26+ only (deployment target 26.4, Apple Silicon): use current APIs freely,
never add availability checks or fallbacks for older macOS. Single scheme: `Onset`.

Critical product requirements, in priority order: **stability**, **performance**,
**scalable architecture**. Weigh every design decision against these three.

**Runtime is loaded, not idle**: real usage is screen+camera recording while the
user drives other apps (browser, IDE, editor, AI tooling) — CPU/GPU/VideoToolbox
are already contended before recording starts. Design and verify perf under
representative concurrent load, never a quiet machine (camera stabilization's
designed bypass was only found to fire at ~23s under normal load because
viability had been judged idle). Full render/export-level saturation is out of
scope for perf verdicts.

## Autonomy

The app is developed entirely by agents (overview spec, principle 15): own the
full cycle — analysis → design → implementation → local verification →
merge-ready PR. Never pause mid-task to ask "should I continue?".

- Interrupt the user ONLY for what an agent physically cannot do: Apple Developer /
  App Store Connect credentials, one-time TCC grants, physical hardware access.
  Launching the app, clicking through its UI, taking screenshots — do yourself.
- UI verification loop, no human: build → launch .app → drive it (Peekaboo CLI if
  installed, else `osascript` + System Events) → `screencapture` → compare against
  expectation → fix → repeat. Screen Recording/Accessibility TCC are pre-granted to
  the agent host; on a TCC error stop and report — never run `tccutil` to self-heal.
- Merge-ready = local gates green: `scripts/preflight.sh` (mirrors CI pr-gate) +
  docs updated in the same PR + L5 on reference hardware (MX Brio) when the change
  touches recording/devices — build + unit alone do not close L5.
- The cycle usually closes only on the target Mac. Cloud Claude sessions have no
  macOS toolchain, screen, or camera and cannot run `preflight.sh`, the UI loop, or L5
  locally. GitHub CI, though, runs the pr-gate (build + unit + lint + artifact-checks)
  on macOS runners — a green CI is real macOS verification of those gates; it only
  lacks screen/camera for L5 and the UI loop. Merge from cloud when CI is green and no
  remaining gate needs real hardware (L5) or a human-driven UI check — this covers
  docs/CI-config, build/unit/lint-only, and similar changes. When L5 or the UI loop
  remains, open the PR, state in its body which gates remain and where they run, and
  leave it unmerged and the issue out of Done until a session on the target hardware
  verifies.
- When gates pass: mark PR ready + `gh pr merge --auto --squash`, no per-PR confirmation (personal repo).
  EXCEPTION — meta changes that shape agent behavior and the owner's expectations/costs (CLAUDE.md, `.claude/`,
  `.github/workflows/`, lint/build configs, `docs/specs/`) are NEVER auto-merged: open the PR, explicitly call
  the owner to review, merge only after approval. Evidence over assertions in the PR body: Swift Testing
  summary, lint result, screenshot for UI changes.

## Language

- Issues and documentation (`docs/`) — in Russian.
- Code identifiers, code comments, commit messages — in English.

## Commands

```bash
# Pre-push gate (lint + privacy manifest + build + unit, mirrors CI pr-gate)
scripts/preflight.sh

# Build (pipe to xcbeautify if installed — token-cheap output; plain otherwise)
xcodebuild build -scheme Onset -destination 'platform=macOS' -configuration Debug \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO

# Unit tests (Swift Testing, L2 only — L5 env-gated, see Testing; CODE_SIGNING_ALLOWED=NO fine here, never L5)
xcodebuild test -scheme Onset -destination 'platform=macOS' -configuration Debug \
  ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO

# Lint — CI "Lint" job runs BOTH; check both before push
swiftformat --lint .  # CI-exact; do NOT add --config (changes rule resolution → false wrapAttributes errors)
swiftlint lint --strict --config .swiftlint.yml   # version pinned 0.63.3 via Mintfile
```

Artifact checks (CI `artifact-checks` job):

- `scripts/check-privacy-manifest.sh` — works on SOURCE, no build needed (fast
  pre-check; fatal in CI: official Required-Reason codes for UserDefaults).
- `scripts/check-entitlements.sh <Onset.app>` and `scripts/check-no-network.sh <Onset.app>` — need the BUILT
  .app: entitlements are injected at signing; no-network invariant = binary must not link network frameworks.
- `scripts/verify-cfr.sh screen.mp4 camera.mp4 60 30` — CFR cadence from real packet timestamps (ffprobe
  metadata lies). Slow: ~1 min per 10 min of video; the fresh-content check needs MOTION in frame — a static scene fails falsely.

## Testing

- Swift Testing only, zero XCTest. The XCTest "Executed 0 tests" banner is FALSE —
  the verdict is the Swift Testing summary line; never use `-quiet` (hides it).
- L5 (real hardware) suites are env-gated: `ONSET_RUN_L5_CAPTURE=1` (CameraSource, RecordingSession),
  `ONSET_RUN_L5_ENCODE=1` (VideoEncoder, FileWriter); `xcodebuild test -testPlan Onset-L5` sets both.
  `-only-testing` matches suites, not functions. See `docs/quality/production-quality-bar.md` §4.3.
- L5 requires a SIGNED build — drop `CODE_SIGNING_ALLOWED=NO` for build-for-testing; an unsigned test host
  writes a sticky TCC deny for screen capture (recovery: `tccutil reset ScreenCapture` + manual re-grant).
- BEFORE any L5 run: `pgrep -la Onset`. `pkill -9 Onset` (exactly this name, never broader) is fine for a stale
  or hung host — no live lock held, a dead lock PID, or the owner's OK — but never kill a live run (another
  session's test or the owner's app). One `xcodebuild test` at a time — hardware tests fight over the camera and hang.
- **Shared target Mac** — concurrent agent sessions and the owner share one machine's camera/screen. Before any
  hardware or `.app` grab (L5, the UI loop, launching `.app`, `screencapture`) take an atomic lock: `mkdir
  /tmp/onset-hw.lock` (write your PID inside), `rmdir` when done. The lock is no panacea — a crashed session
  leaves it stale — so reclaim it when the holder PID is dead; when a live holder exists, wait or defer, don't barge in.
- Reference hardware for L5: Logitech MX Brio (`docs/quality/production-quality-bar.md`).
- Perf L5 must include a representative-load scenario (other apps active), not only a quiet machine — see the runtime-is-loaded principle above.
- Recordings land in session subfolders `Onset <timestamp>/` inside the user-selected base directory (default `~/Movies/Onset/`) — L5 outputs for verify-cfr/ffprobe live there.
- Test-writing conventions (fakes, naming, suites): `OnsetTests/CLAUDE.md`.
- Coverage on by default in `Onset.xctestplan` (target `Onset`, not test bundle); L5 plan gathers none. Inspect via `-resultBundlePath` + `scripts/coverage-summary.sh` (CI posts to job summary). Report-only — gate via `ONSET_COVERAGE_MIN` (off).

## Project structure

| Dir | Purpose | Key types |
|---|---|---|
| `Onset/OnsetApp.swift` | Entry: two fixed-size `Window` scenes + `MenuBarExtra`, hotkey ⌘⌥⌃R | `OnsetApp` |
| `Onset/Recording/Capture/` | Frame/sample acquisition into AsyncStreams | `VideoFrameSource`/`AudioSampleSource` (protocols), `CameraSource`, `ScreenSource`, `DeviceDiscovery`, `DeviceAvailabilityObserver` |
| `Onset/Recording/Pipeline/` | Session orchestration, two-file output, capability preflight | `RecordingSession`, `DualFileOutputStage`, `CapabilityProbe`/`CapabilityResolver`, `DropMonitor`, `PipelineTypes.swift` |
| `Onset/Encode/` | HW HEVC encoding + CFR normalization | `VideoEncoder`, `CFRNormalizer` (pure), `EncoderConfigBuilder`, `LiveCompressionSession` |
| `Onset/Permissions/` | TCC statuses, startup routing, relaunch | `PermissionsService`, `PermissionsProviding`, `EffectivePermissions` (pure), `AppRouter` (pure) |
| `Onset/Configuration/` | Recording policy: codec, bitrate table, budget | `RecordingConfiguration`, `RecordingPolicyTypes.swift` |
| `Onset/Storage/` | MP4 muxing, output paths and POSIX permissions | `FileWriter`, `RecordingOutput`, `FileWriterTypes.swift` |
| `Onset/UI/` | Main / Recording / Onboarding / MenuBar / HotKey surfaces | `RecordingCoordinator` (sole state owner), `MainViewModel`, `OnboardingViewModel`, `MenuBarLabelMapper` (pure), `GlobalHotKeyMonitor` |
| `OnsetTests/` | Flat Swift Testing suite, L2+L5 | `Fake*` doubles, `LiveCaptureSetup` (L5 harness) |

Fast pointers:

- Start recording → `RecordingSession.start(permissions:)`; capability preflight → `CapabilityProbe.probe()` → `CapabilityResolver`.
- CFR slots / catch-up → `CFRNormalizer`; host-clock conversion (`CMSyncConvertTime`) happens once, at ingest in `CameraSourceShims.swift`.
- Record-button enable logic → `MainViewModel.canRecord`; TCC wrappers → `ScreenRecordingPermission`, `CaptureDevicePermission`.

Full type-level map (Russian): `docs/architecture.md`.

## Key approaches

- **Pure logic + impure actor pairing**: branching logic lives in nonisolated pure types (`CFRNormalizer`,
  `CapabilityResolver`, `EffectivePermissions`, `AppRouter`, `MenuBarLabelMapper`); framework/C interop stays
  inside actors. New logic follows this split.
- **Default MainActor isolation**: value types declare `Equatable`/`Hashable` on the `nonisolated` type decl
  itself. Structs suffice — the compiler synthesizes nonisolated witnesses. Enums don't: `InferIsolatedConformances`
  infers the synthesized conformance as `@MainActor` even on a `nonisolated` decl, so an enum needs an explicit
  `nonisolated static func ==` witness to be usable off the main actor.
- **Single T0 epoch** (`HostTimeAnchor`) per session; all PTS are host-time offsets
  from T0, converted once at ingest.
- **One-shot lifecycle**: `start()` succeeds once, a throwing `start()` is terminal,
  `stop()` is idempotent — no restarts.
- **Single AsyncStream subscriber**: `RecordingCoordinator` is the only subscriber of
  session streams and the sole *session-lifecycle* state owner; `AppSettings` owns settings.
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
  `Priority` (P0–P2), `Size` (XS–XL), `Estimate`. Size + Priority drive the agent's
  model: XS/S/M → sonnet (haiku for mechanical chores), L/XL or architectural work →
  opus planning + sonnet implementation; P0 bumps one tier up.

## Source of truth

- Specs: `docs/specs/`. Quality bar: `docs/quality/production-quality-bar.md`.
- Design references: `docs/design-ref/`.
- Framework/tool doc links: `docs/architecture.md`, раздел «Ссылки на документацию».

## Code style

- SwiftLint opt-ins to know: `missing_docs` (docs on all declarations),
  `force_unwrapping` banned, `no_magic_numbers` (tests exempt).
- SwiftFormat owns formatting: `--maxwidth 120`, `--trailingcommas always`,
  wrap before-first.

## Workflow

- Docs describe `main`: update affected `docs/` in the same PR that changes behavior.
- **Verify the Apple API against Apple docs before coding it.** Framework behavior
  drifts across macOS versions and differs from iOS — training data misleads; a search
  may surface an identically-named symbol that behaves differently on macOS. Check the
  symbol's actual macOS semantics via the `apple-docs` MCP (primary), macOS SDK headers,
  or developer.apple.com; trust the doc/MCP platform line over a hand-read header.
- Fold non-obvious learnings into CLAUDE.md via `/claude-md-management:revise-claude-md`; add AND delete, keep ≤200 lines.
- **UI: standard components, no agent visual design.** Build from stock SwiftUI/AppKit
  (`Settings`, `Form`, `TabView`, `Toggle`, `LabeledContent`…), no hand-rolled controls to match a mockup;
  brief visual *design* to the Claude Design service (<https://claude.ai/design/p/975364e4-479d-49bb-87a1-202a02c7b5c0>), hand to user.

## Gotchas

- `Config/Strict.xcconfig` (Onset target): warnings-as-errors, strict memory safety (`unsafe` annotations
  required for C interop), upcoming features ExistentialAny / InternalImportsByDefault / MemberImportVisibility.
- The app must never gain network-client code — spec AC enforced by `check-no-network.sh`.
- CI job timeouts (hang detection): build 20 min, unit 20 min, lint 10 min, privacy-manifest
  5 min, artifact-checks 10 min, CodeQL 60 min — anything running longer is stuck, not slow.
- `AVCaptureDevice.authorizationStatus` is cached in-process (macOS 26.x): a TCC revoke is visible only after app restart. Platform behavior, NOT a bug — don't investigate it as one.
- Not product code, never analyze: `com/` (JVM artifact of Claude tooling), `.codex/`
  (Xcode MCP bridge config), `swarm-report/` (gitignored orchestration state).
