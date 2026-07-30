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

## Безопасность

- PostgreSQL не публикуется наружу.
- API доступен только через Caddy.
- `JWT_SECRET`, `ADMIN_KEY` и пароль БД хранятся только в `.env`.
- FreePBX является источником номера, имени и статуса пользователя.
- Открытые SIP-пароли в PostgreSQL чата не сохраняются.

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

## Синхронизация пользователей

При включённых `FREEPBX_AUTH_URL` и `FREEPBX_API_KEY` каталог загружается при старте,
каждые пять минут и после успешного входа. Ручное создание пользователя не требуется.

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
