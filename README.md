# Tvoice

Tvoice is a branded Android SIP softphone for the Tvoice service.

## Tvoice SIP Core

Version 0.5 uses the project's own Kotlin implementation and keeps it active in an Android foreground service:

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

The core is intentionally scoped to the Tvoice server configuration. It does not contain source or binaries from Linphone, PJSIP, Zoiper or MicroSIP.

## Test configuration

- SIP server: `185.177.2.115`
- Port: `5060`
- Transport: `UDP`
- Login: subscriber number and password entered on the device
- Preferred codecs: `PCMA/8000`, then `PCMU/8000`

Passwords are never stored in this repository. The active account password is encrypted with an
AES/GCM key held by Android Keystore; only the encrypted payload is kept in private app preferences
so the foreground calling service can recover after Android restarts its process.

## Build

Every push to `main` builds a debug APK in GitHub Actions. Protocol unit tests are located in `app/src/test`. Open the latest **Build Android APK** run and download the `Tvoice-debug-apk` artifact.

## Security

The current server profile uses SIP/UDP and unencrypted RTP to remain compatible with the existing PBX. TLS and SRTP should be enabled together with matching PBX configuration before carrying sensitive calls over untrusted networks.

## Ownership and third-party components

The Tvoice application and Tvoice SIP Core are project code. AndroidX, Material Components and Material Icons remain subject to their own Apache 2.0 terms; see `THIRD_PARTY_NOTICES.md`.
