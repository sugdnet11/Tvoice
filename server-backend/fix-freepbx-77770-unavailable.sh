#!/bin/sh
set -eu

AOR_FILE=/etc/asterisk/pjsip.aor.conf
CUSTOM_FILE=/etc/asterisk/pjsip.aor_custom_post.conf
BACKUP_DIR=/var/backups/tvoice-freepbx-aor

if /usr/sbin/asterisk -rx 'core show channels count' | grep -Eq '[1-9][0-9]* active call'; then
  echo 'Active call detected; refusing to reload Asterisk configuration.' >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
mysqldump asterisk sip --where="id='77770' AND keyword='qualifyfreq'" > "$BACKUP_DIR/sip-77770-qualify-pre-tvoice-20260728.sql"
cp -a "$AOR_FILE" "$BACKUP_DIR/pjsip.aor-pre-tvoice-20260728.conf"
chmod 600 "$BACKUP_DIR/sip-77770-qualify-pre-tvoice-20260728.sql" "$BACKUP_DIR/pjsip.aor-pre-tvoice-20260728.conf"

mysql -e "UPDATE asterisk.sip SET data = '0' WHERE id = '77770' AND keyword = 'qualifyfreq'"

set +e
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  /var/lib/asterisk/bin/fwconsole reload --dont-reload-asterisk >/tmp/tvoice-fwconsole-reload.log 2>&1
set -e

if ! awk '
  /^\[77770\]$/ { target=1; next }
  target && /^\[/ { target=0 }
  target && /^qualify_frequency=0$/ { found=1 }
  END { exit(found ? 0 : 1) }
' "$AOR_FILE"; then
  awk '
    /^\[77770\]$/ { target=1 }
    target && /^\[/ && $0 != "[77770]" { target=0 }
    target && /^qualify_frequency=/ { $0="qualify_frequency=0" }
    { print }
  ' "$AOR_FILE" > "$AOR_FILE.next"
  chmod --reference="$AOR_FILE" "$AOR_FILE.next"
  chown --reference="$AOR_FILE" "$AOR_FILE.next"
  mv "$AOR_FILE.next" "$AOR_FILE"
fi

if [ -f "$BACKUP_DIR/pjsip.aor_custom_post-pre-tvoice-20260728.conf" ]; then
  cp -a "$BACKUP_DIR/pjsip.aor_custom_post-pre-tvoice-20260728.conf" "$CUSTOM_FILE"
fi

/usr/sbin/asterisk -rx 'module reload res_pjsip.so'
sleep 3
/usr/sbin/asterisk -rx 'pjsip show aor 77770'
