# Сборка Windows

## Требования

- Windows 10/11 x64;
- Flutter 3.47.0 и Dart 3.13.0;
- Visual Studio 2022 с компонентом Desktop development with C++;
- .NET 8 SDK для автономного SIP bridge;
- Inno Setup 6 для установщика;
- Node.js 22 и pnpm 11 для server/web-проверок.

## Клиент

```powershell
flutter pub get
flutter analyze
flutter test
flutter build windows --release
& "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe" installer\Tvoice.iss
```

CMake автоматически собирает self-contained SIP bridge и помещает его в
`build\windows\x64\runner\Release\sip_bridge`.

## Server и web

```powershell
pnpm --dir server-backend install --frozen-lockfile
pnpm --dir server-backend run typecheck
pnpm --dir web install --frozen-lockfile
pnpm --dir web run typecheck
pnpm --dir web test
```

