# Tvoice

Tvoice is a branded Android SIP softphone for the Tvoice service.

## Tvoice SIP Core and Chat Core

Version 0.9 uses the project's own Kotlin implementation and keeps it active in an Android foreground service:

- SIP/2.0 registration over UDP;
- HTTP Digest/MD5 SIP authentication (`401` and `407`);
- outgoing and incoming calls (`INVITE`, `ACK`, `CANCEL`, `BYE`);
- SDP offer/answer;
- RTP audio with G.711 A-law and mu-law;
- RFC 2833 telephone events with SIP INFO fallback;
- microphone mute and Android communication audio routing;
- call hold/resume using re-INVITE.
- encrypted account restoration using Android Keystore;
- Android CallStyle notifications and a lock-screen incoming-call activity;
- UDP NAT Contact correction from SIP `received`/`rport` and 45-second registration refreshes.
- correct authenticated INVITE retry without reusing a challenge `To-tag`;
- separate light incoming-call UI before the active conversation controls appear.
- automatic SIP socket recreation after Wi-Fi/mobile network changes;
- registration recovery with bounded retry delays after temporary network failures.
- dedicated Tvoice Chat connection over HTTPS and secure WebSocket (WSS);
- automatic Chat login with the active SIP subscriber number and password;
- live message delivery, emoji shortcuts, photos/files up to 20 MB, background
  notifications and a local offline cache;
- contact search and creation when starting a new conversation;
- two-second adaptive TOJIKTELECOM/Tvoice welcome screen with safe system-bar spacing;
- three-section navigation for contacts, calls and chat;
- compact right-side account panel, Russian/Tajik UI and light/dark themes.

The core is intentionally scoped to the Tvoice server configuration. It does not contain source or binaries from Linphone, PJSIP, Zoiper or MicroSIP.

## Test configuration

- SIP server: `185.177.2.115`
- Port: `5060`
- Transport: `UDP`
- Login: subscriber number and password entered on the device
- Preferred codecs: `PCMA/8000`, then `PCMU/8000`
- Chat API: `https://chat.185-177-2-115.sslip.io`

Passwords are never stored in this repository. The active account password is encrypted with an
AES/GCM key held by Android Keystore; only the encrypted payload is kept in private app preferences
so the foreground calling service can recover after Android restarts its process. The Chat access
token and plaintext password are kept only in process memory. The Chat server stores a one-way
password hash rather than the subscriber password.

## Build

Every push to `main` builds a debug APK in GitHub Actions. Protocol unit tests are located in `app/src/test`. Open the latest **Build Android APK** run and download the `Tvoice-debug-apk` artifact.

## Security

The current server profile uses SIP/UDP and unencrypted RTP to remain compatible with the existing PBX. TLS and SRTP should be enabled together with matching PBX configuration before carrying sensitive calls over untrusted networks.

Chat does not use SIP `MESSAGE`. It uses the separate Tvoice Chat service over HTTPS/WSS. Every
subscriber must first be provisioned on that service with the same number and password used by the
app. PostgreSQL keeps the server-side message history, while attachments are held in a persistent
protected server volume; Android keeps a limited local cache.

## Ownership and third-party components

The Tvoice application, Tvoice SIP Core and Tvoice Chat integration are project code. AndroidX,
Material Components, Material Icons, OkHttp and Okio remain subject to their respective licenses;
see `THIRD_PARTY_NOTICES.md`.
