---
type: spec
slug: onset-devops-ci
date: 2026-06-02
status: approved
platform: [desktop]
surfaces: [ci]
risk_areas: [pii]
non_functional:
  sla: "быстрый PR-гейт — единицы минут; L5 локально — обязательный acceptance-gate"
  a11y:
acceptance_criteria_ids: [AC-1, AC-2, AC-3, AC-4, AC-5, AC-6, AC-7, AC-8, AC-9, AC-10, AC-11, AC-12]
design:
  figma:
  design_system:
---

# Spec: Onset — DevOps / CI Infrastructure

Date: 2026-06-02
Status: approved
Slug: onset-devops-ci

---

## Context and Motivation

Onset разрабатывается полностью агентами (см. [`onset-product-overview`](2026-06-02-onset-product-overview.md) принцип 15). Для agent-driven цикла **скорость обратной связи критична**: долгое ожидание CI = простой агентов. Прямая боль владельца — CodeQL давал 20–30 минут простоя на каждый PR. Эта спека задаёт инфраструктуру вокруг кода (CI/CD, проверки, автоматизация), которая даёт качество без долгих простоев: дешёвые проверки часто и быстро (быстрый PR-гейт), дорогие — асинхронно/по расписанию, агрессивное кэширование, параллелизм, native auto-merge. Таргет — GitHub Actions (репозиторий будет на GitHub). Фундамент анализа — инфра-консорциум (devops + build-engineer + security), результаты в `swarm-report`.

## Acceptance Criteria

- [ ] **AC-1** — Быстрый PR-гейт состоит из параллельных джобов build / lint / unit на GitHub-hosted `macos-26` (arm64, Xcode 26.5 через `DEVELOPER_DIR`); критический путь — самая медленная джоба, цель — единицы минут.
- [ ] **AC-2** — Быстрый PR-гейт — единственные **required** status-checks в branch protection; медленные CI-проверки (CodeQL, notarization) НЕ required и не блокируют PR. L5 в CI отсутствует вовсе (выполняется локально, см. AC-7).
- [ ] **AC-3** — Сборка под максимальной строгостью (Swift 6 strict concurrency + warnings-as-errors + strict memory safety + upcoming-флаги) проходит как часть build-джоба; нарушения валят гейт.
- [ ] **AC-4** — Lint-джоб (SwiftLint strict + SwiftFormat --lint) запускается **параллельно** build (не build-phase), с закоммиченными `.swiftlint.yml` / `.swiftformat`.
- [ ] **AC-5** — Secrets-защита в быстром гейте: gitleaks (pre-commit локально у агента) + GitHub secret scanning push protection (серверная); попытка коммита распознанного секрета (в т.ч. notarization credential) блокируется.
- [ ] **AC-6** — CodeQL и тяжёлый security-scan вынесены в scheduled (weekly + push-to-main) + on-demand (`workflow_dispatch`), статус informational; не на критическом пути PR.
- [ ] **AC-7** — L5 hardware-приёмка выполняется **ТОЛЬКО локально** на машине владельца — агентом (`manual-tester` + MCP), **вне GitHub CI**. Self-hosted раннеров нет; в GitHub Actions L5-джоб нет вообще (GitHub-hosted виртуальные раннеры не имеют реального экрана/камеры). Per-task — на M3 Max; финальная обкатка MVP — на M1 Air (слабый край). Это абсолютный acceptance-gate проекта.
- [ ] **AC-8** — Auto-merge включён (`gh pr merge --auto --squash`) как стандартный паттерн агента: PR открыт → auto-merge → агент переключается на другую задачу; платформа мержит после прохождения required checks.
- [ ] **AC-9** — `concurrency` с `cancel-in-progress` отменяет устаревшие раны на PR-ветках, **исключая** `merge_group` и `push:main` (иначе ломается финальная валидация / история). Сохраняется и при open-source (смысл — освобождение дефицитного macOS-слота, не экономия минут).
- [ ] **AC-10** — Все workflows используют триггер `pull_request` (НЕ `pull_request_target`) и явный least-privilege `permissions:` блок (`contents: read` по умолчанию, write точечно); fork-PR не имеет доступа к secrets.
- [ ] **AC-11** — Auto-merge не пропускает external/fork-PR без ревью доверенного актора; bot/Copilot-аппрув не удовлетворяет требование ревью на fork-PR (branch protection).
- [ ] **AC-12** — Copilot code review (если включён) — non-blocking informational, НЕ required check, не заменяет `/finalize`. Copilot coding agent НЕ используется (конфликт с agent-driven авторством).

**Authoritative definition of done.** Реализующий агент валидирует против этого списка. Напоминание: локальная L5-приёмка (AC из overview) — обязательный acceptance-gate проекта, выполняется агентом локально вне CI; «принято» определяется прохождением локальной L5, а зелёный CI (pr-gate) — необходимое, но не достаточное условие.

## Prerequisites

| Prerequisite | Status | Owner | Notes |
|--------------|--------|-------|-------|
| **Shared Xcode scheme** `Onset.xcodeproj/xcshareddata/xcschemes/Onset.xcscheme` | ⬜ Todo (BLOCKER) | Agent | Сейчас только `xcuserdata` (user-local) → `xcodebuild -scheme Onset` падает на чистом runner. Без этого все CI-джобы не работают |
| **`SWIFT_VERSION` 5.0 → 6.0 + `SWIFT_STRICT_CONCURRENCY=complete` + `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`** | ⬜ Todo | Agent | Текущий pbxproj на 5.0 — строгость не включена; вынести в `Config/Strict.xcconfig` |
| **`ENABLE_APP_SANDBOX = YES` → `NO`** в pbxproj | ⬜ Todo (CONFLICT) | Agent | Текущий шаблон с sandbox **противоречит** решению overview «Developer ID без App Sandbox»; со sandbox ломается прямой доступ к `~/Movies` и AVCaptureSession без entitlements |
| `.swiftlint.yml` (strict) + `.swiftformat` | ⬜ Todo | Agent | Без конфига SwiftLint не strict |
| L5 — локально (нет CI-prerequisite) | — | Agent | Self-hosted раннеров НЕ будет; L5 выполняется агентом на M3 Max (per-task) и M1 Air (финал MVP) локально, вне GitHub |
| Раннер: YAML-label `macos-26` (arm64-образ; НЕ `macos-26-arm64` — это имя образа, не label) | ✅ Verified | — | runner-images README: macOS 26 Arm64 → label `macos-26`. На образе Xcode 26.5 + SDK 26.5 (default=26.4.1) → workflows задают `DEVELOPER_DIR=/Applications/Xcode_26.5.app` + fail-fast проверка версии |
| Notarization secrets (Developer ID `.p12`, ASC API key) как **environment-scoped** GitHub secrets | ⬜ Todo | Human | Не repo-wide; человек заводит credentials, агент настраивает workflow |
| `.gitignore` (DerivedData, `xcuserdata`, `.DS_Store`, `swarm-report/`) | ⬜ Todo | Agent | Репо без .gitignore |

## Affected Modules and Files

| Файл | Change type | Notes |
|------|-------------|-------|
| `.github/workflows/pr-gate.yml` | New | Быстрый гейт: build / lint / unit параллельно, required |
| `.github/workflows/codeql.yml` | New | Scheduled weekly + push:main + dispatch; non-required |
| ~~`.github/workflows/l5-acceptance.yml`~~ | Removed | Self-hosted L5 в CI отменён; L5 выполняется локально агентом вне GitHub |
| `.github/workflows/release.yml` | New | Триггер `push: tags 'v*'`; xcarchive + notarytool |
| `.github/dependabot.yml` | New | github-actions (pinned SHA свежесть) + SPM dev-deps |
| `Config/Strict.xcconfig` | New | Swift 6 strict, warnings-as-errors, strict memory safety, upcoming-флаги |
| `.swiftlint.yml`, `.swiftformat` | New | Strict-конфиги |
| `Onset.xcodeproj/xcshareddata/xcschemes/Onset.xcscheme` | New | Shared scheme |
| `Onset.xcodeproj/project.pbxproj` | Modified | Swift 6, sandbox=NO, привязать xcconfig |
| `.gitignore` | New | Игнор DerivedData/xcuserdata/.DS_Store/swarm-report |
| `scripts/check-entitlements.sh`, `scripts/check-no-network.sh` | New | Allow/deny-list по **собранному** .app; static-proxy AC-8 |
| `Onset.xctestplan` | Modified | Включён code coverage, scoped на таргет `Onset` (не тест-бандл) |
| `scripts/coverage-summary.sh` | New | Сводка результатов тестов + покрытия из `.xcresult` в `$GITHUB_STEP_SUMMARY`; опциональный порог `ONSET_COVERAGE_MIN` |
| `.github/workflows/pr-gate.yml` (`unit`/`build`) | Modified | `unit`: `-resultBundlePath` + `-enableCodeCoverage`, job-summary, артефакт `.xcresult`. Оба job: `xcpretty` → `xcbeautify --renderer github-actions` |

## Technical Approach

### Порядок внедрения — GitHub-окружение настраивается ПЕРВЫМ (до feature-кода)

Agent-driven модель полагается на CI-гейты и auto-merge как на контур качества → инфраструктура должна стоять до того, как агенты начнут писать продуктовый код. Последовательность:

0. **Создать GitHub-репозиторий**, запушить текущее состояние (Human: создание репо/прав; Agent: всё остальное).
1. **Базовая гигиена кода/проекта** (разблокирует CI): `.gitignore`; shared Xcode scheme; `Config/Strict.xcconfig` (Swift 6 + strict concurrency + warnings-as-errors + strict memory safety + upcoming-флаги), привязать к таргетам; `ENABLE_APP_SANDBOX = NO`; `.swiftlint.yml` + `.swiftformat`.
2. **Быстрый PR-гейт** (`pr-gate.yml`: build/lint/unit параллельно) + **branch protection** (required = быстрый гейт).
3. **Защита секретов**: включить GitHub secret scanning **push protection**; gitleaks pre-commit hook; (опц.) AgentShield статический scan; environment-scoped secrets.
4. **Auto-merge** enabled в настройках репо.
5. **Async-слой**: CodeQL scheduled (`codeql.yml`), Dependabot (`dependabot.yml`), pinned-SHA actions.
6. **L5 — локально** (агент на M3 Max через manual-tester/MCP), вне CI. Никаких self-hosted раннеров.
7. **Позже:** `release.yml` (notarization на тегах, GitHub-hosted, секреты владельца); финальная локальная обкатка на M1 Air перед релизом MVP.

Шаги 0–4 — минимум, чтобы первый же продуктовый PR проходил через быстрый гейт с защитой секретов и auto-merge. Шаги 5–6 параллельно/следом. Это «настроить окружение первым шагом».

### Двухскоростной pipeline
- **Быстрый PR-гейт (required, цель — единицы минут):** три параллельные джобы.
  - `build` — `xcodebuild build -scheme Onset -destination 'platform=macOS'`, **Debug** (`-Onone`, `ONLY_ACTIVE_ARCH=YES`, без WMO — на порядки быстрее Release), под полной строгостью (строгость — frontend-фаза, сборку не раздувает). DerivedData-кэш (ключ `hashFiles(project.pbxproj, **/*.xcconfig)` + runner OS).
  - `lint` — SwiftLint strict + SwiftFormat --lint, **параллельно** (не build-phase; не требует сборки — самая быстрая).
  - `unit` — Swift Testing; при модуляризации — `swift test` на SPM-пакете (быстрее xcodebuild test с bundle/signing). Собирает code coverage (scoped на таргет `Onset` через `Onset.xctestplan`), пишет `-resultBundlePath`, рендерит сводку тестов + покрытия в `$GITHUB_STEP_SUMMARY` (`scripts/coverage-summary.sh`) и грузит `.xcresult` артефактом. Покрытие — **информационное, не блокирует** (опциональный порог `ONSET_COVERAGE_MIN` по умолчанию выключен, чтобы не тормозить гейт и не давать флаки-падений). Вывод тестов форматирует `xcbeautify --renderer github-actions` (предустановлен на `macos-26`) → падения тестов становятся inline-аннотациями в diff PR; шаг `gem install xcpretty` убран из `unit`/`build`.
  - В каждой джобе: `env: DEVELOPER_DIR: /Applications/Xcode_26.5.app`.
- **Async-слой (non-required):** CodeQL (weekly + push:main + dispatch — он пересобирает проект, отсюда 20–30 мин; убран с PR-пути), notarization (tags), dependency-scan (weekly). L5 — не в CI (локально, см. AC-7).
- **`concurrency: cancel-in-progress`** при `github.event_name == 'pull_request'`; исключить `merge_group` (ломает auto-merge финал) и `push:main` (история).

### Классификация проверок по триггерам (что блокирует / что периодически)

Принцип: быстрое+критичное → блокирующий PR-гейт; тяжёлое+информационное → периодически на main (видеть дефекты, не блокируя merge'ы). Open-source снимает billing, но НЕ wall-clock простой агента и НЕ macOS-runner concurrency — тяжёлое всё равно вне PR-пути.

| Проверка | Триггер | Блокирует merge | Зачем |
|---|---|---|---|
| build (Debug, полная строгость — флаги той же джобы, не отдельная) | per-PR-required | ✅ | критический путь гейта; строгость = frontend-фаза, не раздувает codegen |
| lint (SwiftLint strict + SwiftFormat --lint) | per-PR-required | ✅ | параллельно build, сборки не требует — быстрейшая |
| unit (Swift Testing / `swift test` на SPM) | per-PR-required | ✅ | L2 чистая логика без устройств, параллельно |
| code coverage + сводка тестов (job-summary + `.xcresult` артефакт) | per-PR (в `unit`-джобе) | ❌ информационно | Видимость покрытия таргета `Onset` и pass/fail без внешнего сервиса; порог `ONSET_COVERAGE_MIN` по умолчанию выкл |
| entitlements-check (по собранному .app) | per-PR-required | ✅ | downstream build (секвенс в гейте); ловит config-drift (sandbox=YES, network.client) день-в-день; дёшево |
| no-network static-proxy (nm/otool) | per-PR-required | ✅ | downstream build; статическая гарантия AC-8; дёшево |
| privacy-manifest lint (PrivacyInfo.xcprivacy) | per-PR-required | ✅ | дёшево, детерминированно |
| dependency-review-action | per-PR-required* | ✅ | *условно — если GitHub dependency graph поддерживает SPM (verify перед включением); лёгкий diff deps на PR |
| secret scanning push protection | on every push (server-side) | блокирует push | основной барьер «агент закоммитил ключ»; срабатывает на push в любую ветку |
| gitleaks | local-precommit | — | слой 2 защиты секретов, локально мгновенно |
| AgentShield static scan (опц.) | local-precommit | — | доп. слой agent-config (hooks/permissions/~/.claude); только статика |
| CodeQL full | scheduled weekly + push:main + on-demand | ❌ | **прямой ответ на боль 20-30 мин**: убран с PR-пути; дефекты видны регулярно на main |
| Copilot Autofix (на CodeQL-алерт) | следует за CodeQL (async) | ❌ | авто-fix-PR; проходит обычный гейт + agent-review |
| dependency SCA (dev-deps) | scheduled weekly | ❌ | узкая поверхность; Dependabot держит свежим |
| Release/WMO build | scheduled nightly + push:main | ❌ | ловит Release-only регрессы оптимизатора; на порядки медленнее Debug |
| Xcode-version-drift matrix | scheduled weekly | ❌ | matrix только async (лишние оси удлиняют PR + конкурируют за macOS-слот) |
| UI-тесты (XCUITest) | scheduled nightly | ❌ | L3 медленны/менее детерминированны |
| L5 hardware (запись на железе) | **локально, вне CI** (агент на M3 Max per-task; M1 Air финал MVP) | ❌ в CI; ✅ блокирует **локальную приёмку** задачи | GitHub-hosted не имеет реального экрана/камеры; self-hosted не используется → L5 только локально, абсолютный acceptance-gate |
| notarization (xcarchive + notarytool) | on tag `v*` | ❌ | релизное событие; secrets за `release`-environment |
| build provenance (SLSA attestation) | on tag `v*` | ❌ | supply-chain transparency для open-source (later) |

### GitHub-возможности (offload + эффективность; open-source)

Open-source = unlimited минуты → **offload тяжёлого с dev-машины (M3 Max) в GitHub-hosted CI**: Release/WMO, CodeQL, UI-тесты, Xcode-drift matrix, dependency-scan — не грузят dev-тачку, минуты бесплатны. Hardware-зависимое (L5) — локально на машине владельца (агент через manual-tester/MCP), вне CI (нельзя на виртуальных GitHub-hosted раннерах; self-hosted не используется).

- **MVP:** concurrency+cancel-in-progress (СОХРАНИТЬ — освобождает дефицитный macOS-слот, смысл не billing); branch protection required-checks; auto-merge; environments + protection rules (`release` для notarization-секретов); least-privilege `permissions:` на `GITHUB_TOKEN` (contents:read по умолчанию — **обязательно для public**); secret scanning; Dependabot; Copilot Autofix; Copilot Chat в PR (on-demand, безвреден).
- **later:** reusable workflows (общий macOS+Xcode setup), matrix (только async), artifact attestations (SLSA provenance, бесплатно для public через Sigstore), job summaries (агент-читаемые сводки), GitHub Security Advisories (приватный канал репорта уязвимостей), Copilot code review.
- **skip:** merge queue (только org-owned, Onset user-owned), required workflows (org-feature), OIDC (Apple notary не федерирует GitHub OIDC → notarization остаётся environment-secrets), **Copilot coding agent** (конфликт с agent-driven — см. ниже).

### Copilot в agent-driven модели

- **Copilot coding agent — SKIP.** Onset уже agent-driven: ваши агенты — единственный автор, спека = автономный контракт (принцип 15). Второй автономный автор создаёт race на issues, дублирование, вопрос авторства. Не задействовать.
- **Copilot code review — опционально, non-blocking, НЕ required.** Дополнительный независимый ревью-слой (другой движок поверх вашего Claude-agent-ревью `/finalize` — diversity, ловит иной bias). Жёстко: **не делать required** (убьёт fast-gate + шум) и **не заменяет `/finalize`** (он остаётся основным review→fix→simplify gate). Informational-комментарии на PR.
- **Copilot Autofix — главный выигрыш Copilot.** Бесплатен и включён по умолчанию для public-repo с CodeQL. На каждый CodeQL-алерт (в async-слое) предлагает fix-PR → дефект всплывает сразу с готовым фиксом, нулевая цена на PR-пути. fix-PR проходит обычный required-гейт + agent-review (не auto-merge без ревью). *Verify: поддержка Swift у Autofix (CodeQL Swift = GA, но coverage Autofix исторически у́же — проверить docs перед включением; если нет — отложить).*
- **Copilot Chat в PR** — безвреден, on-demand (разобраться в чужом external-PR диффе).

### Open-source threat model (новый — критичный blind spot)

Public repo: любой может открыть PR, который запускает `pr-gate.yml`. Обязательные меры:
- **Триггер `pull_request` (НЕ `pull_request_target`)** — secrets недоступны fork-PR по умолчанию; `pull_request_target` с checkout untrusted-кода = классическая RCE-уязвимость Actions.
- **Least-privilege `permissions:`** в каждом workflow — `contents: read` по умолчанию, write только где функционально нужно.
- **Auto-merge × external-PR:** malicious fork-PR не должен авто-уехать в main. Branch protection: require review от **человека/доверенного актора** для external-PR; bot/Copilot-аппрув НЕ удовлетворяет требование ревью на fork-PR.
- **Self-hosted раннеров нет** → вектор «fork-PR выполняет недоверенный код на dev-машине через self-hosted» неприменим. L5 — локально вне CI; «Require approval for first-time contributors» всё равно включить (контроль запуска CI на fork-PR).
- **Notarization secrets** за `release`-environment (больше глаз на конфиге в public).

### Auto-merge (delegate-the-wait)
`gh pr merge <PR> --auto --squash` — для личного репо на free-плане (merge queue требует Team/Enterprise). Branch protection: required = быстрый гейт; auto-merge enabled. Агент открыл PR → включил auto-merge → ушёл на следующую задачу.

### Модуляризация (наибольший ROI скорости — рекомендация build-engineer)
Разбить на SPM local-package таргеты по слоям DAG из overview (Capture/Encode/Recording/Capability/Configuration/...). Даёт одновременно: инкрементальную сборку (изменение в модуле → пересборка только его + зависимых), параллельные таргеты, изоляцию unit-тестов (`swift test` без app bundle), и **compile-time проверку архитектурных границ** (направление зависимостей — принцип 10 overview). Trade-off: cross-module inlining на hot-path (per-frame callback) — но реальная работа там в системных фреймворках (VideoToolbox/AVFoundation), Swift-overhead незначим. MVP-уровень: достаточно базовой разбивки.

### Security-проверки (узкая поверхность — прагматика)
NO network client убивает целые классы уязвимостей; минимум deps делает тяжёлый supply-chain scan избыточным. Реальная поверхность — entitlements/TCC + notarization-секреты, не код. Быстрый гейт:
- **gitleaks** (pre-commit локально) + **GitHub secret scanning push protection** (серверная) — блокирует коммит секрета (agent-driven риск: агент может закоммитить notarization credential).
- **Entitlements allow/deny-list** на **собранном** `.app` (`codesign -d --entitlements -` — xcodebuild инжектит часть entitlements, исходный `.entitlements` даст false pass/fail). Ловит config-drift (sandbox=YES, лишние app-groups) в день один.
- **Static-proxy AC-8** (no network): `nm`/`otool` по собранному бинарю — нет линковки с `Network.framework`/`CFNetwork`, нет URLSession-символов. Runtime-проверка (`nettop`) — в L5/async.
- **L2 права файлов** `~/Movies/Onset/` (владелец-пользователь, без group/other).
- **PrivacyInfo.xcprivacy** lint (required-reason API, напр. UserDefaults).
- **Pin GitHub Actions к commit-SHA** (для agent-driven важнее, чем SCA dev-deps) + Dependabot держит свежими.
- **Notarization secrets**: environment-scoped (не repo-wide), временный keychain в CI с гарантированной очисткой (`trap`).

### Защита от «агент закоммитил секрет» (многослойная — главная забота)

Agent-driven: агент генерирует конфиги подписи/CI и может случайно закоммитить ключ/токен. Защита в несколько независимых слоёв (ни один не единственная точка отказа):
1. **GitHub secret scanning push protection** (серверная) — физически блокирует `git push` с распознанным секретом. Основной барьер, работает даже если локальные слои обойдены.
2. **gitleaks pre-commit hook** (локально у агента) — ловит до коммита, мгновенно.
3. **`.gitignore`** — `.env`, `*.p12`, credentials, `xcuserdata` не попадают в индекс.
4. **Environment-scoped secrets** — notarization-credentials живут в GitHub Environment secrets, не в коде/репо вообще (нечего коммитить).
5. **AgentShield — статический CLI-scan `~/.claude`-конфигов (опционально, ADOPT WITH CAUTION).** Покрывает то, чего не видят gitleaks/push-protection: секреты в agent-config, hook-injection в `PreToolUse`/`SessionStart`, permissive `Bash(*)`, MCP supply-chain (незакреплённые `npx`). Использовать **только быстрый статический режим** (`agentshield scan`, локально/pre-commit или лёгкий CI-шаг) — **НЕ** MiniClaw runtime, **НЕ** GitHub App (даёт доступ к репо), **НЕ** `--opus` (3-агентный, медленный — конфликт со скоростью). Незрелость (хакатон-проект) приемлема для read-only локального scan; не привязывать к нему pipeline жёстко — дополнительный слой, не замена слоёв 1–4. Пере-оценить зрелость перед любым углублением.
6. **Hook-барьер (опц., harness-level):** PreToolUse-hook, блокирующий Edit/Write файлов, похожих на credentials — рассмотреть как ещё один слой для agent-driven.

### L5 — локально, вне CI
GitHub-hosted (виртуальные) не имеют capture-hardware / AVCapture-устройств / возможности kill-9 + проверки файла, а self-hosted раннеров владелец не подключает. Поэтому L5 (AC-4 ffprobe CFR, AC-7 sync, AC-10 crash-injection из recording-spec) выполняется **только локально** на машине владельца — агентом (`manual-tester` + MCP): per-task на M3 Max, финальная обкатка MVP на M1 Air. В GitHub Actions L5-джоб нет. «Принято» по задаче = локальная L5 пройдена; зелёный pr-gate — необходимое, но не достаточное условие.

### Build-time гигиена
- Debug для PR; Release/WMO — async.
- Slow-compile guardrail: `-Xfrontend -warn-long-expression-type-checking` (порог калибровать на реальном коде, начать консервативно) — против O(N⁴) type-inference.
- SPM SourcePackages кэш (ключ по `Package.resolved`) — modest при минимуме deps.
- Трекинг времени сборки (`-showBuildTimingSummary` + xclogparser) — later, против незаметного регресса.

## Technical Constraints

- GitHub Actions; macOS-раннеры. Pinned-SHA для сторонних actions.
- Строгость не приносить в жертву скорости (она frontend-фаза, не раздувает codegen) — гейт строгий И быстрый.
- L5 — локально вне CI; self-hosted раннеров нет. CI — только GitHub-hosted.
- Notarization-секреты environment-scoped + временный keychain с очисткой.
- Энтайтлменты проверять на собранном .app, не на исходнике.
- Логи CI — без секретов/PII.

## Decisions Made

| Decision | Choice | Rationale |
|----------|--------|-----------|
| CI-архитектура | Двухскоростная: быстрый required гейт + async non-required слой | Убирает 20–30 мин (CodeQL) с PR-пути — прямой ответ на боль скорости |
| Merge-автоматизация | Native auto-merge (`--auto --squash`), не merge queue | Merge queue требует Team/Enterprise; auto-merge достаточно для личного репо |
| CodeQL | Weekly + push:main + on-demand, non-required | Compiled-language analyzer пересобирает проект (медленно); узкая поверхность риска (no network) |
| Runner для PR-гейта | GitHub-hosted label `macos-26` (arm64-образ; Xcode 26.5 via DEVELOPER_DIR) | Xcode 26.5 + SDK 26.5 присутствуют (verified live, default=26.4.1); `macos-26-arm64` — имя образа, не label; self-hosted не используется |
| Исполнение L5 | Локально, агентом, вне CI (M3 Max per-task; M1 Air финал) | GitHub-hosted без реального hardware; self-hosted владелец не подключает |
| PR-конфигурация | Debug (`-Onone`, без WMO) | Release/WMO на порядки медленнее; не нужен для гейта |
| Модуляризация | SPM local packages по слоям DAG | Инкрементальность + параллелизм + изоляция тестов + compile-time границы |
| Security-scan объём | Минимальный (secrets + entitlements + static no-network), без тяжёлого SCA/DAST | Узкая поверхность; over-scan подрывает скорость и доверие |
| AgentShield | Только статический CLI-scan как опциональный доп. слой; runtime/App/Deep-Opus — нет | Статика быстрая и покрывает agent-config (hooks/permissions/~/.claude secrets); незрелость приемлема для read-only scan, опасна для runtime/доступа |
| Защита от коммита секретов | Многослойная: push protection + gitleaks + .gitignore + env-scoped secrets (+ опц. AgentShield, hook) | Главная забота agent-driven; ни один слой не единственная точка отказа |
| Порядок внедрения | GitHub-окружение — первый шаг, до feature-кода | Контур качества (CI-гейты + auto-merge) должен стоять до того, как агенты пишут продуктовый код |
| Open-source эффект | Снимает только billing; cancel-in-progress сохранить, matrix только async | Связывающие констрейнты — wall-clock простой агента + macOS-runner concurrency, не деньги |
| Copilot coding agent | Skip | Конфликт с agent-driven авторством (второй автор, race на issues) |
| Copilot code review | Опционально, non-blocking informational | Diversity-ревью поверх `/finalize`; required убил бы fast-gate + шум |
| Copilot Autofix | Включить (verify Swift-поддержку); fix-PR через обычный гейт+ревью | Бесплатен для public с CodeQL; дефект всплывает с готовым фиксом в async-слое |
| Offload | Тяжёлое не-hardware → GitHub-hosted CI; hardware (L5) → локально на dev-машине вне CI | Не грузить dev-машину сборками; минуты бесплатны; L5 нельзя на виртуальных, self-hosted не используется |
| External-PR безопасность | pull_request (не target) + least-privilege permissions + human-review на fork | Public repo: чужой PR запускает pipeline — threat model шире |
| Видимость coverage/тестов | Self-contained: `$GITHUB_STEP_SUMMARY` + `.xcresult` артефакт + `xcbeautify`-аннотации; НЕ Codecov / check-action | Lean-этика, no external service, least-privilege (`contents: read` сохранён); Codecov потребовал бы внешний сервис и токен |
| Coverage-гейт | Report-only (порог `ONSET_COVERAGE_MIN` по умолчанию выкл) | Нет калиброванной базовой линии; жёсткий порог дал бы флаки-падения и тормозил AC-1 fast-gate |
| Форматтер логов | `xcbeautify` (предустановлен на `macos-26`) вместо `xcpretty` (`gem install`) | Inline-аннотации падений + лучше парсит Swift Testing; минус одна зависимость и шаг установки |

## Risks and Concerns

- **[critical] `pull_request_target` с checkout untrusted-кода — классическая RCE GitHub Actions** → использовать `pull_request` (secrets недоступны fork-PR по умолчанию), не `pull_request_target`.
- **[critical] Auto-merge × external-PR (open-source) — malicious fork-PR может авто-уехать в main** → branch protection: require review от человека/доверенного актора для fork-PR; bot/Copilot-аппрув не удовлетворяет.
- **[resolved] Self-hosted L5-раннер на dev-машине** — риск устранён архитектурно: self-hosted раннеров нет, L5 локально вне CI. (Оставлено для истории решения.)
- **[critical] Notarization-секреты при open-source (больше глаз/форков)** → environment-scoped (`release`), временный keychain с `trap`-очисткой; secrets только в release-workflow на теге.
- **[major] Least-privilege `permissions:` не выставлен** → явный блок в каждом workflow, `contents: read` по умолчанию.
- **[major] Отказ от cancel-in-progress «раз минуты бесплатны»** → дефицитный macOS-слот занят устаревшими ранами, свежий коммит ждёт. Сохранить (констрейнт — concurrency+wall-clock, не billing).
- **[major] Раздувание PR-гейта matrix-осями «потому что бесплатно»** → matrix только в async-слой; PR-гейт минимален.
- **[major] `ENABLE_APP_SANDBOX=YES` дрейф из шаблона в распространяемую сборку** → entitlements allow/deny-list по собранному .app ловит дрейф день-в-день.
- **[major] Entitlements-проверка по исходному `.entitlements` вместо собранного .app** → проверять только `codesign -d --entitlements -` на собранном .app (xcodebuild инжектит часть).
- **[minor] Опора на Copilot Autofix как на качество-гейт** → Autofix informational; fix-PR через обычный гейт + agent-review, не auto-merge без ревью.
- **[minor] Copilot Autofix может не поддерживать Swift** → verify на docs перед включением; если нет — отложить.
- **[minor] AgentShield (незрелый) жёстко в pipeline** → только статический read-only scan как доп. слой, не блокирующий; пере-оценить зрелость.
- **[minor] path filters footgun на required checks** (docs-only PR un-mergeable) → паттерн skip-джобы, рапортующей имя required-check.

## Out of Scope

- CAS / explicitly-built-modules compilation caching (Xcode 26) — *(later: измерить выигрыш)*
- Self-hosted как primary PR-runner — *(later: оптимизация скорости после MVP)*
- Полная матрица версий Xcode — *(later)*
- Performance-regression CI (encode-budget калибровка) — *(post-MVP, после обкатки)*
- Build-time трекинг (xclogparser) — *(later)*
- AgentShield **runtime-компоненты** (MiniClaw sandbox, GitHub App с доступом к репо, `--opus` 3-агентный deep-scan) — *(out для MVP: незрелость опасна для runtime/доступа; deep-scan медленный. Статический CLI-scan — опциональный доп. слой, см. «Защита от секретов» в Technical Approach)*

## Open Questions

- [ ] Устойчивость к ротации Xcode на hosted-образе — *non-blocking, implementation-time*
  - Recommendation: pr-gate содержит fail-fast проверку версии Xcode (если 26.5 уедет с образа — явная ошибка, не молчаливый неверный SDK); мониторить runner-images announcements
- [ ] Точный порог `-warn-long-expression-type-checking` — *non-blocking, implementation-time*
  - Recommendation: калибровать на реальном коде, начать консервативно (напр. 500 ms)
- [ ] Поддержка SPM в GitHub dependency graph (для `dependency-review-action`) — *non-blocking, implementation-time*
  - Recommendation: verify на docs.github.com; если SPM поддержан — dependency-review в required PR-гейт; иначе полагаться на Dependabot
- [ ] Поддержка Swift у Copilot Autofix — *non-blocking, implementation-time*
  - Recommendation: verify на docs.github.com (CodeQL Swift = GA, но Autofix coverage у́же); если Swift не поддержан — отложить Autofix, CodeQL-алерты ревьюит агент
- [ ] Блокирующий coverage-порог и/или Codecov-интеграция — *deferred, post-MVP*
  - Recommendation: сначала накопить данные по `$GITHUB_STEP_SUMMARY` (report-only), затем калибровать `ONSET_COVERAGE_MIN`; Codecov/check-action — только при появлении устойчивого к новому формату `.xcresult` варианта, чтобы не нарушать lean-этику

## Future Phases

**Phase 2:** CAS caching, build-time трекинг, performance-regression (локально/CI после обкатки на M1 Air … M3 Max). Notarization/release workflow дозревает к первому релизу. (Self-hosted раннеры не планируются — L5 остаётся локальным.)
