# Tvoice source baseline

The clean Android and Windows branches use version `0.17.10+32` and were
derived from the latest integrated Flutter source commit
`153fb062ea2b39a05dd85b0fb3bdbe1232bb963b`.

| Platform | Clean branch | Release source | Notes |
| --- | --- | --- | --- |
| Android | `android` | no Release | `applicationId` remains `tj.tvoice.app`; CI blocks the mismatched signing certificate. |
| iOS | `ios` | — | Orphan branch containing only the MacBook upload placeholder README. |
| Windows | `windows` | tag `windows-v0.17.10` | Includes the Windows client, SIP bridge, canonical server API and guest web client. |

The primary development checkout is `D:\Development\Tvoice`. Generated build
directories, dependency caches, IDE state, old binaries and source archives are
not stored in the clean Git history.
