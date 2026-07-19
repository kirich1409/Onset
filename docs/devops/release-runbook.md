# Runbook: Ad-hoc релиз Onset

**Статус:** активен. Не требует платного Apple Developer аккаунта.

Этот runbook описывает выпуск **ad-hoc-подписанной** (без нотаризации) сборки для
раздачи тестерам. Для будущего **нотаризованного** релиза (Developer ID) см.
[`notarization-runbook.md`](notarization-runbook.md).

---

## Два пути релиза

| | Ad-hoc (сейчас) | Нотаризованный (позже) |
|---|---|---|
| Workflow | `.github/workflows/release-adhoc.yml` | `.github/workflows/release.yml` |
| Триггер | `workflow_dispatch` (ручной, по кнопке) | `push` тега `v*` |
| Подпись | ad-hoc (`codesign --sign -`) | Developer ID Application |
| Нотаризация | нет | да (`xcrun notarytool`) |
| Apple-аккаунт | не нужен | платный ($99/год) + 6 secrets |
| Gatekeeper у тестера | требует ручной «Open Anyway» | пропускает без предупреждений |

Workflow `release-adhoc.yml` создаёт тег `v<version>` сам, через `gh release create`
с `GITHUB_TOKEN`. События от `GITHUB_TOKEN` **не запускают** другие workflow, поэтому
этот тег **не** ретриггерит `release.yml` — два пути не пересекаются.

---

## Как выпустить ad-hoc релиз

1. GitHub → вкладка **Actions** → workflow **«Release (ad-hoc)»**.
2. Нажать **Run workflow**.
3. В поле **version** ввести версию в формате semver `X.Y.Z` (например `0.1.0`).
   Текущая версия проекта — `MARKETING_VERSION` в `Onset.xcodeproj/project.pbxproj`.
4. **Run workflow**.

Дождаться завершения (~5–10 минут). Результат — **draft** GitHub Release с тегом
`v<version>`, к которому приложены `Onset-<version>.dmg` и `Onset-<version>.zip`.

После проверки сборки тестерами перевести Release из draft → published вручную.

---

## Что делает workflow

**Job `build` (раннер `macos-26`, таймаут 30 мин):**

1. Валидирует введённую версию по регулярке semver `X.Y.Z` — некорректный ввод
   проваливает прогон за секунды, до сборки.
2. Проверяет наличие Xcode 26.5 на раннере (fail-fast при ротации образа).
3. Собирает Release-конфигурацию **без подписи** (`CODE_SIGNING_ALLOWED=NO`),
   передавая `CURRENT_PROJECT_VERSION` и `MARKETING_VERSION` из введённой версии.
   Вывод `.app` детерминирован через `-derivedDataPath` →
   `Build/Products/Release/Onset.app`. Сборка только под arm64 (`ONLY_ACTIVE_ARCH=YES`)
   — проект Apple-Silicon-only.
4. **Ad-hoc-подписывает** готовый `.app`:
   `codesign --force --deep --sign - <Onset.app>`, печатает `codesign -dvv` и
   проверяет подпись `codesign --verify --strict`.
5. Упаковывает `Onset-<version>.dmg` (`hdiutil create … -format UDZO`) и
   `Onset-<version>.zip` (`ditto -c -k --keepParent`).
6. Выкладывает оба файла как артефакт прогона (retention 1 день).

**Job `create-release` (раннер `ubuntu-latest`, таймаут 10 мин, `contents: write`):**

1. Скачивает артефакты сборки (checkout исходников не нужен — всё через `gh` API).
2. Генерирует релиз-ноуты средствами GitHub (см. ниже).
3. Создаёт **draft** Release: `gh release create "v<version>" --draft --notes-file …`
   с вложениями `.dmg` и `.zip`.

---

## Релиз-ноуты: авто-генерация GitHub

Релиз-ноуты генерируются **бесплатно средствами самого GitHub** — без AI и без
API-ключа. Используется REST-эндпоинт `POST repos/.../releases/generate-notes`
(через `gh api`), который возвращает авто-ноуты как **текст**, не создавая релиз.
GitHub сам определяет диапазон (предыдущий релиз → целевой commit) и формирует
список изменений со ссылками на PR.

- В конец тела релиза **всегда** дописывается блок инструкции для тестеров (см.
  ниже). Тело собирается в один файл `notes.md`, релиз создаётся одним вызовом
  `gh release create --notes-file`.
- Ноуты — косметика: если `generate-notes` упадёт, в лог пишется `::warning::`, а
  релиз создаётся с минимальным телом (только блок установки). Из-за текста ноутов
  весь workflow не падает; тихого пропуска нет.

---

## Инструкция для тестеров (ad-hoc сборка)

Этот блок автоматически добавляется в тело каждого ad-hoc Release. Приводится здесь
для справки:

> ## Установка (ad-hoc сборка)
> Это ad-hoc-подписанная сборка без нотаризации. При первом запуске macOS заблокирует
> приложение. Чтобы открыть:
> System Settings → Privacy & Security → найдите сообщение про «Onset» → нажмите «Open Anyway».
> (ПКМ→Открыть на macOS 26 больше не обходит Gatekeeper.)
> Примечание: при ad-hoc-подписи разрешение на запись экрана (Screen Recording) нужно
> выдавать заново после каждой новой сборки.

Почему Screen Recording приходится выдавать заново: TCC привязывает разрешение к
подписи приложения. У ad-hoc-подписи нет стабильной идентичности (Team ID), поэтому
каждая новая сборка для системы — «другое» приложение, и ранее выданное разрешение
к ней не применяется. Нотаризованный Developer ID путь эту проблему снимает —
идентичность стабильна между сборками.

---

## Какие secrets нужны

**Для ad-hoc релиза secrets не нужны вообще** — workflow использует только
автоматический `${{ github.token }}` (доступен без настройки).

| Secret | Когда нужен | Назначение |
|---|---|---|
| Apple-секреты (6 шт.) | только для будущего нотаризованного пути | Developer ID + App Store Connect; см. [`notarization-runbook.md`](notarization-runbook.md) |

Apple-секреты для ad-hoc пути **не нужны** — они относятся исключительно к
нотаризованному пути (`release.yml`).

---

## Верификация workflow

Workflow нельзя выполнить локально. Синтаксис провалидирован `actionlint`.
Реальная проверка пути — **первый ручной `workflow_dispatch`-прогон после merge**:
запустить «Release (ad-hoc)» с тестовой версией, убедиться, что появился draft
Release с приложенными `.dmg`/`.zip` и корректным телом (ноуты + блок установки).
