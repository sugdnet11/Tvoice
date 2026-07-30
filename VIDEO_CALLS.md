# LiveKit video calls

Tvoice 0.17 uses a dedicated self-hosted LiveKit 1.13.1 server for one-to-one
video calls. Audio and video are WebRTC media; FreePBX remains responsible only
for regular SIP audio calls. This avoids depending on Asterisk H.264 pass-through
and gives adaptive bitrate, packet-loss recovery and secure short-lived room
tokens.

## Production topology

- signalling/TLS: `wss://video.185-177-2-115.sslip.io`;
- token and call signalling API: Tvoice Chat 0.4.0;
- primary media: public UDP 443 relayed to the video VM;
- fallback media: public TCP 8091 relayed to the video VM;
- codecs: Opus/RED audio and VP8/H.264 video;
- rooms: two participants, automatic cleanup and a two-minute unanswered-call timeout.

The LiveKit API secret exists only on the video VM and in the chat backend
environment. Android receives a room-scoped token valid for ten minutes after
authenticating with the same FreePBX credentials used for SIP and chat.

## Android behaviour

- portrait remote video with a movable portrait local preview;
- camera/microphone/speaker toggles and front/back camera switching;
- connected-call timer;
- full-screen incoming-call notification with answer/reject;
- Picture-in-Picture minimization so chat remains usable during the call;
- automatic adaptive video quality and TCP fallback when UDP is unavailable.

The Android implementation uses the official open-source LiveKit Android SDK
2.27.0. The previous custom SIP/H.264 implementation remains source-compatible
for legacy incoming SIP offers, but every video button in Tvoice now starts a
LiveKit call.

## Operations

See `video-server/README.md` for the installed ports and service checks. Server
credentials must never be committed or embedded in an APK.
