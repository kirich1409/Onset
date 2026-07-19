---
type: progress
slug: recording-backend-selection
---

# Progress: recording-backend-selection

## Tasks
- [x] T-1 — Типы выбора бэкенда
- [x] T-2 — Pure-резолвер + L2-тесты
- [x] T-3 — Persisted store + L2-тесты
- [x] T-4 — Проводка в RecordingSession + composition root
- [x] T-5 — Документация

## Learnings
(по одной строке на завершённую задачу)
- T-1: типы + ключи созданы, pbxproj авто-синхронизирован (PBXFileSystemSynchronizedRootGroup), L0 build зелёный, swiftformat/swiftlint чисто.
- T-2: RecordingBackendResolver (nonisolated enum) + SupportedBackends (Bool-per-stage) + 4 теста (nil/unknown/unsupported/happy). L2 зелёный (838 tests).
- T-3: BackendSelectionPersisting + UserDefaultsBackendSelectionStore (зеркало DeviceSelectionStore, один JSON-ключ) + 3 теста (round-trip/clear/corrupt). L2 зелёный.
- T-4: RecordingSession.init получил writerFactoryBuilder (3-звенная precedence), composition root резолвит в start() и строит фабрики из resolved. Деформации от плана: store вводится как factory-closure `makeBackendStore` (а не property `backendStore`) — обходит eager-конструкцию под XCTest-guard; writer-wiring тесты переименованы (writerFactory_winsOverBuilder_whenBothProvided / writerFactoryBuilder_receivesSessionDirRootedURLProvider). Закоммиченный T-4 сначала игнорировал resolved (dead-code) — пофикшено и вложено в коммит 9b24361. L0+L2 зелёные (840 tests).
- T-5: docs/architecture.md — подраздел backend-selection seam; privacy-manifest зелёный без правок (CA92.1 покрывает onset.backend.selection). Коммиты: 5bedccc/9b24361/bd2ed55.
- ВНЕ скоупа фичи: preflight.sh даёт ложные wrapAttributes (использует `--config .swiftformat` вопреки CLAUDE.md «do NOT add --config»); CI-точная `swiftformat --lint .` = 0/152 чисто. Пред-существующий баг тулинга → отдельный chore/meta-PR.
