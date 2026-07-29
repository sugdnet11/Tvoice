#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR=/opt/tvoice-video
CREDENTIALS_FILE="$INSTALL_DIR/livekit-credentials.env"
PUBLIC_IP=185.177.2.115

install -d -m 0750 "$INSTALL_DIR"

if [[ ! -f "$CREDENTIALS_FILE" ]]; then
  api_key="tvoice_$(openssl rand -hex 8)"
  api_secret="$(openssl rand -hex 32)"
  umask 077
  printf 'LIVEKIT_API_KEY=%s\nLIVEKIT_API_SECRET=%s\n' "$api_key" "$api_secret" > "$CREDENTIALS_FILE"
fi

# shellcheck disable=SC1090
source "$CREDENTIALS_FILE"

cat > "$INSTALL_DIR/livekit.yaml" <<EOF
port: 7880
rtc:
  # Public TCP 8091 is DNATed to port 80 on the chat VM, which relays here.
  tcp_port: 8091
  # Public UDP 443 is relayed by the chat VM and avoids TCP head-of-line delay.
  udp_port: 443
  use_external_ip: false
  node_ip: ${PUBLIC_IP}
  congestion_control:
    enabled: true
    allow_pause: true
keys:
  ${LIVEKIT_API_KEY}: ${LIVEKIT_API_SECRET}
logging:
  level: info
  pion_level: error
room:
  auto_create: true
  empty_timeout: 300
  departure_timeout: 20
  max_participants: 2
  sync_streams: true
  enabled_codecs:
    - mime: audio/opus
    - mime: audio/red
    - mime: video/vp8
    - mime: video/h264
EOF
chmod 0600 "$INSTALL_DIR/livekit.yaml" "$CREDENTIALS_FILE"

cat > "$INSTALL_DIR/docker-compose.yml" <<'EOF'
version: "3.8"
services:
  livekit:
    image: livekit/livekit-server:v1.13.1
    container_name: tvoice-livekit
    command: --config /etc/livekit.yaml
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./livekit.yaml:/etc/livekit.yaml:ro
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

cd "$INSTALL_DIR"
docker-compose pull
docker-compose up -d

for attempt in $(seq 1 30); do
  if wget -q -O /dev/null http://127.0.0.1:7880/; then
    break
  fi
  if [[ "$attempt" -eq 30 ]]; then
    docker-compose logs --tail=100 livekit
    exit 1
  fi
  sleep 1
done

install -o farid -g farid -m 0600 "$CREDENTIALS_FILE" /home/farid/livekit-credentials.env
docker-compose ps
