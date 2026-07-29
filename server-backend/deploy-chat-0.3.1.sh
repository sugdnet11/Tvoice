#!/bin/sh
set -eu

APP_DIR=/opt/tvoice-chat
ARCHIVE=/home/farid/tvoice-chat-0.3.1-deploy.tar.gz
BACKUP_DIR=/var/backups/tvoice-chat
SOURCE_BACKUP="$BACKUP_DIR/source-pre-0.3.1-20260728.tar.gz"

test -d "$APP_DIR"
test -f "$ARCHIVE"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
tar -C /opt -czf "$SOURCE_BACKUP" tvoice-chat
test -s "$SOURCE_BACKUP"
chmod 600 "$SOURCE_BACKUP"

docker tag tvoice-chat-chat:latest tvoice-chat-chat:pre-0.3.1
tar -xzf "$ARCHIVE" -C "$APP_DIR"
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
  docker tag tvoice-chat-chat:pre-0.3.1 tvoice-chat-chat:latest
  docker compose up -d --no-deps --force-recreate chat
  echo "Deployment failed health check; previous image restored." >&2
  exit 1
fi

cat /tmp/tvoice-chat-health.json
echo
docker compose ps chat
