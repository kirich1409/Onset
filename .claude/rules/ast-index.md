# ast-index Rules

> **Платформа проекта — macOS** (Swift, AppKit/SwiftUI). В ast-index нет отдельного типа `macos`: тип `ios` — это общий **Swift/ObjC**-индексатор, он же корректен для macOS. `ast-index stats` показывает «iOS (Swift/ObjC)» — это про язык, не про платформу таргета. При rebuild использовать `--project-type ios` (или автодетект).

## Mandatory Search Rules

1. **ALWAYS use ast-index FIRST** for any code search task
2. **NEVER duplicate results** — if ast-index found usages/implementations, that IS the complete answer
3. **DO NOT run grep "for completeness"** after ast-index returns results
4. **Use grep/Search ONLY when:**
   - ast-index returns empty results
   - Searching for regex patterns (ast-index uses literal match)
   - Searching for string literals inside code (`"some text"`)
   - Searching in comments content

## Why ast-index

ast-index is 17-69x faster than grep (1-10ms vs 200ms-3s) and returns structured, accurate results.

## Command Reference

| Task | Command | Time |
|------|---------|------|
| Universal search | `ast-index search "query"` | ~10ms |
| Find class/protocol | `ast-index class "ClassName"` | ~1ms |
| Find usages | `ast-index usages "SymbolName"` | ~8ms |
| Find conformances | `ast-index implementations "Protocol"` | ~5ms |
| Call hierarchy | `ast-index call-tree "function" --depth 3` | ~1s |
| Class hierarchy | `ast-index hierarchy "ClassName"` | ~5ms |
| Find callers | `ast-index callers "functionName"` | ~1s |
| Module deps | `ast-index deps "ModuleName"` | ~10ms |
| File outline | `ast-index outline "File.swift"` | ~1ms |

## iOS-Specific Commands

| Task | Command |
|------|---------|
| SwiftUI views | `ast-index swiftui` |
| Async functions | `ast-index async-funcs` |
| @MainActor | `ast-index main-actor` |
| Combine publishers | `ast-index publishers` |
| Storyboard usages | `ast-index storyboard-usages "Class"` |
| Asset usages | `ast-index asset-usages "name"` |

## Index Management

- `ast-index rebuild` — Full reindex (run once after clone)
- `ast-index update` — After git pull/merge
- `ast-index stats` — Show index statistics
