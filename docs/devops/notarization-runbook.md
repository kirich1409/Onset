# Runbook: Developer ID подпись и нотаризация Onset

**Статус:** инфраструктура подготовлена, secrets не заданы. Workflow не выполняется без заполненных secrets.

---

## Предварительные условия

- Учётная запись Apple Developer Program ($99/год): https://developer.apple.com/programs/enroll/
- Права Team Agent или Admin в Apple Developer аккаунте.
- Xcode, установленный локально (для экспорта сертификата).

---

## Шаг 1 — Создать сертификат Developer ID Application

1. Открыть **Xcode → Settings → Accounts**, добавить Apple ID если не добавлен.
2. Нажать **Manage Certificates → "+" → Developer ID Application**.
   Xcode автоматически запросит сертификат через API Apple и поместит его в Keychain.
3. Проверить, что сертификат виден:
   ```
   security find-identity -v -p codesigning
   ```
   В списке должна быть строка вида:
   `Developer ID Application: Имя Фамилия (XXXXXXXXXX)`

   Где `XXXXXXXXXX` — ваш Team ID (10 символов). Его также можно найти на
   https://developer.apple.com/account → Membership → Team ID.

---

## Шаг 2 — Экспортировать сертификат в .p12

1. Открыть **Keychain Access** (приложение).
2. Найти сертификат **Developer ID Application: ...** в категории **My Certificates**.
3. Развернуть сертификат (стрелка), выделить оба объекта: сертификат + приватный ключ.
4. ПКМ → **Export 2 items** → формат **.p12** → задать надёжный пароль → сохранить файл.
5. Конвертировать в base64 (нужно для GitHub Secret):
   ```
   base64 -i DeveloperIDApplication.p12 | pbcopy
   ```
   Буфер обмена содержит значение для секрета `DEVELOPER_ID_CERT_P12`.

---

## Шаг 3 — Создать App Store Connect API Key

Нотаризация использует ASC API key (рекомендованный путь; не требует пароля от Apple ID).

1. Открыть https://appstoreconnect.apple.com/access/integrations/api
2. Нажать **Generate API Key** (тип: **Developer**).
   - **Key ID** — запомнить (10+ символов, например `ABCD123456`).
   - **Issuer ID** — отображается вверху страницы (UUID формат).
   - Скачать файл `.p8` (скачивается **один раз**; потерянный ключ нельзя восстановить).
3. Содержимое `.p8` файла (включая строки `-----BEGIN PRIVATE KEY-----`/`-----END PRIVATE KEY-----`) — значение для секрета `APP_STORE_CONNECT_PRIVATE_KEY`.

---

## Шаг 4 — Заполнить ExportOptions.plist

В файле `ExportOptions.plist` в корне репозитория заменить заглушку в поле `teamID`:

```xml
<key>teamID</key>
<string>XXXXXXXXXX</string>  <!-- заменить на ваш реальный Team ID -->
```

Commit это изменение. Workflow вставляет значение через `sed` из секрета `APPLE_TEAM_ID`,
поэтому в файле можно оставить заглушку — она перезаписывается в runtime.
Реальный Team ID в файле не нужен и не рекомендуется (он не секретный, но избыточен).

---

## Шаг 5 — Добавить GitHub Secrets в Environment "release"

Открыть: **GitHub repo → Settings → Environments → release → Environment secrets → Add secret**

> ⚠️ Secrets добавляются именно в **Environment "release"**, а не в разделе "Repository secrets".
> Workflow использует `environment: release` — только environment-scoped secrets доступны в этой джобе.

| Secret name                     | Значение                                                          |
|---------------------------------|-------------------------------------------------------------------|
| `APPLE_TEAM_ID`                 | Team ID, 10 символов (например `ABCDE12345`)                     |
| `DEVELOPER_ID_CERT_P12`         | base64-encoded содержимое `.p12` файла (из шага 2)               |
| `DEVELOPER_ID_CERT_PASSWORD`    | Пароль от `.p12` файла (из шага 2)                               |
| `APP_STORE_CONNECT_KEY_ID`      | Key ID из App Store Connect (из шага 3)                          |
| `APP_STORE_CONNECT_ISSUER_ID`   | Issuer ID из App Store Connect (UUID, из шага 3)                 |
| `APP_STORE_CONNECT_PRIVATE_KEY` | Содержимое `.p8` файла целиком, включая `BEGIN/END` строки       |

**Итого: 6 secrets.**

> Примечание: workflow был обновлён — используются имена секретов выше. Имена из закрытого
> issue #162 (`NOTARYTOOL_APPLE_ID`, `NOTARYTOOL_APP_SPECIFIC_PASSWORD`, `NOTARYTOOL_TEAM_ID`,
> `DEVELOPER_ID_APPLICATION_P12_BASE64`, `DEVELOPER_ID_APPLICATION_P12_PASSWORD`) устарели,
> их добавлять **не нужно**.

---

## Шаг 6 — Запустить первый релиз

```bash
git tag v0.1.0
git push origin v0.1.0
```

Workflow `release.yml` запускается автоматически на push тега `v*`.

Что происходит:
1. Проверяет наличие всех 6 secrets (при отсутствии — fail-fast с сообщением об ошибке).
2. Импортирует сертификат во временный keychain.
3. Собирает архив (`xcodebuild archive`, Release/WMO).
4. Экспортирует `.app` с подписью Developer ID Application + Hardened Runtime.
5. Нотаризирует `.app` через `xcrun notarytool` (ASC API key), ставит staple.
6. Создаёт DMG, нотаризирует и ставит staple **на DMG** (требуется для offline-установки).
7. Создаёт draft GitHub Release с вложениями `.dmg` и `.zip`.
8. Удаляет временный keychain.

Время выполнения: ~15–25 минут (включая ожидание нотаризации Apple).

---

## Шаг 7 — Smoke-test на чистой машине

Цель: убедиться, что Gatekeeper пропускает приложение без dev-сертификатов в keychain.

**На чистой машине или VM без установленных dev-сертификатов:**

1. Скачать DMG из GitHub Release (draft) или с Actions artifacts.
2. Смонтировать DMG и скопировать `.app` в `/Applications`.
3. Проверить подпись:
   ```
   codesign --verify --deep --strict --verbose=2 /Applications/Onset.app
   ```
   Ожидаемый результат: `valid on disk` / `satisfies its Designated Requirement`

4. Проверить нотаризацию:
   ```
   spctl --assess --type execute -vvv /Applications/Onset.app
   ```
   Ожидаемый результат:
   ```
   /Applications/Onset.app: accepted
   source=Notarized Developer ID
   ```

5. Открыть приложение двойным кликом — Gatekeeper должен пропустить без предупреждений.
6. Проверить entitlements в собранном `.app`:
   ```
   codesign -d --entitlements :- /Applications/Onset.app
   plutil -p Onset.app/Contents/Info.plist | grep -i Usage
   ```
   Должны присутствовать: `com.apple.security.device.camera`,
   `com.apple.security.device.audio-input`. App Sandbox (`com.apple.security.app-sandbox`) — отсутствует.

7. Запустить проверочные скрипты из репозитория:
   ```
   scripts/check-entitlements.sh /Applications/Onset.app
   scripts/check-no-network.sh /Applications/Onset.app
   scripts/check-privacy-manifest.sh
   ```

После успешного smoke-test: перевести GitHub Release из draft → published.

---

## Troubleshooting

**`::error::Signing secrets absent`** — не все 6 secrets добавлены в Environment "release".
Проверить: Settings → Environments → release → Environment secrets.

**`notarytool: Error: App Store Connect API key not found`** — значение `APP_STORE_CONNECT_PRIVATE_KEY`
должно включать строки `-----BEGIN PRIVATE KEY-----` и `-----END PRIVATE KEY-----`.

**`spctl: rejected` на чистой машине** — DMG или `.app` не прошёл staple. Убедиться,
что оба шага "Notarize DMG" и "Notarize app" завершились с `Accepted` в логах notarytool.

**Hardened Runtime** — включается автоматически xcodebuild для `developer-id` export при наличии
`ENABLE_HARDENED_RUNTIME = YES` в настройках проекта. Отдельный ключ в ExportOptions.plist
не требуется и не поддерживается.
