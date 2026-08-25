# Tvoice LiveKit server

The production media server runs on the dedicated Debian VM `10.10.10.8`.
Signalling is proxied by the chat server Caddy as
`wss://video.185-177-2-115.sslip.io`; WebRTC media goes directly to the
public address mapped to the VM.

Current direct media path:

- public TCP `8091` -> `10.10.10.8:8091`
- public UDP `443` -> `10.10.10.8:443`

The direct DNAT is required. Relaying ICE through the chat VM changes the peer
address and caused calls to connect without audio or remote video.


The LiveKit API key and secret live only in `/opt/tvoice-video` and in the
chat backend environment. They must never be embedded in the Android app.

Operational checks:

```bash
cd /opt/tvoice-video
docker-compose ps
docker-compose logs --tail=100 livekit
curl -i http://127.0.0.1:7880/
```

This is a small single-node deployment for one-to-one calls. Recording,
Ingress/Egress and Redis are intentionally disabled for the 2 GB VM.
