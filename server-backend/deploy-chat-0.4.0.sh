#!/bin/sh
set -eu

APP_DIR=/opt/tvoice-chat
ARCHIVE=/home/farid/tvoice-chat-0.4.0-deploy.tar.gz
CREDENTIALS=/home/farid/livekit-credentials.env
BACKUP_DIR=/var/backups/tvoice-chat
SOURCE_BACKUP="$BACKUP_DIR/source-pre-0.4.0-20260728.tar.gz"

test -d "$APP_DIR"
test -f "$ARCHIVE"
test -f "$CREDENTIALS"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
tar -C /opt -czf "$SOURCE_BACKUP" tvoice-chat
test -s "$SOURCE_BACKUP"
chmod 600 "$SOURCE_BACKUP"

# shellcheck disable=SC1090
. "$CREDENTIALS"
test -n "$LIVEKIT_API_KEY"
test -n "$LIVEKIT_API_SECRET"

docker tag tvoice-chat-chat:latest tvoice-chat-chat:pre-0.4.0
tar -xzf "$ARCHIVE" -C "$APP_DIR"

set_env() {
  key="$1"
  value="$2"
  if grep -q "^${key}=" "$APP_DIR/.env"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$APP_DIR/.env"
  else
    printf '%s=%s\n' "$key" "$value" >> "$APP_DIR/.env"
  fi
}

set_env LIVEKIT_API_KEY "$LIVEKIT_API_KEY"
set_env LIVEKIT_API_SECRET "$LIVEKIT_API_SECRET"
set_env LIVEKIT_WS_URL "wss://video.185-177-2-115.sslip.io"
set_env VIDEO_HOST "video.185-177-2-115.sslip.io"
chmod 600 "$APP_DIR/.env"

cd "$APP_DIR"
docker compose config >/dev/null
docker compose build chat
docker compose up -d --no-deps chat
docker compose up -d --no-deps --force-recreate caddy

healthy=false
attempt=0
while [ "$attempt" -lt 30 ]; do
  if docker exec tvoice-chat-chat-1 node -e 'fetch("http://127.0.0.1:8080/health").then(async response => { if (!response.ok) process.exit(1); const body = await response.json(); if (body.version !== "0.4.0" || body.video !== "ready") process.exit(1); console.log(JSON.stringify(body)); }).catch(() => process.exit(1));' >/tmp/tvoice-chat-health.json; then
    healthy=true
    break
  fi
  attempt=$((attempt + 1))
  sleep 2
done

if [ "$healthy" != true ]; then
  docker tag tvoice-chat-chat:pre-0.4.0 tvoice-chat-chat:latest
  docker compose up -d --no-deps --force-recreate chat
  echo "Deployment failed health check; previous chat image restored." >&2
  exit 1
fi

cat /tmp/tvoice-chat-health.json
echo
docker compose ps chat caddy
