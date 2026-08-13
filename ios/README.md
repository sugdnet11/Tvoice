# Tvoice for iOS

This folder is a separate native iOS client. It does not share build files or
generated artifacts with the Android app in the repository root.

## Implemented in the iOS source

- SwiftUI interface for iOS 16 and newer;
- Russian UI with system light/dark appearance;
- one FreePBX username/password used for the existing Tvoice Chat login;
- credentials stored in Keychain with `AfterFirstUnlockThisDeviceOnly`;
- HTTPS contacts, conversations, messages and read/delivery status;
- WSS live chat and incoming video-call signalling;
- LiveKit Swift 2.15.3 video, microphone/camera controls and call timer;
- incoming/outgoing CallKit integration;
- native FreePBX SIP over UDP with Digest authentication;
- symmetric RTP on a dynamically bound port with PCMA/PCMU duplex audio;
- PushKit token registration scaffold;
- four tabs: Contacts, Calls, Chats and Account;
- message composer follows the iOS keyboard through `safeAreaInset`.

Server addresses are centralized in `TvoiceIOS/Core/AppConfig.swift`. LiveKit
API keys and SIP passwords are not embedded in the project.

## Generate and open the project on macOS

Requirements:

- macOS with Xcode 16 or newer;
- XcodeGen (`brew install xcodegen`);
- an Apple Developer team for device signing and PushKit.

Commands:

```bash
cd ios
xcodegen generate
open TvoiceIOS.xcodeproj
```

In Xcode select the `TvoiceIOS` target, open **Signing & Capabilities**, choose
your Apple Developer team and confirm these capabilities:

- Push Notifications;
- Background Modes: Audio, Voice over IP, Remote notifications;
- Camera and microphone privacy descriptions are already in `Info.plist`.

LiveKit is resolved through Swift Package Manager from the official repository.
Use a physical iPhone for video testing: the LiveKit iOS simulator cannot publish
the camera.

## Apple data still required for background incoming calls

Foreground chat and video signalling use the current WebSocket server. To wake
Tvoice after iOS has suspended or terminated it, the backend must send a VoIP
push through APNs. Configure these values only as server secrets:

- Apple Team ID;
- APNs Key ID;
- `.p8` APNs private key;
- final Bundle ID (currently `tj.tvoice.ios`).

After those values are supplied, add the backend endpoint that stores the
PushKit device token and sends a short-expiry VoIP push for
`video.call.incoming`. Apple requires the app to report that push to CallKit.

## Current limitation

Foreground SIP audio calls are implemented. Background and terminated-state
incoming SIP calls still require PushKit/APNs; permanently keeping the
Android-style UDP service alive is not allowed by iOS. FreePBX must keep
`rtp_symmetric`, `force_rport` and `rewrite_contact` enabled for mobile clients.

SIP signalling is sent to `185.177.2.115:5060/UDP`. RTP never uses port 5060:
the client binds a dynamic local socket and takes the remote media address and
port strictly from the peer SDP `c=` and `m=audio` lines.

Chat and LiveKit video use the already deployed Tvoice Chat 0.4.0 and LiveKit
servers without changes.
