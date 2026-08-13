# Tvoice applications

This repository contains the three native Tvoice clients. Each platform is an
independent project and keeps its own source, build files and documentation.

| Platform | Folder | Version | Main build entry |
| --- | --- | --- | --- |
| Android | [`android/`](android/README.md) | 0.17.3 | `android/gradlew` |
| iOS | [`ios/`](ios/README.md) | 0.1.0 | `ios/TvoiceIOS.xcodeproj` / XcodeGen |
| Windows | [`windows/`](windows/README.md) | 1.1.0 | `windows/Tvoice.Windows.sln` |

## Repository layout

```text
Tvoice/
├── android/   Android/Kotlin application
├── ios/       iOS/SwiftUI application
└── windows/   Windows/WPF application
```

Build outputs, signing keys, credentials, local caches and platform-generated
files are intentionally excluded. Android release updates must be signed with
the existing private production key; the key itself must never be committed.

The applications connect to the deployed Tvoice FreePBX, chat and LiveKit
services. Server infrastructure is maintained outside this application-only
branch.
