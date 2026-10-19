# Tvoice Chat Server

Собственный сервер текстового чата для абонентов Tvoice.

## Состав

- Node.js 22 + TypeScript
- Fastify REST API и WebSocket
- PostgreSQL 17
- JWT-авторизация
- единая проверка SIP-пароля через закрытый FreePBX bridge
- Caddy для HTTPS/WSS
- Docker Compose
- вложения до 20 МБ в отдельном Docker volume
- сигналинг видеозвонков для собственного LiveKit
- multi-tenant изоляция компаний, пользователей, чатов и видеовызовов
- provisioning компаний по коду и партнёрский каталог абонентов

## Безопасность

- PostgreSQL не публикуется наружу.
- API доступен только через Caddy.
- `JWT_SECRET`, `ADMIN_KEY` и пароль БД хранятся только в `.env`.
- FreePBX является источником номера, имени и статуса пользователя.
- Открытые SIP-пароли в PostgreSQL чата не сохраняются.
- Скачать вложение может только участник соответствующего диалога.

## Подготовка

```bash
cp .env.example .env
chmod 600 .env
```

Сгенерируйте четыре независимых секрета:

```bash
openssl rand -hex 32
openssl rand -hex 48
openssl rand -hex 32
openssl rand -hex 32
```

Укажите их соответственно в `POSTGRES_PASSWORD`, `JWT_SECRET`, `ADMIN_KEY` и
`FREEPBX_API_KEY`. Последний ключ должен совпадать с `/etc/tvoice-auth.key` на FreePBX.
Такой же пароль БД необходимо подставить внутрь `DATABASE_URL`.

## Запуск

В текущей production-схеме TCP 443 направлен на Caddy чат-машины
`10.10.10.6`. Веб-панель FreePBX доступна отдельно через публичный TCP 8445,
а медиапорты LiveKit идут напрямую на `10.10.10.8`. Актуальные постоянные
правила находятся в `infrastructure/proxmox/tvoice-nat.sh`.

Запуск выполняется так:

```bash
docker compose up -d --build
docker compose ps
curl http://127.0.0.1/health
```

Публичный HTTPS должен быть включён до подключения мобильных клиентов.

Версия `0.5.0` автоматически создаёт таблицу вложений при старте. Для ручного
применения той же миграции используйте `db/004_attachments.sql`.

## Синхронизация пользователей

При включённых `FREEPBX_AUTH_URL` и `FREEPBX_API_KEY` каталог загружается при старте,
каждые пять минут и после успешного входа. Ручное создание пользователя не требуется.

## Подключение других компаний

1. Администратор Tvoice создаёт tenant через `POST /v1/admin/tenants`.
2. API возвращает одноразово `partnerKey`; его нужно передать компании безопасным каналом.
3. Компания входит на `/partner`, проверяет SIP-профиль и синхронизирует каталог без паролей.
4. Пользователь вводит код компании и свои обычные SIP-данные в приложении.
5. Tvoice проверяет пароль через webhook компании, после чего автоматически выдаёт токены чата и LiveKit.

Для webhook-компаний задайте `TENANT_SECRETS_KEY` как 64 шестнадцатеричных
символа (`openssl rand -hex 32`). Секрет webhook хранится в PostgreSQL только в
зашифрованном AES-256-GCM виде. Пароли SIP-пользователей в Tvoice не сохраняются.

Публичные служебные страницы backend:

- `/partner` — защищённый ключом портал компании;
- `/privacy` — политика конфиденциальности для Google Play;
- `/data-deletion` — порядок запроса удаления пользовательских данных.

Для существующей компании новый ключ портала создаётся запросом
`POST /v1/admin/tenants/:code/rotate-partner-key`. Предыдущий ключ после этого
сразу перестаёт действовать.

Пример создания компании:

```bash
curl -X POST http://127.0.0.1:8080/v1/admin/tenants \
  -H "x-admin-key: $ADMIN_KEY" -H "content-type: application/json" \
  -d '{
    "code":"COMPANY01","slug":"company-01","name":"Компания 01",
    "sip":{"host":"sip.company.example","port":5060,"transport":"udp"},
    "auth":{"type":"webhook","url":"https://company.example/tvoice/auth","sharedSecret":"CHANGE_TO_32_CHAR_SECRET_OR_LONGER"}
  }'
```

Webhook компании принимает `tenantCode`, `sipNumber`, `password` и при успешной
проверке возвращает:

```json
{"user":{"sipNumber":"75566","displayName":"Фарид Усманов"}}
```

## Проверка входа

```bash
curl -fsS http://127.0.0.1/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"sipNumber":"73302","password":"CHANGE_ME"}'
```

## Production HTTPS

После проверки переключите в `.env`:

```dotenv
CADDYFILE=./deploy/caddy/Caddyfile.production
CHAT_HOST=chat.185-177-2-115.sslip.io
PBX_HOST=pbx.185-177-2-115.sslip.io
ACME_EMAIL=ваш_email
```

Затем направьте публичные TCP 80/443 на `10.10.10.6`. Caddy будет обслуживать:

- `https://chat.185-177-2-115.sslip.io` → Tvoice Chat;
- `https://pbx.185-177-2-115.sslip.io` → FreePBX `10.10.10.2`.

Перед переключением обязательно сохраните правила NAT и протестируйте
конфигурацию Caddy.

## Резервное копирование

```bash
docker compose exec -T postgres \
  pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip \
  > "tvoice-chat-$(date +%F).sql.gz"
```
