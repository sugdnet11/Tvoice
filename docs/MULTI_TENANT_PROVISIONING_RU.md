# Multi-tenant provisioning Tvoice

## Пользовательский сценарий

Пользователь выбирает компанию по коду или ссылке вида
`tvoice://company?code=COMPANY01`, затем один раз вводит SIP-логин и пароль.
Backend компании проверяет эти данные. После успешной проверки Tvoice выдаёт
собственный tenant-scoped JWT для чата и видеосвязи и возвращает SIP-профиль.

## Границы безопасности

- SIP-пароль передаётся только по TLS между приложением, Tvoice и webhook компании.
- Пароль не записывается в PostgreSQL Tvoice.
- Секрет webhook шифруется AES-256-GCM ключом `TENANT_SECRETS_KEY`.
- JWT содержит `tenantId`; поиск контактов и абонентов ограничен этим tenant.
- LiveKit identity включает `tenantId`, поэтому одинаковые номера разных компаний не конфликтуют.
- Компания импортирует только номер, отображаемое имя и активность абонента.

## API

- `GET /v1/tenants/:code` — публичный профиль компании без секретов.
- `POST /v1/auth/login` — единый вход с `tenantCode`, `sipNumber`, `password`.
- `POST /v1/admin/tenants` — создание компании оператором Tvoice.
- `GET /v1/partner/tenant` — профиль для партнёрского портала.
- `PUT /v1/partner/directory` — идемпотентная синхронизация каталога.

Заголовки партнёрского API: `x-tenant-code` и `x-tenant-key`.
