# Tvoice

Tvoice is a branded Android SIP softphone for the Tvoice service.

## Test configuration

- SIP server: `185.177.2.115`
- Port: `5060`
- Transport: `UDP`
- Login: subscriber number and password entered on the device

Passwords are not stored in this repository.

## Build

Every push to `main` builds a debug APK in GitHub Actions. Open the latest **Build Android APK** run and download the `Tvoice-debug-apk` artifact.

## Current milestone

- SIP login and registration
- own subscriber number and registration state
- dial pad and outgoing audio calls
- incoming call answer/end
- microphone mute and speaker routing

Next milestone: Android foreground service, notification/full-screen incoming call UI, call history, contacts, iOS CallKit/PushKit.
