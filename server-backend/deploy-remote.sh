#!/bin/sh
set -eu

APP_DIR=/opt/tvoice-chat
ARCHIVE=/home/farid/tvoice-chat-0.3.0-deploy.tar.gz
KEY_TRANSFER=/home/farid/tvoice-auth.key-transfer
BACKUP_DIR=/var/backups/tvoice-chat
SOURCE_BACKUP="$BACKUP_DIR/source-pre-0.3.0-20260728.tar.gz"
DATABASE_BACKUP="$BACKUP_DIR/database-pre-0.3.0-20260728.dump"
ENV_BACKUP="$BACKUP_DIR/env-pre-0.3.0-20260728"

test -d "$APP_DIR"
test -f "$ARCHIVE"
test -s "$KEY_TRANSFER"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

tar -C /opt -czf "$SOURCE_BACKUP" tvoice-chat
docker exec tvoice-chat-postgres-1 pg_dump -U tvoice -d tvoice_chat -Fc > "$DATABASE_BACKUP"
install -m 0600 "$APP_DIR/.env" "$ENV_BACKUP"
test -s "$SOURCE_BACKUP"
test -s "$DATABASE_BACKUP"
chmod 600 "$SOURCE_BACKUP" "$DATABASE_BACKUP" "$ENV_BACKUP"

docker tag tvoice-chat-chat:latest tvoice-chat-chat:pre-0.3.0
tar -xzf "$ARCHIVE" -C "$APP_DIR"
docker exec -i tvoice-chat-postgres-1 psql -v ON_ERROR_STOP=1 -U tvoice -d tvoice_chat < "$APP_DIR/db/002_delivery_receipts.sql"
docker exec -i tvoice-chat-postgres-1 psql -v ON_ERROR_STOP=1 -U tvoice -d tvoice_chat < "$APP_DIR/db/003_freepbx_auth.sql"

grep -v '^FREEPBX_AUTH_URL=' "$APP_DIR/.env" | grep -v '^FREEPBX_API_KEY=' > "$APP_DIR/.env.next"
printf 'FREEPBX_AUTH_URL=http://10.10.10.2/tvoice-api/index.php\n' >> "$APP_DIR/.env.next"
printf 'FREEPBX_API_KEY=%s\n' "$(cat "$KEY_TRANSFER")" >> "$APP_DIR/.env.next"
chmod --reference="$APP_DIR/.env" "$APP_DIR/.env.next"
chown --reference="$APP_DIR/.env" "$APP_DIR/.env.next"
mv "$APP_DIR/.env.next" "$APP_DIR/.env"

cd "$APP_DIR"
docker compose build chat
docker compose up -d --no-deps chat

healthy=false
attempt=0
while [ "$attempt" -lt 20 ]; do
  if docker exec tvoice-chat-chat-1 node -e 'fetch("http://127.0.0.1:8080/health").then(async response => { if (!response.ok) process.exit(1); console.log(await response.text()); }).catch(() => process.exit(1));' >/tmp/tvoice-chat-health.json; then
    healthy=true
    break
  fi
  attempt=$((attempt + 1))
  sleep 2
done

if [ "$healthy" != true ]; then
  docker tag tvoice-chat-chat:pre-0.3.0 tvoice-chat-chat:latest
  install -m 0600 "$ENV_BACKUP" "$APP_DIR/.env"
  docker compose up -d --no-deps --force-recreate chat
  echo "Deployment failed health check; previous image restored." >&2
  exit 1
fi

cat /tmp/tvoice-chat-health.json
echo
rm -f "$KEY_TRANSFER"
docker compose ps chat
