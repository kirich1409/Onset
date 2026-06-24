# План реализации: активный сигнал о критических проблемах записи

Источник истины: `docs/specs/critical-recording-signals-spec.md` (v3-final, PASS).
Ветка: `feature/critical-recording-signals`.

## Принцип декомпозиции

Снизу вверх: сначала чистая логика и константы (полностью L2-тестируемы без
интеграции), затем live-seam данных, затем интеграция в координатор, UI и
уведомления, в конце docs + L5. Каждая фаза оставляет проект компилируемым и
зелёным по L0-L2. L5 (AC-1/2/7/12/13) — единым проходом на MX Brio в конце.

## Зависимости фаз

```
P0 prereqs ─┬─ A foundations (pure) ──┬─ C coordinator ─┬─ D UI ──┐
            │                          │                 ├─ E notif┤─ F docs ─ G L5
            └─ B live-seam ────────────┘                 │         │
                                                          └─────────┘
```

- A (чистые детекторы, enum, константы) и B (live-seam) независимы → параллельны.
- C интегрирует A+B в координатор (live view + session latch, монотонное время).
- D (UI) и E (уведомления) зависят от C, между собой независимы → параллельны.
- F (docs) после C-E; G (L5) — финальная верификация всего.

## Фазы

### P0 — Prerequisites (gate, до A-E)
P1 числовой fps-readout (делается в B). P2 монотонные часы (в C). P3 entitlement
Time Sensitive (в E). P4 проверить живой путь `degradedWarning`/
`postStopDropWarningThreshold` после #246 — короткий аудит кода до C, чтобы знать,
переиспользуем или обходим существующую пост-стоп ветку.

### A — Foundations (pure/contract, L2)
Константы в `RecordingConfiguration` (9 шт.); `CriticalIncident` +
`CriticalIncidentScope` в `PipelineTypes.swift` с ручными nonisolated `==`/`hash`;
`FpsCollapseDetector` (baseline-окно + skip + freeze-on-candidate + AND-condition,
время аргументом) и `SustainedDropDetector` (degraded-длительность + нормированный
drop-rate + floor). L2-тесты на AC-3(а)/4/5/6 (детекторы). Плюс **контракт нотифаера**
(до C): протокол `RecordingStartNotifying` + его реализация (уровень по тиру) + Fake.
Дедуп/session-cap (AC-9, AC-3(б)) живут проводными в координаторе (фаза C), не здесь.

### B — Live-seam (P1)
latest-snapshot камеры (struct с fps/gap rate + возраст/tick-id) в
`StageRateAggregator`, обновляемый внутри существующего `flush`/`rateLock` БЕЗ
reset окна. **Атомарно**: смена сигнатуры `flush` И миграция всех 4 call-site
(VideoEncoder/CameraSource/ScreenSource/FileWriter) — в одной задаче, иначе проект
не компилируется между ними. Отдельно `RecordingSession.currentRates()` — pull под
существующим lock. encoder/writer-снимок НЕ пробрасывать.

### C — Coordinator integration (P2, P4)
Два значения: live critical view (де-эскалируемый вердикт детекторов) + session
max-severity latch. Детекторы крутятся в tick-loop на монотонном `elapsed`
(не `Date()`). Маппинг `cameraLost(scope)` из существующего
`.sourceRevoked`/`.allVideoSourcesLost`. Пост-стоп ветка по max-severity (2 текста).
session-level cap на live-уведомления.

### D — UI (после C)
`MenuBarLabel` — глиф `exclamationmark.octagon.fill` (различитель внутр.глиф+цвет);
`MenuBarLabelMapper` — hard-вид от live view + per-инцидент a11y-label (второй вход).
L2 на маппер (AC-11); grayscale-проверка в реальном размере.

### E — Notifications finish + entitlement (после A.5, C; P3)
Протокол/уровень-по-тиру/Fake уже в A.5; дедуп+session-cap — в C. Здесь остаётся:
actionable пост-стоп (action → reveal отчёта в Finder); capability Time Sensitive в
`Onset.entitlements` + обновить `scripts/check-entitlements.sh` (и проверить, что
`check-no-network.sh` остаётся зелёным).

### F — Docs
`docs/architecture.md` (новые типы + поток сигнала) и
`docs/quality/production-quality-bar.md` (критерии «пожара», пороги, L5-калибровка).

### G — Verification (L5, MX Brio)
`scripts/preflight.sh` зелёный; L5 на Brio: AC-1 (камера+экран отвал), AC-2
(камера-only отвал), AC-7 (затемнение не срабатывает / stall срабатывает), AC-12
(actionable пост-стоп), AC-13 (soft-сессия → мягкая нота). Перед L5: `pgrep -la
Onset`, signed build, один `xcodebuild test` за раз.

## Риски

- L5-калибровка порогов (AC-7) — главный риск; baseline+freeze+AND могут потребовать
  подстройки `fpsCollapseRatio`/`fpsCollapseGapMsThreshold` на реальной камере.
- Пульсация в MenuBarExtra label может не рендериться — fallback статичная форма+цвет
  (не блокер, AC-11 на статике).
- Контракт `flush` задевает 4 call-site + их тесты — аддитивно, но проверить L2.

## Источник верификации (acceptance)
Спека `docs/specs/critical-recording-signals-spec.md`, AC-1…AC-13 с L-тегами.
`/acceptance` сверяет реализацию против них; L2 — в `/check`, L5 — фаза G.
