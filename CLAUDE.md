# Onset

macOS screen/camera recording app (menu bar + windows). Swift 6, strict concurrency
`complete`, warnings-as-errors (`Config/Strict.xcconfig`) — any warning fails the build.
Deployment target: macOS 26.4. Single scheme: `Onset`.

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

## Testing gotchas

- Swift Testing only, zero XCTest. In xcodebuild output the XCTest banner
  "Executed 0 tests" is FALSE — the verdict is in the Swift Testing summary.
  Never use `-quiet`: it hides that summary.
- Before re-running `xcodebuild test`, kill stale/orphaned test-host processes —
  hardware (camera) tests fight over the device and hang, spawning extra instances.
- Window scenes and the global hotkey are suppressed under test runs
  (see `OnsetApp.swift`) so the suite doesn't pop onboarding windows.
- L5/hardware tests are opt-in; OnsetUITests target exists but is not wired into
  the Onset scheme's Test action.

## Architecture

- Entry: `Onset/OnsetApp.swift` — two fixed-size `Window` scenes (onboarding,
  recording) + `MenuBarExtra`; global hotkey ⌘⌥⌃R.
- Layers: `Recording/` (Capture, Pipeline), `Encode/`, `Permissions/` (TCC),
  `Storage/`, `UI/` (Main, MenuBar, Onboarding, Recording, HotKey), `Configuration/`.
- MVVM + actors; pattern: pure-logic type paired with an impure actor wrapper.
- Shared state: `PermissionsService`, `RecordingCoordinator`, `GlobalHotKeyMonitor`.

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

## PR policy

Personal repo — loose profile: draft→ready promotion and native auto-merge
(`gh pr merge --auto --squash`) are allowed without per-PR confirmation.
Issues auto-add to GitHub Project #4 via built-in workflow — no manual linkage.

## Gotchas

- `Config/Strict.xcconfig` (Onset target): warnings-as-errors, strict memory safety,
  upcoming features ExistentialAny / InternalImportsByDefault / MemberImportVisibility.
- The app must never gain network-client code — spec AC enforced by
  `check-no-network.sh`.
- `swarm-report/` is gitignored orchestration state, not part of the product.
