# iOS architecture

```text
SwiftUI views
    │
    ▼
AppModel ────────────── CallKitManager / PushKitManager
    │
    ├── ChatAPIClient ── HTTPS + WSS ── Tvoice Chat 0.4.0
    │                                      │
    │                                      └── FreePBX authentication
    │
    ├── LiveKitCallModel ── WebRTC ── LiveKit 1.13.1
    │
    ├── NativeSipEngine ── SIP/UDP ── FreePBX
    │          │
    │          └── RtpAudioEngine ── dynamic RTP/PCMA/PCMU
    │
    └── KeychainStore
```

Rules:

- Views do not know access tokens or passwords.
- The SIP password is sent only to `/v1/auth/login` over HTTPS and is persisted
  only in Keychain.
- The LiveKit API secret never leaves the backend; iOS receives a room-scoped,
  ten-minute token.
- CallKit owns system call presentation. PushKit only wakes the app and must
  immediately lead to a CallKit report.
- SIP signalling and RTP media use separate UDP sockets and ports. RTP endpoints
  are accepted only from negotiated SDP and port 5060 is explicitly rejected.
- Android and iOS remain separate build targets but share the same public API.
