# Release checklist

- [ ] `./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleRelease` passes.
- [ ] Test registration, outgoing/incoming call, hangup, hold/resume, mute, speaker and DTMF on the
  target PBX over Wi-Fi and mobile data.
- [ ] After answer, verify the timer starts at `00:00`, survives call-screen minimization and keeps
  advancing while sending a chat message; use the active-call banner to reopen and hang up.
- [ ] Verify Back closes the account drawer, conversation and dialer in order without exiting from a
  nested screen.
- [ ] Test process recreation, network switching and foreground-service notification behavior on
  Android 8, 12 and the current target API.
- [ ] Verify multi-account switch and rejected-account rollback.
- [ ] With two provisioned chat accounts, send messages in both directions using a server-directory
  contact, a manually entered SIP number and a formatted device number. Verify UUID message IDs,
  duplicate message text, expired-token refresh, failed-bubble retry and live WSS delivery.
- [ ] Verify chat reconnect, offline-cache migration, 20 MB upload/download boundary and notification
  privacy against the deployed chat backend.
- [ ] On two physical devices, verify incoming/outgoing H.264 calls, audio-only fallback, camera
  permission denial/retry, camera mute/switch, remote rendering, minimization into chat, background
  foreground-service behavior and cleanup after hangup.
- [ ] Confirm signing certificate SHA-256 matches the previous production release.
- [ ] Review dependency and Android lint reports; archive the signed APK and mapping file.
- [ ] Keep conference UI disabled until PBX integration and two-party-to-conference tests pass.
