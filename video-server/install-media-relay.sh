#!/bin/sh
set -eu

# The edge router maps public :8091 to :80 on the chat VM. Caddy only needs
# :443 in production, so :80 is a raw TCP relay to the dedicated video VM.
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends socat

cat >/etc/systemd/system/tvoice-livekit-tcp-relay.service <<'EOF'
[Unit]
Description=Tvoice LiveKit TCP media relay
After=network-online.target docker.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:80,reuseaddr,fork TCP:10.10.10.8:8091
Restart=always
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/tvoice-livekit-udp-relay.service <<'EOF'
[Unit]
Description=Tvoice LiveKit UDP media relay
After=network-online.target docker.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/socat UDP4-RECVFROM:443,reuseaddr,fork UDP4-SENDTO:10.10.10.8:443
Restart=always
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now tvoice-livekit-tcp-relay.service
systemctl enable --now tvoice-livekit-udp-relay.service
systemctl --no-pager --full status tvoice-livekit-tcp-relay.service
systemctl --no-pager --full status tvoice-livekit-udp-relay.service
