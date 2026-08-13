# Tvoice for Android

Tvoice is a branded Android SIP softphone and chat client for the Tvoice service.

## Capabilities

- SIP/2.0 registration over UDP with HTTP Digest/MD5 authentication;
- outgoing and incoming calls, SDP, G.711 A-law/mu-law RTP audio;
- one-to-one LiveKit/WebRTC video calls with Opus, VP8/H.264, adaptive quality and short-lived tokens;
- RFC 2833 DTMF with SIP INFO fallback, mute, speaker and hold/resume;
- Android foreground calling service, CallStyle notifications and lock-screen incoming-call UI;
- connected-call duration, minimizable in-app call screen and an active-call banner while using chat;
- compact four-tab messenger UI (contacts, calls, chats and account) with safe system/IME insets;
- NAT Contact correction, registration refresh, bounded recovery and socket recreation after a
  Wi-Fi/mobile network change;
- encrypted persistent multi-account credentials with one active SIP registration at a time;
- a separate HTTPS/WSS Tvoice Chat client, encrypted offline cache and photos/files up to 20 MB;
- server-backed Tvoice contact directory, canonical SIP addressing, token refresh and retryable
  delivery errors;
- device contacts, call history, Russian/Tajik UI, light/dark themes and account switching.

Conference controls remain hidden because the configured PBX has no verified conference capability.

The core is scoped to the Tvoice server profile. It contains no source or binaries from Linphone,
PJSIP, Zoiper or MicroSIP.

## Test configuration

- SIP server: `185.177.2.115`
- SIP port/transport: `5060/UDP`
- Login: subscriber number and password entered on the device
- Preferred codecs: `PCMA/8000`, then `PCMU/8000`; video: `H264/90000`, packetization mode 1
- Chat API: `https://chat.185-177-2-115.sslip.io`
- Video signalling: `wss://video.185-177-2-115.sslip.io`; media: UDP 443, TCP 8091 fallback

Passwords are never stored in this repository. Saved SIP accounts, call history and the limited
local chat cache are AES/GCM encrypted with separate non-exportable Android Keystore keys. Chat
access tokens and plaintext passwords are kept only in process memory.

## Architecture

The UI talks to a `TvoiceController` boundary. `TvoiceRuntime` owns process-lifetime orchestration,
`SipManager` owns account switching, and `TvoiceSipCore`/`RtpAudioSession` own protocol sockets.
Account, call-history, contacts and chat persistence are separate stores/repositories. See
[`ARCHITECTURE.md`](ARCHITECTURE.md) for dependency rules and data flows.

## Build and verification

Use the checked-in, checksum-pinned Gradle wrapper:

```bash
cd android
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug
```

Pull requests run unit tests, Android lint and a debug build. Pushes to `main` additionally build an
R8-optimized, resource-shrunk release APK signed with repository secrets. The workflow publishes
quality reports plus separate debug and release artifacts. Release signing needs
`TVOICE_KEYSTORE_BASE64` and `TVOICE_KEYSTORE_PASSWORD` GitHub secrets.

## Security

The PBX profile uses SIP/UDP and unencrypted RTP. Incoming SIP datagrams are restricted to the
configured server address; RTP is restricted to the negotiated media address and pinned SSRC.
These checks reduce spoofing but do not provide confidentiality. SIP/TLS and SRTP must be enabled
together with matching PBX configuration before carrying sensitive calls over untrusted networks.
See [`SECURITY.md`](SECURITY.md).

Chat uses the separate HTTPS/WSS Tvoice Chat service, not SIP `MESSAGE`. Its Android cache is
AES-GCM encrypted. Attachment downloads are bounded to 20 MB even if the server omits or falsifies
`Content-Length`.

## Ownership and third-party components

The Tvoice application, SIP core and chat integration are project code. AndroidX, Material
Components, Material Icons, OkHttp and Okio remain subject to their respective licenses; see
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
