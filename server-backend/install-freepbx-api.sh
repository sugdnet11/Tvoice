#!/bin/sh
set -eu

SOURCE=/home/farid/tvoice-freepbx-api.php
TARGET_DIR=/var/www/html/tvoice-api
TARGET="$TARGET_DIR/index.php"
KEY=/etc/tvoice-auth.key
BACKUP_DIR=/var/backups/tvoice-freepbx-api

test -f "$SOURCE"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
if [ -f "$TARGET" ]; then
  cp -a "$TARGET" "$BACKUP_DIR/index-pre-0.1.0-20260728.php"
  chmod 600 "$BACKUP_DIR/index-pre-0.1.0-20260728.php"
fi

install -d -o asterisk -g asterisk -m 0750 "$TARGET_DIR"
install -o root -g asterisk -m 0640 "$SOURCE" "$TARGET"
if [ ! -s "$KEY" ]; then
  umask 077
  openssl rand -hex 48 > "$KEY"
fi
chown root:asterisk "$KEY"
chmod 0640 "$KEY"

php -l "$TARGET"

authorization="X-Tvoice-Key: $(cat "$KEY")"
users_status=$(curl -sS -o /tmp/tvoice-freepbx-users.json -w '%{http_code}' -H "$authorization" 'http://127.0.0.1/tvoice-api/index.php?action=users')
users_count=$(php -r '$v=json_decode(file_get_contents($argv[1]), true); echo is_array($v["users"] ?? null) ? count($v["users"]) : -1;' /tmp/tvoice-freepbx-users.json)
echo "users_http=$users_status users=$users_count"
if [ "$users_status" != 200 ]; then
  cat /tmp/tvoice-freepbx-users.json
  echo
fi
test "$users_status" = 200
test "$users_count" -gt 0

sip_secret=$(mysql -NBe "SELECT data FROM asterisk.sip WHERE id = '73302' AND keyword = 'secret' LIMIT 1")
test -n "$sip_secret"
payload=$(php -r 'echo json_encode(["sipNumber" => $argv[1], "password" => $argv[2]], JSON_UNESCAPED_UNICODE);' 73302 "$sip_secret")
auth_status=$(curl -sS -o /tmp/tvoice-freepbx-auth.json -w '%{http_code}' -H "$authorization" -H 'Content-Type: application/json' --data "$payload" 'http://127.0.0.1/tvoice-api/index.php?action=auth')
wrong_status=$(curl -sS -o /tmp/tvoice-freepbx-wrong.json -w '%{http_code}' -H "$authorization" -H 'Content-Type: application/json' --data '{"sipNumber":"73302","password":"definitely-wrong"}' 'http://127.0.0.1/tvoice-api/index.php?action=auth')
test "$auth_status" = 200
test "$wrong_status" = 401

echo "users=$users_count users_http=$users_status auth_http=$auth_status wrong_password_http=$wrong_status"
