---
type: test-plan
slug: permissions-onboarding
platform: [desktop]
---

# Test Plan: Onset — Permissions & Onboarding

| | |
|---|---|
| Feature | Permissions & Onboarding (macOS TCC: Screen Recording / Camera / Microphone) |
| Spec | `docs/specs/2026-06-02-onset-permissions-onboarding.md` (AC-1…AC-9; AC-6 amended) |
| Design | `docs/design-ref/request-permissions/` |
| Platform | macOS 26.x, Apple Silicon |
| TCC reset (precondition) | `tccutil reset ScreenCapture dev.androidbroadcast.Onset; tccutil reset Camera dev.androidbroadcast.Onset; tccutil reset Microphone dev.androidbroadcast.Onset` |

## Findings

- **AC-6 amended** — Screen Recording has **no distinct "denied" state**: `CGPreflightScreenCaptureAccess()` returns only `Bool`, so denied is indistinguishable from not-determined. Screen states are «Требуется» → «Ожидание…» → ✓. No screen red-banner. Camera/Microphone keep a real `denied` state. TCs reflect this (no screen-denied TC; camera/mic-denied TCs present).
- **Latent functional dependency** — Onset appears in System Settings → Screen Recording **only after** it calls `CGRequestScreenCaptureAccess()` once. The «Открыть настройки» action fires the one-shot request first, then deep-links. TC-7 verifies the app is actually present in the list.
- Routing has no persisted "onboarding done" flag — it is status-driven; revoking a permission returns to onboarding (TC-18).
- Relaunch path is verifiable only on a real signed build (not Xcode/DerivedData) — TC-8/TC-9 are L5-only.

## Risk Areas

- **TCC screen-recording relaunch** (highest) — self-relaunch + `--post-screen-grant` + anti-loop; OS may respawn the process on grant.
- **Graceful degradation** — wrong effective-permissions subset → user blocked or records the wrong thing.
- **PII** — device names shown in UI must never be logged.
- **No network egress** — build-level guarantee behind «данные никуда не отправляются».

## Test Cases

### Phase 1 — Pure logic (L2, no device)

#### TC-1 — EffectivePermissions: graceful subsets
| | |
|---|---|
| Priority | P1 |
| Type | unit — pure value-type mapping; `unit` rationale: no I/O |
| Tier | Feature |
| Preconditions | — |
| Steps | Compute `EffectivePermissions` for every combination of the 3 statuses |
| Expected Result | screen-only / camera-only / video-without-audio / blocked-when-no-video-source match AC-7/AC-11; `canRecord` false only when no video source |
| Source | Spec §AC-7/AC-11; `EffectivePermissions.swift` (covered by `EffectivePermissionsTests`) |

#### TC-2 — AppRouter start routing
| | |
|---|---|
| Priority | P0 |
| Type | unit; rationale: pure routing function |
| Tier | Smoke |
| Preconditions | — |
| Steps | `route()` for: allGranted+noArg; missing+noArg; arg+preflightTrue+allGranted; arg+preflightTrue+notAllGranted; arg+preflightFalse |
| Expected Result | `.main`; `.onboarding`; `.allSet`; `.onboarding` (not allSet); `.onboarding` (anti-loop, no relaunch) — per AC-5/AC-8/AC-9 |
| Source | Spec §AC-5/AC-8/AC-9; `AppRouter.swift` (covered by `AppRouterTests`) |

#### TC-3 — Relaunch edge-detection
| | |
|---|---|
| Priority | P0 |
| Type | unit |
| Tier | Feature |
| Preconditions | — |
| Steps | `shouldTriggerRelaunch(previous:current:)` for notDetermined→authorized, authorized→authorized, →notDetermined, denied→authorized |
| Expected Result | relaunch only on front-edge (previous != authorized && current == authorized) |
| Source | `AppRouter.swift` (covered by `AppRouterRelaunchTests`) |

#### TC-4 — OnboardingViewModel state derivation
| | |
|---|---|
| Priority | P1 |
| Type | unit — VM via fake `PermissionsProviding` |
| Tier | Feature |
| Preconditions | `FakePermissionsService` |
| Steps | Drive grant/deny/await transitions through the fake |
| Expected Result | progress «N из 3», card statuses, mic-remaining subtitle, polling start/stop, graceful availability all correct |
| Source | `OnboardingViewModel.swift` (covered by `OnboardingViewModelTests`) |

### Phase 2 — Live app L5 (running Onset.app on macOS 26.x)

#### TC-5 — First launch shows onboarding (AC-1)
| | |
|---|---|
| Priority | P1 |
| Type | ui-scenario |
| Tier | Smoke |
| Preconditions | TCC reset (all 3 not-determined) |
| Steps | Launch Onset.app |
| Expected Result | Onboarding window: «Onset нужны разрешения», subtitle «…Данные никуда не отправляются», 3 cards (Запись экрана/Камера/Микрофон) all «Требуется», progress «0 из 3 · нужно выдать три разрешения», footer «Позже» + «Продолжить» (disabled) |
| Source | Spec §AC-1; Figma cold 0/3 |

#### TC-6 — Camera & Microphone grant without restart (AC-2)
| | |
|---|---|
| Priority | P1 |
| Type | ui-scenario |
| Tier | Smoke |
| Preconditions | TC-5 state |
| Steps | Tap «Разрешить» on Camera → accept system prompt; same for Microphone |
| Expected Result | Each card flips to ✓ immediately (no relaunch); subtitle shows the device name (e.g. «MacBook Pro — микрофон»); progress increments |
| Source | Spec §AC-2; Figma waiting 2/3 |

#### TC-7 — Screen «Открыть настройки» registers app + deep-links (AC-3, AC-4)
| | |
|---|---|
| Priority | P0 |
| Type | ui-scenario |
| Tier | Feature |
| Preconditions | TC-6 state; screen not granted |
| Steps | Tap «Открыть настройки» on the Screen card |
| Expected Result | (a) **Onset appears as its own row** in System Settings → Privacy → Screen Recording (the one-shot CGRequest registered it); (b) Settings opens at the Screen Recording pane; (c) screen card shows numbered 1-2-3 instructions; (d) card moves to «Ожидание…» with «Проверить снова» available |
| Source | Spec §AC-3/AC-4; Figma waiting; Findings (registration) |

#### TC-8 — Screen auto-detect + relaunch → «Всё готово» (AC-4, AC-5)
| | |
|---|---|
| Priority | P0 |
| Type | ui-scenario (L5, signed build) |
| Tier | Feature |
| Preconditions | TC-7; camera+mic already ✓ |
| Steps | Toggle Onset ON in Settings → Screen Recording; do not return manually |
| Expected Result | Polling/OS detects grant → app relaunches itself once (no duplicate Gatekeeper prompt) → shows «Всё готово · 3 из 3 · все разрешения активны» exactly once; «Перейти к записи» present |
| Source | Spec §AC-4/AC-5; `tcc-screen-verify.md` |

#### TC-9 — «Перейти к записи» lands on Main (AC-5/AC-8)
| | |
|---|---|
| Priority | P1 |
| Type | ui-scenario |
| Tier | Feature |
| Preconditions | TC-8 «Всё готово» |
| Steps | Tap «Перейти к записи» |
| Expected Result | Main screen shown (placeholder); does NOT bounce back to onboarding |
| Source | Spec §AC-5; finalize round-1 fix |

#### TC-10 — Repeat launch with all granted skips onboarding (AC-8/AC-9)
| | |
|---|---|
| Priority | P1 |
| Type | ui-scenario |
| Tier | Regression |
| Preconditions | All 3 granted |
| Steps | Quit and relaunch Onset.app |
| Expected Result | Onboarding skipped (≤1 status-check frame), Main shown directly; «Всё готово» NOT shown (no transient arg) |
| Source | Spec §AC-8/AC-9 |

#### TC-11 — Graceful «Продолжить без экрана» (AC-7)
| | |
|---|---|
| Priority | P0 |
| Type | ui-scenario |
| Tier | Feature |
| Preconditions | Camera granted, screen NOT granted |
| Steps | In onboarding (incl. while «Ожидание…» screen), use «Продолжить без экрана» |
| Expected Result | Option is available whenever screen not granted + camera available (not gated on a denied state); leads to Main with camera+(mic) effective permissions; no waiting dead-end |
| Source | Spec §AC-6/AC-7 (amended) |

#### TC-12 — Graceful «Записать без звука» (AC-7)
| | |
|---|---|
| Priority | P1 |
| Type | ui-scenario |
| Tier | Feature |
| Preconditions | Screen+Camera granted, microphone not granted |
| Steps | Observe footer; use «Записать без звука» |
| Expected Result | Header «Почти всё готово. Осталось выдать последнее разрешение…»; «Записать без звука» leads to Main with video-without-audio |
| Source | Spec §AC-7; Figma mic-remaining |

#### TC-13 — Camera denied state (AC-6 camera/mic retain denied)
| | |
|---|---|
| Priority | P1 |
| Type | ui-scenario |
| Tier | Feature |
| Preconditions | Camera previously denied in Settings |
| Steps | Launch onboarding |
| Expected Result | Camera card shows «Запрещён» chip + «Открыть настройки»; no repeated system prompt; VoiceOver can focus & activate the button |
| Source | Spec §AC-6 (camera/mic) |

#### TC-14 — Microphone denied state
| | |
|---|---|
| Priority | P2 |
| Type | ui-scenario |
| Tier | Feature |
| Preconditions | Microphone denied in Settings |
| Steps | Launch onboarding |
| Expected Result | Mic card «Запрещён» + «Открыть настройки»; «Записать без звука» path available |
| Source | Spec §AC-6/AC-7 |

#### TC-15 — Screen has no denied state (AC-6 amended)
| | |
|---|---|
| Priority | P2 |
| Type | ui-scenario |
| Tier | Regression |
| Preconditions | Screen not granted (regardless of prior interaction) |
| Steps | Observe screen card across cold and post-Settings states |
| Expected Result | Screen card only ever «Требуется»/«Ожидание…»/✓ — never «Запрещён»; no red screen banner; «Открыть настройки» always available |
| Source | Spec §AC-6 (amended) |

#### TC-16 — No video source blocks recording (P0)
| | |
|---|---|
| Priority | P0 |
| Type | ui-scenario |
| Tier | Feature |
| Preconditions | Neither screen nor camera granted |
| Steps | «Позже» → reach Main |
| Expected Result | Main shows «Запись недоступна — выдайте разрешения» + button back to onboarding; recording blocked |
| Source | Spec §AC-7/AC-11; `MainView.swift` |

#### TC-17 — «Позже» at 0/3 → blocked Main + return
| | |
|---|---|
| Priority | P3 |
| Type | ui-scenario |
| Tier | Regression |
| Preconditions | Cold 0/3 |
| Steps | Tap «Позже»; then tap «Выдать разрешения» on Main |
| Expected Result | Main blocked state; return button routes back to onboarding |
| Source | Spec Technical Approach «Позже» |

#### TC-18 — Revoke in Settings returns to onboarding (P0)
| | |
|---|---|
| Priority | P0 |
| Type | ui-scenario |
| Tier | Regression |
| Preconditions | All granted, on Main |
| Steps | Revoke a permission (e.g. Camera) in System Settings; bring Onset to foreground / relaunch |
| Expected Result | App returns to onboarding (status-driven, no persisted done-flag) |
| Source | Spec Technical Approach «Роутинг старта» |

#### TC-19 — Anti-loop on relaunch with preflight false (AC-5)
| | |
|---|---|
| Priority | P3 |
| Type | unit + ui-scenario |
| Tier | Regression |
| Preconditions | Launch with `--post-screen-grant` but screen preflight false |
| Steps | Simulate the transient-arg launch without an actual grant |
| Expected Result | No relaunch loop; routes by status (onboarding), `pendingScreenGrantRelaunch` cleared |
| Source | Spec §AC-5 |

## Edge Cases & Negative Scenarios

- Toggle screen OFF after granting (revoke) while app running / on relaunch — covered conceptually by TC-18 (verify at L5; known-uncertain from spike re: stale revoke value).
- «Всё готово» must show **once** — re-foregrounding must not re-show it (transient arg consumed).
- Camera/mic system prompt double-tap protection (button disabled/loading while prompt up).
- Dynamic Type / VoiceOver order / chip contrast — L5 a11y checks (deferred from finalize).

## Coverage Matrix

| AC | TCs |
|---|---|
| AC-1 | TC-5 |
| AC-2 | TC-6 |
| AC-3 | TC-7 |
| AC-4 | TC-7, TC-8 |
| AC-5 | TC-2, TC-3, TC-8, TC-9, TC-19 |
| AC-6 (amended) | TC-13, TC-14, TC-15 |
| AC-7 | TC-1, TC-11, TC-12 |
| AC-8 | TC-9, TC-10 |
| AC-9 | TC-10 |
| AC-11 (no-source block) | TC-1, TC-16 |

## Suggested Automation Candidates

- TC-1…TC-4 — already automated (Swift Testing, 45 tests). Keep as regression.
- TC-5, TC-6, TC-13/14, TC-16, TC-17 — automatable via desktop MCP (`manual-tester`); TCC system prompts/Settings toggles need scripted-or-assisted steps.
- TC-8/TC-9 (relaunch) — manual L5 on a signed build; not CI-automatable.

## Non-functional / Instrumentation

- **Log events** (`os.Logger`, subsystem `dev.androidbroadcast.Onset`, category `PermissionsService`/`AppRelauncher`): permission status transitions, screen-poll ticks, relaunch trigger. Verify at L5 they fire on the corresponding actions.
- **PII:** assert no log line interpolates device names (`defaultCameraName`/`defaultMicrophoneName`/`primaryDisplayDescription`) — display-only. (Confirmed in code review; re-confirm via Console.app during L5.)
- **No network egress:** `scripts/check-entitlements.sh` asserts absence of `network.client`/`network.server` and App Sandbox on the built `.app`; no `URLSession`/telemetry in the feature. (CI artifact-checks.)
- **Metrics / Traces / Alerts / Dashboards:** N/A — local desktop utility, no backend/telemetry by design (overview #12 no network egress).
