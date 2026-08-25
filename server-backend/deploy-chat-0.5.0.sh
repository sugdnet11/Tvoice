#!/bin/sh
set -eu

APP_DIR=/opt/tvoice-chat
ARCHIVE=/home/farid/tvoice-chat-0.5.0-deploy.tar.gz
BACKUP_DIR=/var/backups/tvoice-chat
STAMP=$(date +%Y%m%d-%H%M%S)
SOURCE_BACKUP="$BACKUP_DIR/source-pre-0.5.0-$STAMP.tar.gz"
DATABASE_BACKUP="$BACKUP_DIR/database-pre-0.5.0-$STAMP.sql.gz"

test "$(id -u)" -eq 0
test -d "$APP_DIR"
test -f "$ARCHIVE"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

tar -C /opt -czf "$SOURCE_BACKUP" tvoice-chat
docker exec tvoice-chat-postgres-1 pg_dump -U tvoice tvoice_chat | gzip -9 > "$DATABASE_BACKUP"
test -s "$SOURCE_BACKUP"
test -s "$DATABASE_BACKUP"
chmod 600 "$SOURCE_BACKUP" "$DATABASE_BACKUP"

docker tag tvoice-chat-chat:latest tvoice-chat-chat:pre-0.5.0
tar -xzf "$ARCHIVE" -C "$APP_DIR"
cd "$APP_DIR"
docker compose config >/dev/null
docker compose build chat
docker compose up -d --no-deps chat

healthy=false
attempt=0
while [ "$attempt" -lt 45 ]; do
  if docker exec tvoice-chat-chat-1 node -e 'fetch("http://127.0.0.1:8080/health").then(async response => { const body = await response.json(); if (!response.ok || body.version !== "0.5.0" || body.video !== "ready") process.exit(1); console.log(JSON.stringify(body)); }).catch(() => process.exit(1));' > /tmp/tvoice-chat-health.json 2>/dev/null; then
    healthy=true
    break
  fi
  attempt=$((attempt + 1))
  sleep 2
done

if [ "$healthy" != true ]; then
  docker tag tvoice-chat-chat:pre-0.5.0 tvoice-chat-chat:latest
  docker compose up -d --no-deps --force-recreate chat
  echo "Deployment failed health check; previous chat image restored." >&2
  exit 1
fi

cat /tmp/tvoice-chat-health.json
echo
docker compose ps chat caddy postgres
echo "Backups: $SOURCE_BACKUP $DATABASE_BACKUP"
